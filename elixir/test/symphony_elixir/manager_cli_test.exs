defmodule SymphonyElixir.ManagerCLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ManagerCLI

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

  defp spawn_stub_process(linked? \\ false) do
    starter = fn -> Process.sleep(25) end
    if linked?, do: spawn_link(starter), else: spawn(starter)
  end
end
