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
        {:ok, spawn(fn -> :ok end)}
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
        {:ok, spawn(fn -> :ok end)}
      end
    }

    assert :ok = ManagerCLI.evaluate(["--config", "tmp/manager.json", "run"], deps)
    assert_received {:manager_started, started_path}
    assert started_path == Path.expand("tmp/manager.json")
  end

  test "handles linked manager exits without crashing the caller" do
    parent = self()

    deps = %{
      ensure_all_started: fn -> {:ok, [:req]} end,
      start_manager: fn path ->
        send(parent, {:manager_started, path})
        {:ok, spawn_link(fn -> :ok end)}
      end
    }

    assert :ok = ManagerCLI.evaluate(["run"], deps)
    assert_received {:manager_started, started_path}
    assert started_path == SymphonyElixir.ManagerConfig.default_config_path()
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
end
