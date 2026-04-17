defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end,
      run_manager: fn _args ->
        send(parent, :manager_run)
        :ok
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to the centralized workflow path when workflow path is missing" do
    expected_path = SymphonyElixir.Workflow.default_workflow_file_path()

    deps = %{
      file_regular?: fn path -> path == expected_path end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      run_manager: fn _args -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      run_manager: fn _args -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      run_manager: fn _args -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "rejects invalid workflow http ports" do
    deps = %{
      file_regular?: fn _path -> flunk("workflow path should not be checked for invalid usage") end,
      set_workflow_file_path: fn _path -> flunk("workflow path should not be set for invalid usage") end,
      set_logs_root: fn _path -> flunk("logs root should not be set for invalid usage") end,
      set_server_port_override: fn _port -> flunk("port override should not be set for invalid usage") end,
      ensure_all_started: fn -> flunk("app should not start for invalid usage") end,
      run_manager: fn _args -> flunk("manager should not run for workflow mode") end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "--port", "0", "WORKFLOW.md"], deps)
    assert message =~ "Usage: symphony"
    assert message =~ "--port <port>"

    assert {:error, message} = CLI.evaluate([@ack_flag, "--port", "65536", "WORKFLOW.md"], deps)
    assert message =~ "Usage: symphony"
    assert message =~ "--port <port>"
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      run_manager: fn _args -> :ok end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end,
      run_manager: fn _args -> :ok end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      run_manager: fn _args -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "dispatches the manager subcommand when acknowledged" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> flunk("workflow path should not be checked for manager mode") end,
      set_workflow_file_path: fn _path -> flunk("workflow path should not be set for manager mode") end,
      set_logs_root: fn _path -> flunk("logs root should not be set for manager mode") end,
      set_server_port_override: fn _port -> flunk("port override should not be set for manager mode") end,
      ensure_all_started: fn -> flunk("workflow app should not start for manager mode") end,
      run_manager: fn args ->
        send(parent, {:manager_run, args})
        :ok
      end
    }

    assert :manager_ok = CLI.evaluate(["manager", @ack_flag, "--config", "tmp/config.json"], deps)
    assert_received {:manager_run, ["--config", "tmp/config.json"]}
  end

  test "requires the guardrails acknowledgement for manager mode" do
    deps = %{
      file_regular?: fn _path -> flunk("workflow path should not be checked for manager mode") end,
      set_workflow_file_path: fn _path -> flunk("workflow path should not be set for manager mode") end,
      set_logs_root: fn _path -> flunk("logs root should not be set for manager mode") end,
      set_server_port_override: fn _port -> flunk("port override should not be set for manager mode") end,
      ensure_all_started: fn -> flunk("workflow app should not start for manager mode") end,
      run_manager: fn _args -> flunk("manager should not run without acknowledgement") end
    }

    assert {:error, message} = CLI.evaluate(["manager", "--config", "tmp/config.json"], deps)
    assert message =~ "This Symphony implementation is a low key engineering preview."
    assert message =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  end
end
