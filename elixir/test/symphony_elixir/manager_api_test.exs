defmodule SymphonyElixir.ManagerApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.Manager

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule RepoApiPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      state_payload = Keyword.fetch!(opts, :state_payload)
      issue_responses = Keyword.get(opts, :issue_responses, %{})

      case {conn.method, conn.path_info} do
        {"GET", ["api", "v1", "state"]} ->
          json(conn, 200, state_payload)

        {"GET", ["api", "v1", issue_identifier]} ->
          case Map.get(issue_responses, issue_identifier, {404, issue_not_found_payload()}) do
            {status, payload} -> json(conn, status, payload)
          end

        _ ->
          json(conn, 404, %{"error" => %{"code" => "not_found", "message" => "Route not found"}})
      end
    end

    defp json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end

    defp issue_not_found_payload do
      %{"error" => %{"code" => "issue_not_found", "message" => "Issue not found"}}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "manager api exposes repo-scoped reads and repo restarts" do
    with_manager_fixture!(fn fixture ->
      parent = self()

      repo_state_payload = %{
        "generated_at" => "2026-04-14T11:00:00Z",
        "counts" => %{"running" => 1, "retrying" => 0},
        "running" => [
          %{
            "issue_id" => "issue-http",
            "issue_identifier" => "MT-HTTP",
            "state" => "In Progress",
            "worker_host" => nil,
            "workspace_path" => "/tmp/repo-a-workspace/MT-HTTP",
            "session_id" => "thread-http",
            "turn_count" => 3,
            "last_event" => "notification",
            "last_message" => "rendered",
            "pending_approval" => nil,
            "started_at" => "2026-04-14T10:55:00Z",
            "last_event_at" => nil,
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

      repo_issue_payload = %{
        "issue_identifier" => "MT-HTTP",
        "issue_id" => "issue-http",
        "status" => "running",
        "workspace" => %{
          "path" => "/tmp/repo-a-workspace/MT-HTTP",
          "host" => nil
        },
        "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
        "running" => %{
          "worker_host" => nil,
          "workspace_path" => "/tmp/repo-a-workspace/MT-HTTP",
          "session_id" => "thread-http",
          "turn_count" => 3,
          "state" => "In Progress",
          "started_at" => "2026-04-14T10:55:00Z",
          "last_event" => "notification",
          "last_message" => "rendered",
          "pending_approval" => nil,
          "last_event_at" => nil,
          "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
        },
        "retry" => nil,
        "pending_approval" => nil,
        "logs" => %{"codex_session_logs" => []},
        "recent_events" => [],
        "last_error" => nil,
        "tracked" => %{}
      }

      repo_port =
        start_repo_api!(
          state_payload: repo_state_payload,
          issue_responses: %{"MT-HTTP" => {200, repo_issue_payload}}
        )

      config =
        fixture.config
        |> put_in(["repos", Access.at(0), "port"], repo_port)

      write_config!(fixture.config_path, config)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> 0 end,
          runtime_start: fn repo, _config, _env ->
            handle = {:runtime, repo.id, System.unique_integer([:positive])}
            send(parent, {:runtime_started, handle, repo.id})
            {:ok, handle}
          end,
          runtime_stop: fn handle, timeout_ms ->
            send(parent, {:runtime_stopped, handle, timeout_ms})
            :ok
          end,
          fetch_state: fn _port, _timeout_ms ->
            {:ok, %{"running" => [], "retrying" => []}}
          end
        )

      on_exit(fn ->
        if Process.alive?(manager) do
          GenServer.stop(manager)
        end
      end)

      assert_receive {:runtime_started, first_handle, "repo-a"}
      start_test_endpoint(manager: manager, snapshot_timeout_ms: 50)

      repos_payload = json_response(get(build_conn(), "/api/v1/repos"), 200)

      assert Enum.map(repos_payload["repos"], & &1["id"]) == ["repo-a", "repo-b"]

      assert Enum.any?(
               repos_payload["repos"],
               &(&1["id"] == "repo-a" and &1["running"] == true and &1["port"] == repo_port)
             )

      assert json_response(get(build_conn(), "/api/v1/repos/repo-a/state"), 200) == repo_state_payload

      assert json_response(get(build_conn(), "/api/v1/repos/repo-a/issues/MT-HTTP"), 200) ==
               repo_issue_payload

      assert json_response(get(build_conn(), "/api/v1/repos/repo-a/issues/MT-MISSING"), 404) ==
               %{"error" => %{"code" => "issue_not_found", "message" => "Issue not found"}}

      assert json_response(get(build_conn(), "/api/v1/repos/repo-missing/state"), 404) ==
               %{"error" => %{"code" => "repo_not_found", "message" => "Repo not found"}}

      restart_payload = json_response(post(build_conn(), "/api/v1/repos/repo-a/restart", %{}), 202)

      assert restart_payload["id"] == "repo-a"
      assert restart_payload["running"] == true
      assert restart_payload["health"] == "starting"
      assert_receive {:runtime_stopped, ^first_handle, 10_000}
      assert_receive {:runtime_started, second_handle, "repo-a"}
      refute second_handle == first_handle
    end)
  end

  test "manager api returns explicit repo_unavailable errors when a runtime cannot be reached" do
    with_manager_fixture!(fn fixture ->
      parent = self()

      config =
        fixture.config
        |> put_in(["repos", Access.at(0), "port"], reserve_port!())

      write_config!(fixture.config_path, config)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> 0 end,
          runtime_start: fn repo, _config, _env ->
            handle = {:runtime, repo.id, System.unique_integer([:positive])}
            send(parent, {:runtime_started, handle, repo.id})
            {:ok, handle}
          end,
          runtime_stop: fn _handle, _timeout_ms -> :ok end,
          fetch_state: fn _port, _timeout_ms ->
            {:ok, %{"running" => [], "retrying" => []}}
          end
        )

      on_exit(fn ->
        if Process.alive?(manager) do
          GenServer.stop(manager)
        end
      end)

      assert_receive {:runtime_started, _handle, "repo-a"}
      start_test_endpoint(manager: manager, snapshot_timeout_ms: 50)

      assert json_response(get(build_conn(), "/api/v1/repos/repo-a/state"), 503) ==
               %{"error" => %{"code" => "repo_unavailable", "message" => "Repo runtime is unavailable"}}

      assert json_response(get(build_conn(), "/api/v1/repos/repo-a/issues/MT-HTTP"), 503) ==
               %{"error" => %{"code" => "repo_unavailable", "message" => "Repo runtime is unavailable"}}
    end)
  end

  test "manager api restart endpoint stops the manager cleanly" do
    with_manager_fixture!(fn fixture ->
      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> 0 end,
          runtime_start: fn repo, _config, _env -> {:ok, {:runtime, repo.id}} end,
          runtime_stop: fn _handle, _timeout_ms -> :ok end,
          fetch_state: fn _port, _timeout_ms ->
            {:ok, %{"running" => [], "retrying" => []}}
          end
        )

      start_test_endpoint(manager: manager, snapshot_timeout_ms: 50)

      assert json_response(post(build_conn(), "/api/v1/manager/restart", %{}), 202) ==
               %{"queued" => true, "action" => "manager_restart"}

      refute Process.alive?(manager)
    end)
  end

  test "manager api returns manager_unavailable when no manager is configured" do
    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :MissingOrchestrator), snapshot_timeout_ms: 5)

    assert json_response(get(build_conn(), "/api/v1/repos"), 503) ==
             %{"error" => %{"code" => "manager_unavailable", "message" => "Manager is unavailable"}}
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

  defp start_repo_api!(opts) do
    port = reserve_port!()

    start_supervised!({Bandit, plug: {RepoApiPlug, opts}, scheme: :http, ip: {127, 0, 0, 1}, port: port})

    port
  end

  defp reserve_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp with_manager_fixture!(fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-manager-api-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    config =
      base_config(root)
      |> Map.put("repos", [
        repo_entry(root, "repo-a", port: nil),
        repo_entry(root, "repo-b", enabled: false, port: 43_102, local_env?: false)
      ])

    config_path = Path.join(root, "config.json")
    write_config!(config_path, config)

    try do
      fun.(%{config: config, config_path: config_path, root: root})
    after
      File.rm_rf(root)
    end
  end

  defp base_config(root) do
    symphony_repo = Path.join(root, "symphony")
    symphony_bin = Path.join([symphony_repo, "elixir", "bin", "symphony"])

    File.mkdir_p!(Path.dirname(symphony_bin))
    File.write!(symphony_bin, "#!/bin/sh\nexit 0\n")
    File.chmod!(symphony_bin, 0o755)

    %{
      "version" => 1,
      "symphony_repo" => symphony_repo,
      "symphony_bin" => symphony_bin,
      "manager" => %{
        "check_interval_seconds" => 1,
        "http_timeout_seconds" => 1,
        "failure_threshold" => 3,
        "restart_backoff_seconds" => [5, 15, 30],
        "port_range" => %{"start" => 43_101, "end" => 65_535},
        "graceful_shutdown_seconds" => 10,
        "config_reload_seconds" => 5
      },
      "repos" => []
    }
  end

  defp repo_entry(root, repo_id, opts) do
    repo_path = Path.join(root, repo_id)
    workflow_path = Path.join([root, "workflows", repo_id, "WORKFLOW.md"])
    logs_root = Path.join([root, "logs", repo_id])
    local_env_path = Path.join(repo_path, "local.env")

    File.mkdir_p!(repo_path)
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, "tracker:\n  kind: memory\n")

    if Keyword.get(opts, :local_env?, true) do
      File.write!(local_env_path, "LOCAL_ONLY=from_file\n")
    end

    %{
      "id" => repo_id,
      "name" => String.upcase(repo_id),
      "repo_path" => repo_path,
      "workflow_path" => workflow_path,
      "logs_root" => logs_root,
      "local_env_path" => if(Keyword.get(opts, :local_env?, true), do: local_env_path, else: nil),
      "port" => Keyword.get(opts, :port),
      "enabled" => Keyword.get(opts, :enabled, true),
      "env" => %{}
    }
  end

  defp write_config!(path, config) do
    File.write!(path, Jason.encode!(config, pretty: true) <> "\n")
  end
end
