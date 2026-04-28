defmodule SymphonyElixir.ManagerDashboardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticManager do
    use GenServer

    def start_link(opts) do
      name = Keyword.get(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call({:repo_state, repo_id}, _from, state) do
      reply =
        state
        |> Keyword.fetch!(:repo_states)
        |> Map.get(repo_id, {:error, :repo_not_found})

      {:reply, reply, state}
    end

    def handle_call({:restart_repo, repo_id}, _from, state) do
      send(Keyword.fetch!(state, :parent), {:restart_repo, repo_id})

      next_snapshot =
        update_in(Keyword.fetch!(state, :snapshot).repos, fn repos ->
          Enum.map(repos, &restart_snapshot_repo(&1, repo_id))
        end)

      next_state = Keyword.put(state, :snapshot, next_snapshot)
      repo = Enum.find(next_snapshot.repos, &(&1.id == repo_id))

      {:reply, {:ok, repo}, next_state}
    end

    def handle_call(:restart, _from, state) do
      send(Keyword.fetch!(state, :parent), :restart_manager)
      {:reply, :ok, state}
    end

    defp restart_snapshot_repo(%{id: repo_id} = repo, repo_id) do
      %{
        repo
        | health: :starting,
          running: true,
          restart_attempts: 0,
          next_start_time_ms: 0,
          last_error: nil
      }
    end

    defp restart_snapshot_repo(repo, _repo_id), do: repo
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "manager dashboard switches repos and scopes issue data to the selected repo" do
    {:ok, manager} =
      start_supervised(
        {StaticManager,
         parent: self(),
         snapshot: manager_snapshot([repo_snapshot("repo-a", health: :ok), repo_snapshot("repo-b", health: :ok)]),
         repo_states: %{
           "repo-a" => {:ok, 200, repo_payload("MT-A", "thread-a", "repo a rendered", 1)},
           "repo-b" => {:ok, 200, repo_payload("MT-B", "thread-b", "repo b updated", 2)}
         }}
      )

    start_test_endpoint(manager: manager, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Repo controls"
    assert html =~ "Restart Repo"
    assert html =~ "Restart Manager"
    assert html =~ "MT-A"
    assert html =~ "/tmp/logs/repo-a/log/symphony.log"
    assert html =~ "/tmp/manager.log"
    assert html =~ "/tmp/manager.error.log"
    refute html =~ "MT-B"
    assert html =~ "/api/v1/repos/repo-a/issues/MT-A"
    assert html =~ "REPO-A"

    _ = view |> element("button[phx-value-repo=repo-b]") |> render_click()
    assert_patch(view, "/?repo=repo-b")

    repo_b_html = render(view)
    assert repo_b_html =~ "MT-B"
    refute repo_b_html =~ "MT-A"
    assert repo_b_html =~ "/api/v1/repos/repo-b/issues/MT-B"
    assert repo_b_html =~ "repo b updated"
    assert repo_b_html =~ "Healthy"
  end

  test "manager dashboard renders unavailable repo state and restart actions without crashing" do
    {:ok, manager} =
      start_supervised(
        {StaticManager,
         parent: self(),
         snapshot:
           manager_snapshot([
             repo_snapshot("repo-a", health: :ok),
             repo_snapshot("repo-b", health: :backoff, running: false, restart_attempts: 1, last_error: "start failure: boom")
           ]),
         repo_states: %{
           "repo-a" => {:ok, 200, repo_payload("MT-A", "thread-a", "repo a rendered", 1)},
           "repo-b" => {:error, :repo_unavailable}
         }}
      )

    start_test_endpoint(manager: manager, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/?repo=repo-b")
    assert html =~ "Snapshot unavailable"
    assert html =~ "Restarting"
    assert html =~ "Repo runtime is unavailable while the manager waits to restart it."
    assert html =~ "Restart Repo"
    assert html =~ "Restart Manager"

    restart_repo_html = view |> element("button", "Restart Repo") |> render_click()
    assert_receive {:restart_repo, "repo-b"}
    assert restart_repo_html =~ "Repo restart queued for repo-b."
    assert restart_repo_html =~ "Starting"

    restart_manager_html = view |> element("button", "Restart Manager") |> render_click()
    assert_receive :restart_manager
    assert restart_manager_html =~ "Manager restart queued."
  end

  test "manager dashboard marks long repo strings for wrapping and clamps long session updates" do
    long_repo_name = "repo-with-an-extremely-long-display-name-that-needs-to-wrap-cleanly-inside-the-picker-pill"
    long_repo_id = "repo-host-production-primary-with-a-very-long-identifier-and-extra-segments"
    long_repo_path = "/tmp/company/projects/symphony/instances/repo-host-production-primary-with-a-very-long-identifier-and-extra-segments"
    long_logs_root = "/tmp/logs/symphony/manager-dashboard/repo-host-production-primary-with-a-very-long-identifier-and-extra-segments"
    long_manager_log = "/tmp/logs/symphony/manager-dashboard/manager/symphony-manager-supervisor-with-a-very-long-log-file-name.log"
    long_manager_error_log = "/tmp/logs/symphony/manager-dashboard/manager/symphony-manager-supervisor-with-a-very-long-error-log-file-name.log"

    long_last_error =
      "start failure: repo bootstrap could not complete because the generated workspace path remained locked by a stale worker process for too long"

    long_last_message =
      "Processed repository health update for the selected repo and recorded a detailed manager event message that should wrap instead of forcing the running sessions table to overflow horizontally."

    {:ok, manager} =
      start_supervised(
        {StaticManager,
         parent: self(),
         snapshot:
           manager_snapshot(
             [
               repo_snapshot(long_repo_id,
                 name: long_repo_name,
                 repo_path: long_repo_path,
                 logs_root: long_logs_root,
                 last_error: long_last_error
               )
             ],
             manager_log_path: long_manager_log,
             manager_error_log_path: long_manager_error_log
           ),
         repo_states: %{
           long_repo_id => {:ok, 200, repo_payload("INT-141", "session-with-a-long-id", long_last_message, 1)}
         }}
      )

    start_test_endpoint(manager: manager, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)

    assert html =~ long_repo_name
    assert html =~ long_repo_id
    assert html =~ long_repo_path
    assert html =~ long_logs_root
    assert html =~ long_manager_log
    assert html =~ long_manager_error_log
    assert html =~ long_last_error
    assert html =~ long_last_message

    assert Floki.attribute(document, ".repo-pill-name.text-wrap", "title") == [long_repo_name]

    assert Floki.attribute(document, ".repo-pill-meta.text-wrap", "title") ==
             ["#{long_repo_id} · port 43102"]

    assert long_repo_path in Floki.attribute(document, ".repo-summary-card .metric-detail.text-wrap", "title")
    assert long_logs_root in Floki.attribute(document, ".repo-summary-card .metric-detail.text-wrap", "title")

    assert long_manager_error_log in Floki.attribute(document, ".repo-summary-card .metric-detail.text-wrap", "title")

    assert long_last_error in Floki.attribute(document, ".repo-summary-card .summary-value.text-wrap", "title")

    assert long_manager_log in Floki.attribute(document, ".repo-summary-card .summary-value.text-wrap", "title")

    assert Floki.attribute(document, ".event-text.text-clamp", "title") == [long_last_message]
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp manager_snapshot(repos, opts \\ []) do
    %{
      config_path: "/tmp/manager.json",
      config_mtime: 1,
      manager_log_path: Keyword.get(opts, :manager_log_path, "/tmp/manager.log"),
      manager_error_log_path: Keyword.get(opts, :manager_error_log_path, "/tmp/manager.error.log"),
      repos: repos
    }
  end

  defp repo_snapshot(repo_id, opts) do
    %{
      id: repo_id,
      name: Keyword.get(opts, :name, String.upcase(repo_id)),
      enabled: true,
      repo_path: Keyword.get(opts, :repo_path, "/tmp/#{repo_id}"),
      workflow_path: Keyword.get(opts, :workflow_path, "/tmp/#{repo_id}/WORKFLOW.md"),
      logs_root: Keyword.get(opts, :logs_root, "/tmp/logs/#{repo_id}"),
      local_env_path: Keyword.get(opts, :local_env_path, "/tmp/#{repo_id}/local.env"),
      port: Keyword.get(opts, :port, if(repo_id == "repo-a", do: 43_101, else: 43_102)),
      running: Keyword.get(opts, :running, true),
      health: Keyword.get(opts, :health, :ok),
      failure_count: Keyword.get(opts, :failure_count, 0),
      restart_attempts: Keyword.get(opts, :restart_attempts, 0),
      next_start_time_ms: Keyword.get(opts, :next_start_time_ms, 0),
      blocked_reason: Keyword.get(opts, :blocked_reason),
      last_exit_status: Keyword.get(opts, :last_exit_status),
      last_error: Keyword.get(opts, :last_error),
      last_state_payload: nil
    }
  end

  defp repo_payload(issue_identifier, session_id, last_message, running_count) do
    %{
      "generated_at" => "2026-04-25T20:00:00Z",
      "counts" => %{"running" => running_count, "retrying" => 0},
      "running" => [
        %{
          "issue_id" => "issue-#{issue_identifier}",
          "issue_identifier" => issue_identifier,
          "state" => "In Progress",
          "worker_host" => nil,
          "workspace_path" => "/tmp/#{issue_identifier}",
          "session_id" => session_id,
          "turn_count" => 3,
          "last_event" => "notification",
          "last_message" => last_message,
          "pending_approval" => nil,
          "started_at" => "2026-04-25T19:58:00Z",
          "last_event_at" => "2026-04-25T19:59:00Z",
          "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
        }
      ],
      "retrying" => [],
      "codex_totals" => %{
        "input_tokens" => 4,
        "output_tokens" => 8,
        "total_tokens" => 12,
        "seconds_running" => 42.5
      },
      "rate_limits" => %{"primary" => %{"remaining" => 11}}
    }
  end
end
