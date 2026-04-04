defmodule SymphonyElixir.ManagerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Manager
  alias SymphonyElixir.ManagerConfig

  test "starts enabled repos, skips disabled repos, and persists assigned ports" do
    with_manager_fixture!(fn fixture ->
      parent = self()

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> 0 end,
          runtime_start: fn repo, _config, env ->
            handle = {:runtime, repo.id, repo.port}
            send(parent, {:runtime_started, handle, repo.id, repo.port, env})
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

      assert_receive {:runtime_started, {:runtime, "repo-a", assigned_port}, "repo-a", assigned_port, env}
      assert is_integer(assigned_port)
      refute_receive {:runtime_started, _handle, "repo-b", _port, _env}
      assert env["LOCAL_ONLY"] == "from_file"
      assert env["INLINE_ONLY"] == "from_repo"
      assert env["OVERRIDE_ME"] == "from_repo"
      assert File.dir?(Path.join([fixture.root, "logs", "repo-a"]))

      snapshot = Manager.snapshot(manager)

      assert [
               %{id: "repo-a", health: :starting, running: true, port: ^assigned_port},
               %{id: "repo-b", health: :disabled, running: false}
             ] = snapshot.repos

      assert {:ok, persisted} = ManagerConfig.load_raw(fixture.config_path)
      assert get_in(persisted, ["repos", Access.at(0), "port"]) == assigned_port
    end)
  end

  test "reloads config to disable, enable, add, and remove repos cleanly" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> Agent.get(clock, & &1) end,
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

      assert_receive {:runtime_started, repo_a_handle, "repo-a"}

      updated_config =
        fixture.config
        |> Map.put("repos", [
          repo_entry(fixture.root, "repo-a", enabled: false, port: 43_101),
          repo_entry(fixture.root, "repo-b", enabled: true, port: 43_102),
          repo_entry(fixture.root, "repo-c", enabled: true, port: 43_103, local_env?: false)
        ])

      write_config!(fixture.config_path, updated_config)
      Agent.update(clock, &(&1 + 5_000))

      snapshot_after_reload = Manager.tick(manager)

      assert_receive {:runtime_stopped, ^repo_a_handle, 10_000}
      assert_receive {:runtime_started, _repo_b_handle, "repo-b"}
      assert_receive {:runtime_started, _repo_c_handle, "repo-c"}

      assert Enum.any?(snapshot_after_reload.repos, &(&1.id == "repo-a" and &1.health == :disabled))
      assert Enum.any?(snapshot_after_reload.repos, &(&1.id == "repo-b" and &1.running))
      assert Enum.any?(snapshot_after_reload.repos, &(&1.id == "repo-c" and &1.running))

      removed_config =
        updated_config
        |> Map.put("repos", [
          repo_entry(fixture.root, "repo-b", enabled: true, port: 43_102),
          repo_entry(fixture.root, "repo-c", enabled: true, port: 43_103, local_env?: false)
        ])

      write_config!(fixture.config_path, removed_config)
      Agent.update(clock, &(&1 + 5_000))

      snapshot_after_remove = Manager.tick(manager)

      assert Enum.map(snapshot_after_remove.repos, & &1.id) == ["repo-b", "repo-c"]
    end)
  end

  test "restarts an enabled repo immediately when runtime config changes on reload" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> Agent.get(clock, & &1) end,
          runtime_start: fn repo, _config, env ->
            handle = {:runtime, repo.id, System.unique_integer([:positive])}
            send(parent, {:runtime_started, handle, repo, env})
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

      assert_receive {:runtime_started, first_handle, first_repo, first_env}
      assert first_repo.id == "repo-a"
      assert first_env["INLINE_ONLY"] == "from_repo"
      assert first_env["OVERRIDE_ME"] == "from_repo"

      reloaded_logs_root = Path.join([fixture.root, "logs", "repo-a-reloaded"])
      reloaded_local_env_path = Path.join([fixture.root, "repo-a", "reloaded.env"])

      updated_config =
        fixture.config
        |> Map.put("repos", [
          repo_entry(
            fixture.root,
            "repo-a",
            port: 43_104,
            workflow_basename: "RELOADED.md",
            logs_root: reloaded_logs_root,
            local_env_path: reloaded_local_env_path,
            local_env_contents: "LOCAL_ONLY=from_reload_file\nOVERRIDE_ME=from_reload_file\n",
            env: %{
              "INLINE_ONLY" => "from_reload",
              "OVERRIDE_ME" => "from_reload"
            }
          ),
          repo_entry(fixture.root, "repo-b", enabled: false, port: 43_102, local_env?: false)
        ])

      write_config!(fixture.config_path, updated_config)
      Agent.update(clock, &(&1 + 5_000))

      snapshot_after_reload = Manager.tick(manager)

      assert_receive {:runtime_stopped, ^first_handle, 10_000}
      assert_receive {:runtime_started, second_handle, second_repo, second_env}
      refute second_handle == first_handle

      assert second_repo.id == "repo-a"
      assert second_repo.port == 43_104
      assert second_repo.workflow_path == Path.join([fixture.root, "workflows", "repo-a", "RELOADED.md"])
      assert second_repo.logs_root == reloaded_logs_root
      assert second_repo.local_env_path == reloaded_local_env_path
      assert second_env["LOCAL_ONLY"] == "from_reload_file"
      assert second_env["INLINE_ONLY"] == "from_reload"
      assert second_env["OVERRIDE_ME"] == "from_reload"
      assert File.dir?(reloaded_logs_root)

      assert Enum.any?(
               snapshot_after_reload.repos,
               &(&1.id == "repo-a" and &1.running and &1.port == 43_104 and
                   &1.workflow_path == second_repo.workflow_path and
                   &1.logs_root == reloaded_logs_root and &1.local_env_path == reloaded_local_env_path)
             )
    end)
  end

  test "keeps blocked repos blocked until the effective config changes" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      missing_env_path = Path.join([fixture.root, "repo-a", "missing.env"])

      blocked_config =
        put_in(
          fixture.config,
          ["repos", Access.at(0), "local_env_path"],
          missing_env_path
        )

      write_config!(fixture.config_path, blocked_config)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> Agent.get(clock, & &1) end,
          runtime_start: fn repo, _config, env ->
            send(parent, {:runtime_started, repo.id, env})
            {:ok, {:runtime, repo.id}}
          end,
          runtime_stop: fn handle, timeout_ms ->
            send(parent, {:runtime_stopped, handle, timeout_ms})
            :ok
          end,
          fetch_state: fn _port, _timeout_ms ->
            {:ok, %{"running" => [], "retrying" => []}}
          end
        )

      blocked_snapshot = Manager.snapshot(manager)

      assert Enum.any?(
               blocked_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :blocked and
                   &1.blocked_reason == "local_env_path does not exist: #{missing_env_path}" and not &1.running)
             )

      refute_receive {:runtime_started, "repo-a", _env}

      Agent.update(clock, &(&1 + 5_000))
      still_blocked_snapshot = Manager.tick(manager)
      refute_receive {:runtime_started, "repo-a", _env}

      assert Enum.any?(
               still_blocked_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :blocked and
                   &1.blocked_reason == "local_env_path does not exist: #{missing_env_path}" and not &1.running)
             )

      assert {:ok, persisted_config} = ManagerConfig.load_raw(fixture.config_path)
      local_env_path = Path.join([fixture.root, "repo-a", "local.env"])

      updated_config =
        persisted_config
        |> put_in(["repos", Access.at(0), "local_env_path"], local_env_path)
        |> put_in(
          ["repos", Access.at(0), "env"],
          %{
            "INLINE_ONLY" => "from_reload",
            "OVERRIDE_ME" => "from_reload"
          }
        )

      write_config!(fixture.config_path, updated_config)

      reloaded_snapshot = Manager.reload_config(manager)

      assert_receive {:runtime_started, "repo-a", second_env}
      assert second_env["INLINE_ONLY"] == "from_reload"
      assert second_env["OVERRIDE_ME"] == "from_reload"
      assert second_env["LOCAL_ONLY"] == "from_file"

      assert Enum.any?(
               reloaded_snapshot.repos,
               &(&1.id == "repo-a" and &1.running and &1.health == :starting and is_nil(&1.blocked_reason))
             )
    end)
  end

  test "does not retry blocked repos when unrelated config changes" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      {:ok, attempts} = Agent.start_link(fn -> %{} end)
      missing_env_path = Path.join([fixture.root, "repo-a", "missing.env"])

      blocked_config =
        put_in(
          fixture.config,
          ["repos", Access.at(0), "local_env_path"],
          missing_env_path
        )

      write_config!(fixture.config_path, blocked_config)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> Agent.get(clock, & &1) end,
          runtime_start: fn repo, _config, _env ->
            attempt =
              Agent.get_and_update(attempts, fn counts ->
                next_attempt = Map.get(counts, repo.id, 0) + 1
                {next_attempt, Map.put(counts, repo.id, next_attempt)}
              end)

            send(parent, {:runtime_start_attempted, repo.id, attempt})

            {:ok, {:runtime, repo.id, attempt}}
          end,
          runtime_stop: fn handle, timeout_ms ->
            send(parent, {:runtime_stopped, handle, timeout_ms})
            :ok
          end,
          fetch_state: fn _port, _timeout_ms ->
            {:ok, %{"running" => [], "retrying" => []}}
          end
        )

      refute_receive {:runtime_start_attempted, "repo-a", _}

      initial_snapshot = Manager.snapshot(manager)

      assert Enum.any?(
               initial_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :blocked and
                   &1.blocked_reason == "local_env_path does not exist: #{missing_env_path}" and not &1.running)
             )

      assert {:ok, persisted_config} = ManagerConfig.load_raw(fixture.config_path)

      updated_config =
        put_in(persisted_config, ["repos", Access.at(1), "enabled"], true)

      write_config!(fixture.config_path, updated_config)
      Agent.update(clock, &(&1 + 5_000))

      reloaded_snapshot = Manager.tick(manager)

      assert_receive {:runtime_start_attempted, "repo-b", 1}
      refute_receive {:runtime_start_attempted, "repo-a", _}

      assert Enum.any?(
               reloaded_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :blocked and
                   &1.blocked_reason == "local_env_path does not exist: #{missing_env_path}" and not &1.running)
             )

      assert Enum.any?(reloaded_snapshot.repos, &(&1.id == "repo-b" and &1.running and &1.health == :starting))
    end)
  end

  test "retries start failures with backoff instead of blocking the repo" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> Agent.get(clock, & &1) end,
          runtime_start: fn repo, _config, _env ->
            attempt =
              Agent.get_and_update(attempts, fn value ->
                next_value = value + 1
                {next_value, next_value}
              end)

            send(parent, {:runtime_start_attempted, repo.id, attempt})

            case attempt do
              1 -> {:error, :boom}
              _ -> {:ok, {:runtime, repo.id, attempt}}
            end
          end,
          runtime_stop: fn handle, timeout_ms ->
            send(parent, {:runtime_stopped, handle, timeout_ms})
            :ok
          end,
          fetch_state: fn _port, _timeout_ms ->
            {:ok, %{"running" => [], "retrying" => []}}
          end
        )

      assert_receive {:runtime_start_attempted, "repo-a", 1}

      first_failure_snapshot = Manager.snapshot(manager)

      assert Enum.any?(
               first_failure_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :backoff and &1.restart_attempts == 1 and
                   &1.next_start_time_ms == 5_000 and is_nil(&1.blocked_reason) and
                   &1.last_exit_status == :start_failed and &1.last_error == "start failure: :boom" and
                   not &1.running)
             )

      Agent.update(clock, &(&1 + 4_999))
      _ = Manager.tick(manager)
      refute_receive {:runtime_start_attempted, "repo-a", 2}

      Agent.update(clock, &(&1 + 1))
      recovered_snapshot = Manager.tick(manager)

      assert_receive {:runtime_start_attempted, "repo-a", 2}

      assert Enum.any?(
               recovered_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :starting and &1.running and is_nil(&1.blocked_reason))
             )
    end)
  end

  test "resets restart backoff after a repo starts successfully again" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> Agent.get(clock, & &1) end,
          runtime_start: fn repo, _config, _env ->
            ordinal = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
            handle = {:runtime, repo.id, ordinal}
            send(parent, {:runtime_started, handle})
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

      assert_receive {:runtime_started, first_handle}

      send(manager, {:runtime_exit, first_handle, 1})

      first_backoff_snapshot = Manager.snapshot(manager)

      assert Enum.any?(
               first_backoff_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :backoff and &1.restart_attempts == 1 and
                   &1.next_start_time_ms == 5_000 and not &1.running)
             )

      Agent.update(clock, &(&1 + 5_000))
      restarted_snapshot = Manager.tick(manager)

      assert_receive {:runtime_started, second_handle}
      refute second_handle == first_handle

      assert Enum.any?(
               restarted_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :starting and &1.restart_attempts == 0 and
                   &1.next_start_time_ms == 0 and &1.running)
             )

      send(manager, {:runtime_exit, second_handle, 1})

      second_backoff_snapshot = Manager.snapshot(manager)

      assert Enum.any?(
               second_backoff_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :backoff and &1.restart_attempts == 1 and
                   &1.next_start_time_ms == 10_000 and not &1.running)
             )
    end)
  end

  test "schedules restart backoff after runtime exit instead of tight looping" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> Agent.get(clock, & &1) end,
          runtime_start: fn repo, _config, _env ->
            ordinal = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
            handle = {:runtime, repo.id, ordinal}
            send(parent, {:runtime_started, handle})
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

      assert_receive {:runtime_started, first_handle}

      send(manager, {:runtime_exit, first_handle, 1})
      snapshot_after_exit = Manager.snapshot(manager)

      assert Enum.any?(
               snapshot_after_exit.repos,
               &(&1.id == "repo-a" and &1.health == :backoff and &1.next_start_time_ms == 5_000 and
                   &1.restart_attempts == 1 and not &1.running)
             )

      Agent.update(clock, &(&1 + 4_999))
      _ = Manager.tick(manager)
      refute_receive {:runtime_started, _second_handle}

      Agent.update(clock, &(&1 + 1))
      _ = Manager.tick(manager)
      assert_receive {:runtime_started, second_handle}
      refute second_handle == first_handle
    end)
  end

  test "restarts unhealthy repos after the configured failure threshold" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      failure_config =
        put_in(fixture.config, ["manager", "failure_threshold"], 2)

      write_config!(fixture.config_path, failure_config)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> Agent.get(clock, & &1) end,
          runtime_start: fn repo, _config, _env ->
            ordinal = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
            handle = {:runtime, repo.id, ordinal}
            send(parent, {:runtime_started, handle})
            {:ok, handle}
          end,
          runtime_stop: fn handle, timeout_ms ->
            send(parent, {:runtime_stopped, handle, timeout_ms})
            :ok
          end,
          fetch_state: fn _port, _timeout_ms ->
            {:error, :unhealthy}
          end
        )

      assert_receive {:runtime_started, first_handle}

      first_failure_snapshot = Manager.tick(manager)

      assert Enum.any?(
               first_failure_snapshot.repos,
               &(&1.id == "repo-a" and &1.failure_count == 1 and &1.health == :failing and &1.running)
             )

      second_failure_snapshot = Manager.tick(manager)
      assert_receive {:runtime_stopped, ^first_handle, 10_000}

      assert Enum.any?(
               second_failure_snapshot.repos,
               &(&1.id == "repo-a" and &1.health == :backoff and &1.restart_attempts == 1 and not &1.running)
             )
    end)
  end

  test "supports programmatic repo restarts" do
    with_manager_fixture!(fn fixture ->
      parent = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> 0 end,
          runtime_start: fn repo, _config, _env ->
            ordinal = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
            handle = {:runtime, repo.id, ordinal}
            send(parent, {:runtime_started, handle})
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

      assert_receive {:runtime_started, first_handle}
      assert {:ok, %{health: :starting, id: "repo-a", running: true}} = Manager.restart_repo(manager, "repo-a")
      assert_receive {:runtime_stopped, ^first_handle, 10_000}
      assert_receive {:runtime_started, second_handle}
      refute second_handle == first_handle
    end)
  end

  test "returns restart errors for disabled or missing repos" do
    with_manager_fixture!(fn fixture ->
      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> 0 end,
          runtime_start: fn repo, _config, _env ->
            {:ok, {:runtime, repo.id}}
          end,
          runtime_stop: fn _handle, _timeout_ms ->
            :ok
          end,
          fetch_state: fn _port, _timeout_ms ->
            {:ok, %{"running" => [], "retrying" => []}}
          end
        )

      assert {:error, :repo_disabled} = Manager.restart_repo(manager, "repo-b")
      assert {:error, :repo_not_found} = Manager.restart_repo(manager, "repo-missing")
    end)
  end

  test "stops running repos when the manager shuts down" do
    with_manager_fixture!(fn fixture ->
      parent = self()

      {:ok, manager} =
        Manager.start_link(
          config_path: fixture.config_path,
          name: nil,
          schedule_ticks: false,
          time_fn: fn -> 0 end,
          runtime_start: fn repo, _config, _env ->
            handle = {:runtime, repo.id, System.unique_integer([:positive])}
            send(parent, {:runtime_started, handle})
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

      assert_receive {:runtime_started, first_handle}
      assert :ok = GenServer.stop(manager)
      assert_receive {:runtime_stopped, ^first_handle, 10_000}
    end)
  end

  defp with_manager_fixture!(fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-manager-#{System.unique_integer([:positive])}"
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
        "http_timeout_seconds" => 5,
        "failure_threshold" => 3,
        "restart_backoff_seconds" => [5, 15, 30],
        "port_range" => %{"start" => 43_101, "end" => 43_105},
        "graceful_shutdown_seconds" => 10,
        "config_reload_seconds" => 5
      },
      "repos" => []
    }
  end

  defp repo_entry(root, repo_id, opts) do
    repo_path = Path.join(root, repo_id)
    workflow_basename = Keyword.get(opts, :workflow_basename, "WORKFLOW.md")
    workflow_path = Path.join([root, "workflows", repo_id, workflow_basename])
    logs_root = Keyword.get(opts, :logs_root, Path.join([root, "logs", repo_id]))
    local_env_path = Keyword.get(opts, :local_env_path, Path.join(repo_path, "local.env"))
    workflow_contents = Keyword.get(opts, :workflow_contents, "tracker:\n  kind: memory\n")
    local_env_contents = Keyword.get(opts, :local_env_contents, "LOCAL_ONLY=from_file\nOVERRIDE_ME=from_file\n")
    env = Keyword.get(opts, :env, %{"INLINE_ONLY" => "from_repo", "OVERRIDE_ME" => "from_repo"})

    File.mkdir_p!(repo_path)
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_contents)

    if Keyword.get(opts, :local_env?, true) do
      File.write!(local_env_path, local_env_contents)
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
      "env" => env
    }
  end

  defp write_config!(path, config) do
    File.write!(path, Jason.encode!(config, pretty: true) <> "\n")
  end
end
