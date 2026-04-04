defmodule SymphonyElixir.ManagerCLI do
  @moduledoc """
  CLI entrypoint for the multi-repo Symphony manager.
  """

  alias SymphonyElixir.{Manager, ManagerConfig}

  @switches [config: :string]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          ensure_all_started: (-> ensure_started_result()),
          start_manager: (Path.t() -> GenServer.on_start())
        }

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        run_manager(Keyword.get(opts, :config, ManagerConfig.default_config_path()), deps)

      {opts, ["run"], []} ->
        run_manager(Keyword.get(opts, :config, ManagerConfig.default_config_path()), deps)

      _ ->
        {:error, usage_message()}
    end
  end

  @spec usage_message() :: String.t()
  def usage_message do
    "Usage: symphony manager [--config <path>] [run]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      ensure_all_started: fn -> Application.ensure_all_started(:req) end,
      start_manager: fn config_path -> Manager.start_link(config_path: config_path) end
    }
  end

  defp run_manager(config_path, deps) do
    expanded_path = Path.expand(config_path)
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      with {:ok, _started_apps} <- deps.ensure_all_started.(),
           {:ok, pid} <- deps.start_manager.(expanded_path) do
        wait_for_shutdown(pid, expanded_path)
      else
        {:error, reason} ->
          {:error, "Failed to start Symphony manager with config #{expanded_path}: #{inspect(reason)}"}
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp wait_for_shutdown(pid, _config_path) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:EXIT, ^pid, :normal} ->
        :ok

      {:EXIT, ^pid, reason} ->
        {:error, "Symphony manager exited unexpectedly: #{inspect(reason)}"}

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, "Symphony manager exited unexpectedly: #{inspect(reason)}"}
    end
  end
end
