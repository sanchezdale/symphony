defmodule SymphonyElixir.ManagerCLITest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{HttpServer, Manager, ManagerCLI}

  test "starts the manager with the default config path" do
    parent = self()

    deps = %{
      ensure_all_started: fn ->
        send(parent, :deps_started)
        {:ok, [:req]}
      end,
      start_manager: fn path ->
        send(parent, {:manager_started, path})
        {:ok, spawn_stub_process()}
      end
    }

    assert :ok = ManagerCLI.evaluate([], deps)
    assert_received :deps_started
    assert_received {:manager_started, path}
    assert path == SymphonyElixir.ManagerConfig.default_config_path()
  end

  test "accepts explicit config paths and the optional run subcommand" do
    parent = self()

    deps = %{
      ensure_all_started: fn -> {:ok, [:req]} end,
      start_manager: fn path ->
        send(parent, {:manager_started, path})
        {:ok, spawn_stub_process()}
      end
    }

    assert :ok = ManagerCLI.evaluate(["--config", "tmp/manager.json", "run"], deps)
    assert_received {:manager_started, started_path}
    assert started_path == Path.expand("tmp/manager.json")
  end

  test "starts the manager http server when a port is provided" do
    parent = self()

    deps = %{
      ensure_all_started: fn -> {:ok, [:phoenix_live_view, :bandit, :req]} end,
      start_manager: fn path ->
        send(parent, {:manager_started, path})
        {:ok, spawn_stub_process()}
      end,
      start_http_server: fn manager, opts ->
        send(parent, {:http_server_started, manager, opts})
        {:ok, spawn_stub_process()}
      end
    }

    assert :ok = ManagerCLI.evaluate(["--config", "tmp/manager.json", "--port", "4100", "run"], deps)
    assert_received {:manager_started, started_path}
    assert started_path == Path.expand("tmp/manager.json")
    assert_received {:http_server_started, manager, [port: 4100]}
    assert is_pid(manager)
  end

  test "accepts ignored manager http server starts" do
    deps = %{
      ensure_all_started: fn -> {:ok, [:phoenix_live_view, :bandit, :req]} end,
      start_manager: fn _path -> {:ok, spawn_stub_process()} end,
      start_http_server: fn _manager, _opts -> :ignore end
    }

    assert :ok = ManagerCLI.evaluate(["--port", "4100", "run"], deps)
  end

  test "returns startup errors when the manager http server cannot be started" do
    deps = %{
      ensure_all_started: fn -> {:ok, [:phoenix_live_view, :bandit, :req]} end,
      start_manager: fn _path -> {:ok, spawn_stub_process()} end,
      start_http_server: fn _manager, _opts -> {:error, :addr_in_use} end
    }

    assert {:error, message} = ManagerCLI.evaluate(["--port", "4100", "run"], deps)
    assert message =~ "Failed to start Symphony manager"
    assert message =~ ":addr_in_use"
  end

  test "rejects invalid manager http ports" do
    deps = %{
      ensure_all_started: fn -> flunk("deps should not start for invalid usage") end,
      start_manager: fn _path -> flunk("manager should not start for invalid usage") end,
      start_http_server: fn _manager, _opts -> flunk("http server should not start for invalid usage") end
    }

    assert {:error, message} = ManagerCLI.evaluate(["--port", "0", "run"], deps)
    assert message == ManagerCLI.usage_message()

    assert {:error, message} = ManagerCLI.evaluate(["--port", "65536", "run"], deps)
    assert message == ManagerCLI.usage_message()
  end

  test "handles linked manager exits without crashing the caller" do
    parent = self()

    deps = %{
      ensure_all_started: fn -> {:ok, [:req]} end,
      start_manager: fn path ->
        send(parent, {:manager_started, path})
        {:ok, spawn_stub_process(true)}
      end
    }

    assert :ok = ManagerCLI.evaluate(["run"], deps)
    assert_received {:manager_started, started_path}
    assert started_path == SymphonyElixir.ManagerConfig.default_config_path()
    refute_receive {:DOWN, _, :process, _, _}
  end

  test "surfaces unexpected linked manager exits" do
    deps = %{
      ensure_all_started: fn -> {:ok, [:req]} end,
      start_manager: fn _path ->
        {:ok,
         spawn_link(fn ->
           Process.sleep(25)
           Process.exit(self(), :boom)
         end)}
      end
    }

    assert {:error, message} = ManagerCLI.evaluate(["run"], deps)
    assert message =~ "Symphony manager exited unexpectedly"
    assert message =~ ":boom"
  end

  test "surfaces unexpected monitored manager exits" do
    deps = %{
      ensure_all_started: fn -> {:ok, [:req]} end,
      start_manager: fn _path ->
        {:ok,
         spawn(fn ->
           Process.sleep(25)
           Process.exit(self(), :boom)
         end)}
      end
    }

    assert {:error, message} = ManagerCLI.evaluate(["run"], deps)
    assert message =~ "Symphony manager exited unexpectedly"
    assert message =~ ":boom"
  end

  test "returns a startup error when support apps cannot be started" do
    deps = %{
      ensure_all_started: fn -> {:error, :req_down} end,
      start_manager: fn _path -> flunk("manager should not start when dependencies fail") end
    }

    assert {:error, message} = ManagerCLI.evaluate([], deps)
    assert message =~ "Failed to start Symphony manager"
    assert message =~ ":req_down"
  end

  test "returns usage for unsupported arguments" do
    deps = %{
      ensure_all_started: fn -> {:ok, [:req]} end,
      start_manager: fn _path -> flunk("manager should not start for invalid usage") end
    }

    assert {:error, message} = ManagerCLI.evaluate(["run", "extra"], deps)
    assert message == ManagerCLI.usage_message()
  end

  test "default runtime deps start support apps before surfacing missing config errors" do
    with_temp_home!(fn ->
      assert {:error, message} = ManagerCLI.evaluate(["run"])
      assert message =~ "Failed to start Symphony manager"
      assert message =~ "Config file does not exist"
    end)
  end

  test "default runtime deps start the manager http server when a port is provided" do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      if pid = Process.whereis(SymphonyElixirWeb.Endpoint) do
        GenServer.stop(pid)
      end

      if pid = Process.whereis(Manager) do
        GenServer.stop(pid)
      end
    end)

    with_cli_config!(fn config_path ->
      port = reserve_port!()

      task =
        Task.async(fn ->
          ManagerCLI.evaluate(["--config", config_path, "--port", Integer.to_string(port), "run"])
        end)

      try do
        wait_until!(fn ->
          Process.whereis(Manager) != nil and HttpServer.bound_port() == port
        end)

        assert HttpServer.bound_port() == port
        assert :ok = Manager.restart()
        assert :ok = Task.await(task, 5_000)
      after
        Task.shutdown(task, :brutal_kill)
      end
    end)
  end

  defp spawn_stub_process(linked? \\ false) do
    starter = fn -> Process.sleep(25) end
    if linked?, do: spawn_link(starter), else: spawn(starter)
  end

  defp with_temp_home!(fun) do
    temp_home = Path.join(System.tmp_dir!(), "manager-cli-home-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("HOME")
    File.mkdir_p!(temp_home)
    System.put_env("HOME", temp_home)

    try do
      fun.()
    after
      restore_env("HOME", previous_home)
      File.rm_rf(temp_home)
    end
  end

  defp with_cli_config!(fun) do
    root = Path.join(System.tmp_dir!(), "manager-cli-config-#{System.unique_integer([:positive])}")
    symphony_repo = Path.join(root, "symphony")
    symphony_bin = Path.join([symphony_repo, "elixir", "bin", "symphony"])
    config_path = Path.join(root, "config.json")

    File.mkdir_p!(Path.dirname(symphony_bin))
    File.write!(symphony_bin, "#!/bin/sh\nexit 0\n")
    File.chmod!(symphony_bin, 0o755)

    config = %{
      "version" => 1,
      "symphony_repo" => symphony_repo,
      "symphony_bin" => symphony_bin,
      "manager" => %{
        "check_interval_seconds" => 1,
        "http_timeout_seconds" => 1,
        "failure_threshold" => 3,
        "restart_backoff_seconds" => [5, 15, 30],
        "port_range" => %{"start" => 43_100, "end" => 43_105},
        "graceful_shutdown_seconds" => 10,
        "config_reload_seconds" => 5
      },
      "repos" => []
    }

    File.mkdir_p!(root)
    File.write!(config_path, Jason.encode!(config, pretty: true) <> "\n")

    try do
      fun.(config_path)
    after
      File.rm_rf(root)
    end
  end

  defp reserve_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_until!(predicate, timeout_ms \\ 5_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(predicate, deadline_ms)
  end

  defp do_wait_until(predicate, deadline_ms) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("condition was not met before timeout")
      else
        Process.sleep(20)
        do_wait_until(predicate, deadline_ms)
      end
    end
  end

  defp restore_env(_key, nil), do: System.delete_env("HOME")
  defp restore_env(key, value), do: System.put_env(key, value)
end
