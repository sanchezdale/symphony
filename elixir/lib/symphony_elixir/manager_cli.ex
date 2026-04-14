defmodule SymphonyElixir.ManagerCLI do
  @moduledoc """
  CLI entrypoint for the multi-repo Symphony manager.
  """

  alias SymphonyElixir.{HttpServer, Manager, ManagerConfig}

  @switches [config: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          ensure_all_started: (-> ensure_started_result()),
          start_manager: (Path.t() -> GenServer.on_start()),
          start_http_server: (GenServer.server(), keyword() -> GenServer.on_start() | :ignore)
        }

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with {:ok, http_server_opts} <- http_server_opts(opts) do
          run_manager(Keyword.get(opts, :config, ManagerConfig.default_config_path()), http_server_opts, deps)
        end

      {opts, ["run"], []} ->
        with {:ok, http_server_opts} <- http_server_opts(opts) do
          run_manager(Keyword.get(opts, :config, ManagerConfig.default_config_path()), http_server_opts, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec usage_message() :: String.t()
  def usage_message do
    "Usage: symphony manager [--config <path>] [--port <port>] [run]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      ensure_all_started: &ensure_runtime_apps_started/0,
      start_manager: fn config_path -> Manager.start_link(config_path: config_path) end,
      start_http_server: fn manager, opts ->
        HttpServer.start_link(Keyword.put(opts, :manager, manager))
      end
    }
  end

  defp run_manager(config_path, http_server_opts, deps) do
    expanded_path = Path.expand(config_path)
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      with {:ok, _started_apps} <- deps.ensure_all_started.(),
           {:ok, pid} <- deps.start_manager.(expanded_path),
           {:ok, _http_server} <- maybe_start_http_server(pid, http_server_opts, deps) do
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
        Process.demonitor(ref, [:flush])
        :ok

      {:EXIT, ^pid, reason} ->
        Process.demonitor(ref, [:flush])
        {:error, "Symphony manager exited unexpectedly: #{inspect(reason)}"}

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Process.demonitor(ref, [:flush])
        {:error, "Symphony manager exited unexpectedly: #{inspect(reason)}"}
    end
  end

  defp http_server_opts(opts) do
    case Keyword.get_values(opts, :port) do
      [] ->
        {:ok, []}

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          {:ok, [port: port]}
        else
          {:error, usage_message()}
        end
    end
  end

  defp maybe_start_http_server(_manager, [], _deps), do: {:ok, nil}

  defp maybe_start_http_server(manager, http_server_opts, deps) do
    case deps.start_http_server.(manager, http_server_opts) do
      {:ok, _pid} = result -> result
      :ignore -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_runtime_apps_started do
    with {:ok, phoenix_apps} <- Application.ensure_all_started(:phoenix_live_view),
         {:ok, bandit_apps} <- Application.ensure_all_started(:bandit),
         {:ok, req_apps} <- Application.ensure_all_started(:req) do
      {:ok, Enum.uniq(phoenix_apps ++ bandit_apps ++ req_apps)}
    end
  end
end
