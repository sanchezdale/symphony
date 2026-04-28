defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @guardrails_dir ".symphony"
  @guardrails_bin_dir Path.join(@guardrails_dir, "bin")
  @guardrails_context_file Path.join(@guardrails_dir, "issue-context.tsv")
  @guardrails_script_file Path.join(@guardrails_dir, "guardrails.sh")
  @default_branch_names MapSet.new(["main", "master", "trunk", "develop"])

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  @spec ensure_codex_guardrails(Path.t(), map() | String.t() | nil, worker_host()) ::
          {:ok, map()} | {:error, term()}
  def ensure_codex_guardrails(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    current_branch = current_git_branch(workspace, worker_host)

    with :ok <- write_guardrail_files(workspace, issue_context, current_branch, worker_host) do
      {:ok, codex_guardrail_context(workspace, issue_or_identifier, worker_host)}
    end
  end

  @spec codex_guardrail_context(Path.t(), map() | String.t() | nil, worker_host()) :: map()
  def codex_guardrail_context(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    stored_context = read_guardrail_context(workspace, worker_host)
    current_branch = current_git_branch(workspace, worker_host)

    %{
      workspace_path: workspace,
      issue_identifier: issue_context.issue_identifier,
      current_branch: current_branch,
      canonical_branch: pick_context_value(stored_context, "CANONICAL_BRANCH", current_branch),
      linear_branch_name: pick_context_value(stored_context, "LINEAR_BRANCH_NAME", issue_context.branch_name),
      pr_number: pick_context_value(stored_context, "PR_NUMBER"),
      pr_url: pick_context_value(stored_context, "PR_URL")
    }
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp write_guardrail_files(workspace, issue_context, current_branch, nil) do
    File.mkdir_p!(Path.join(workspace, @guardrails_bin_dir))

    context =
      workspace
      |> read_guardrail_context(nil)
      |> Map.merge(base_guardrail_context(issue_context, current_branch))

    File.write!(Path.join(workspace, @guardrails_context_file), encode_guardrail_context(context))
    File.write!(Path.join(workspace, @guardrails_script_file), guardrails_shell_script())
    File.write!(Path.join(workspace, Path.join(@guardrails_bin_dir, "gh")), gh_guardrails_wrapper())
    File.write!(Path.join(workspace, Path.join(@guardrails_bin_dir, "git")), git_guardrails_wrapper())
    File.chmod!(Path.join(workspace, @guardrails_script_file), 0o755)
    File.chmod!(Path.join(workspace, Path.join(@guardrails_bin_dir, "gh")), 0o755)
    File.chmod!(Path.join(workspace, Path.join(@guardrails_bin_dir, "git")), 0o755)
    :ok
  rescue
    error in [File.Error, ErlangError] -> {:error, {:guardrail_setup_failed, Exception.message(error)}}
  end

  defp write_guardrail_files(workspace, issue_context, current_branch, worker_host)
       when is_binary(worker_host) do
    context =
      workspace
      |> read_guardrail_context(worker_host)
      |> Map.merge(base_guardrail_context(issue_context, current_branch))

    script =
      [
        remote_shell_assign("workspace", workspace),
        "mkdir -p \"$workspace/#{@guardrails_bin_dir}\"",
        heredoc_write_command("$workspace/#{@guardrails_context_file}", encode_guardrail_context(context)),
        heredoc_write_command("$workspace/#{@guardrails_script_file}", guardrails_shell_script()),
        heredoc_write_command("$workspace/#{Path.join(@guardrails_bin_dir, "gh")}", gh_guardrails_wrapper()),
        heredoc_write_command("$workspace/#{Path.join(@guardrails_bin_dir, "git")}", git_guardrails_wrapper()),
        "chmod +x \"$workspace/#{@guardrails_script_file}\"",
        "chmod +x \"$workspace/#{Path.join(@guardrails_bin_dir, "gh")}\"",
        "chmod +x \"$workspace/#{Path.join(@guardrails_bin_dir, "git")}\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:guardrail_setup_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_guardrail_context(issue_context, current_branch) do
    %{}
    |> maybe_put_context_value("ISSUE_IDENTIFIER", issue_context.issue_identifier)
    |> maybe_put_context_value("LINEAR_BRANCH_NAME", issue_context.branch_name)
    |> maybe_put_context_value("CANONICAL_BRANCH", canonical_branch_for_context(current_branch, issue_context.branch_name))
  end

  defp canonical_branch_for_context(current_branch, linear_branch_name) do
    cond do
      branch_canonical_candidate?(current_branch) -> current_branch
      is_binary(linear_branch_name) and String.trim(linear_branch_name) != "" -> String.trim(linear_branch_name)
      true -> nil
    end
  end

  defp maybe_put_context_value(context, _key, nil), do: context

  defp maybe_put_context_value(context, key, value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      context
    else
      Map.put(context, key, trimmed)
    end
  end

  defp maybe_put_context_value(context, key, value), do: Map.put(context, key, to_string(value))

  defp encode_guardrail_context(context) when is_map(context) do
    context
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("", fn {key, value} -> "#{key}\t#{value}\n" end)
  end

  defp read_guardrail_context(workspace, nil) when is_binary(workspace) do
    context_path = Path.join(workspace, @guardrails_context_file)

    case File.read(context_path) do
      {:ok, content} -> parse_guardrail_context(content)
      {:error, _reason} -> %{}
    end
  end

  defp read_guardrail_context(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    script =
      [
        remote_shell_assign("workspace", workspace),
        "context_file=\"$workspace/#{@guardrails_context_file}\"",
        "if [ -f \"$context_file\" ]; then",
        "  cat \"$context_file\"",
        "fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> parse_guardrail_context(output)
      _ -> %{}
    end
  end

  defp parse_guardrail_context(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "\t", parts: 2) do
        [key, value] when key != "" and value != "" -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp current_git_branch(workspace, nil) when is_binary(workspace) do
    case System.find_executable("git") do
      nil ->
        nil

      git ->
        case System.cmd(git, ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.trim()
            |> blank_to_nil()

          _ ->
            nil
        end
    end
  end

  defp current_git_branch(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    script =
      [
        "git_bin=\"$(command -v git 2>/dev/null || true)\"",
        "if [ -z \"$git_bin\" ]; then",
        "  exit 0",
        "fi",
        "cd #{shell_escape(workspace)}",
        "\"$git_bin\" branch --show-current 2>/dev/null || true"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        output
        |> String.trim()
        |> blank_to_nil()

      _ ->
        nil
    end
  end

  defp pick_context_value(context, key, fallback \\ nil) when is_map(context) do
    context
    |> Map.get(key, fallback)
    |> blank_to_nil()
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(value), do: value

  defp branch_canonical_candidate?(branch) when is_binary(branch) do
    trimmed = String.trim(branch)
    trimmed != "" and not MapSet.member?(@default_branch_names, trimmed)
  end

  defp branch_canonical_candidate?(_branch), do: false

  defp heredoc_write_command(target, contents) when is_binary(target) and is_binary(contents) do
    marker = "SYMPHONY_GUARDRAILS_EOF"

    [
      "cat <<'#{marker}' > #{target}",
      contents,
      marker
    ]
    |> Enum.join("\n")
  end

  defp guardrails_shell_script do
    """
    #!/bin/sh
    set -eu

    : "${SYMPHONY_GUARDRAILS_DIR:=$(CDPATH= cd -- "$(dirname "$0")" && pwd)}"
    SYMPHONY_CONTEXT_FILE="$SYMPHONY_GUARDRAILS_DIR/issue-context.tsv"

    load_symphony_context() {
      ISSUE_IDENTIFIER=""
      LINEAR_BRANCH_NAME=""
      CANONICAL_BRANCH=""
      PR_NUMBER=""
      PR_URL=""

      if [ -f "$SYMPHONY_CONTEXT_FILE" ]; then
        while IFS="$(printf '\\t')" read -r key value; do
          [ -n "$key" ] || continue
          case "$key" in
            ISSUE_IDENTIFIER) ISSUE_IDENTIFIER="$value" ;;
            LINEAR_BRANCH_NAME) LINEAR_BRANCH_NAME="$value" ;;
            CANONICAL_BRANCH) CANONICAL_BRANCH="$value" ;;
            PR_NUMBER) PR_NUMBER="$value" ;;
            PR_URL) PR_URL="$value" ;;
          esac
        done < "$SYMPHONY_CONTEXT_FILE"
      fi
    }

    save_symphony_context() {
      tmp_file="$SYMPHONY_CONTEXT_FILE.tmp"
      {
        [ -n "$ISSUE_IDENTIFIER" ] && printf 'ISSUE_IDENTIFIER\\t%s\\n' "$ISSUE_IDENTIFIER"
        [ -n "$LINEAR_BRANCH_NAME" ] && printf 'LINEAR_BRANCH_NAME\\t%s\\n' "$LINEAR_BRANCH_NAME"
        [ -n "$CANONICAL_BRANCH" ] && printf 'CANONICAL_BRANCH\\t%s\\n' "$CANONICAL_BRANCH"
        [ -n "$PR_NUMBER" ] && printf 'PR_NUMBER\\t%s\\n' "$PR_NUMBER"
        [ -n "$PR_URL" ] && printf 'PR_URL\\t%s\\n' "$PR_URL"
      } > "$tmp_file"
      mv "$tmp_file" "$SYMPHONY_CONTEXT_FILE"
    }

    symphony_find_real_executable() {
      tool_name="$1"
      search_path="${SYMPHONY_ORIGINAL_PATH:-$PATH}"
      PATH="$search_path" command -v "$tool_name"
    }

    symphony_current_branch() {
      real_git="$1"
      "$real_git" branch --show-current 2>/dev/null || true
    }

    symphony_is_default_branch() {
      case "$1" in
        main|master|trunk|develop|'') return 0 ;;
        *) return 1 ;;
      esac
    }

    symphony_capture_canonical_branch() {
      branch_name="$1"

      if [ -z "${CANONICAL_BRANCH:-}" ] && [ -n "$branch_name" ] && ! symphony_is_default_branch "$branch_name"; then
        CANONICAL_BRANCH="$branch_name"
        save_symphony_context
      fi
    }

    symphony_request_codex_review() {
      real_gh="$1"
      pr_number="$2"

      [ -n "$pr_number" ] || return 0
      "$real_gh" pr comment "$pr_number" --body "@codex review" >/dev/null 2>&1 || true
    }
    """
    |> String.trim_leading()
  end

  defp gh_guardrails_wrapper do
    """
    #!/bin/sh
    set -eu

    SYMPHONY_BIN_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
    export SYMPHONY_GUARDRAILS_DIR="$SYMPHONY_BIN_DIR"
    # shellcheck source=/dev/null
    . "$SYMPHONY_BIN_DIR/guardrails.sh"

    load_symphony_context
    REAL_GH="$(symphony_find_real_executable gh)"
    REAL_GIT="$(symphony_find_real_executable git)"
    CURRENT_BRANCH="$(symphony_current_branch "$REAL_GIT" | tr -d '\\r')"
    symphony_capture_canonical_branch "$CURRENT_BRANCH"

    if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
      comment_body=""
      previous=""

      for arg in "$@"; do
        case "$previous" in
          --body)
            comment_body="$arg"
            previous=""
            continue
            ;;
        esac

        case "$arg" in
          --body)
            previous="--body"
            ;;
        esac
      done

      if [ "$comment_body" = "@codex review" ]; then
        exec "$REAL_GH" "$@"
      fi

      printf '%s\\n' "Symphony policy: PR comments are disabled except for requesting Codex review with '@codex review'." >&2
      exit 1
    fi

    if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
      for arg in "$@"; do
        case "$arg" in
          --add-reviewer|--remove-reviewer|--reviewer)
            printf '%s\\n' "Symphony policy: reviewer assignment is disabled. GitHub default reviewers handle review requests." >&2
            exit 1
            ;;
        esac
      done
    fi

    if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "create" ]; then
      if [ -n "${CANONICAL_BRANCH:-}" ] && [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "$CANONICAL_BRANCH" ]; then
        printf '%s\\n' "Symphony policy: issue ${ISSUE_IDENTIFIER:-unknown} must continue on branch $CANONICAL_BRANCH, not $CURRENT_BRANCH." >&2
        exit 1
      fi

      if [ -z "${CANONICAL_BRANCH:-}" ] && [ -n "$CURRENT_BRANCH" ]; then
        CANONICAL_BRANCH="$CURRENT_BRANCH"
        save_symphony_context
      fi

      if [ -n "$CURRENT_BRANCH" ]; then
        existing_number="$("$REAL_GH" pr list --head "$CURRENT_BRANCH" --state all --json number --jq '.[0].number' 2>/dev/null || true)"

        if [ -n "$existing_number" ] && [ "$existing_number" != "null" ]; then
          existing_url="$("$REAL_GH" pr list --head "$CURRENT_BRANCH" --state all --json url --jq '.[0].url' 2>/dev/null || true)"
          PR_NUMBER="$existing_number"
          PR_URL="$existing_url"
          save_symphony_context
          symphony_request_codex_review "$REAL_GH" "$PR_NUMBER"
          [ -n "$existing_url" ] && printf '%s\\n' "$existing_url"
          exit 0
        fi
      fi

      set +e
      output="$("$REAL_GH" "$@" 2>&1)"
      status=$?
      set -e
      printf '%s' "$output"
      [ -n "$output" ] && printf '\\n'

      if [ "$status" -eq 0 ] && [ -n "$CURRENT_BRANCH" ]; then
        PR_NUMBER="$("$REAL_GH" pr list --head "$CURRENT_BRANCH" --state all --json number --jq '.[0].number' 2>/dev/null || true)"
        PR_URL="$("$REAL_GH" pr list --head "$CURRENT_BRANCH" --state all --json url --jq '.[0].url' 2>/dev/null || true)"
        save_symphony_context
        symphony_request_codex_review "$REAL_GH" "$PR_NUMBER"
      fi

      exit "$status"
    fi

    exec "$REAL_GH" "$@"
    """
    |> String.trim_leading()
  end

  defp git_guardrails_wrapper do
    """
    #!/bin/sh
    set -eu

    SYMPHONY_BIN_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
    export SYMPHONY_GUARDRAILS_DIR="$SYMPHONY_BIN_DIR"
    # shellcheck source=/dev/null
    . "$SYMPHONY_BIN_DIR/guardrails.sh"

    load_symphony_context
    REAL_GIT="$(symphony_find_real_executable git)"

    guard_branch_creation() {
      new_branch="$1"

      if [ -z "$new_branch" ]; then
        return 0
      fi

      if [ -n "${CANONICAL_BRANCH:-}" ] && [ "$new_branch" != "$CANONICAL_BRANCH" ]; then
        printf '%s\\n' "Symphony policy: issue ${ISSUE_IDENTIFIER:-unknown} must continue on branch $CANONICAL_BRANCH, not $new_branch." >&2
        exit 1
      fi

      if [ -z "${CANONICAL_BRANCH:-}" ] && [ -n "${LINEAR_BRANCH_NAME:-}" ] && [ "$new_branch" != "$LINEAR_BRANCH_NAME" ]; then
        printf '%s\\n' "Symphony policy: initial branch for issue ${ISSUE_IDENTIFIER:-unknown} must use the Linear branch name $LINEAR_BRANCH_NAME." >&2
        exit 1
      fi
    }

    if [ "$#" -ge 3 ] && [ "$1" = "checkout" ] && { [ "$2" = "-b" ] || [ "$2" = "-B" ]; }; then
      guard_branch_creation "$3"
      exec "$REAL_GIT" "$@"
    fi

    if [ "$#" -ge 3 ] && [ "$1" = "switch" ] && { [ "$2" = "-c" ] || [ "$2" = "-C" ]; }; then
      guard_branch_creation "$3"
      exec "$REAL_GIT" "$@"
    fi

    exec "$REAL_GIT" "$@"
    """
    |> String.trim_leading()
  end

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier, branch_name: branch_name}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      branch_name: branch_name
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      branch_name: nil
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      branch_name: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      branch_name: nil
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
