defmodule SymphonyElixir.Manager do
  @moduledoc """
  Supervises one Symphony runtime per enabled repo from the manager `config.json`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.ManagerConfig
  alias SymphonyElixir.ManagerConfig.Repo, as: RepoConfig

  @line_bytes 1_048_576

  defmodule RepoState do
    @moduledoc false

    @enforce_keys [:repo]
    defstruct repo: nil,
              runtime: nil,
              failure_count: 0,
              restart_attempts: 0,
              next_start_time_ms: 0,
              blocked_reason: nil,
              blocked_until_config_change: false,
              last_health: :stopped,
              last_state_payload: nil,
              last_exit_status: nil,
              last_error: nil

    @type health :: :backoff | :blocked | :disabled | :failing | :ok | :starting | :stopped

    @type t :: %__MODULE__{
            repo: RepoConfig.t(),
            runtime: term() | nil,
            failure_count: non_neg_integer(),
            restart_attempts: non_neg_integer(),
            next_start_time_ms: integer(),
            blocked_reason: String.t() | nil,
            blocked_until_config_change: boolean(),
            last_health: health(),
            last_state_payload: map() | nil,
            last_exit_status: term() | nil,
            last_error: String.t() | nil
          }
  end

  defmodule State do
    @moduledoc false

    defstruct config_path: nil,
              config: nil,
              config_mtime: nil,
              last_config_check_ms: nil,
              schedule_ticks: true,
              tick_ref: nil,
              time_fn: nil,
              runtime_start: nil,
              runtime_stop: nil,
              fetch_state: nil,
              repos: %{}

    @type t :: %__MODULE__{
            config_path: Path.t(),
            config: map() | nil,
            config_mtime: integer() | nil,
            last_config_check_ms: integer() | nil,
            schedule_ticks: boolean(),
            tick_ref: reference() | nil,
            time_fn: (-> integer()),
            runtime_start: (RepoConfig.t(), map(), map() -> {:ok, term()} | {:error, term()}),
            runtime_stop: (term(), non_neg_integer() -> :ok),
            fetch_state: (pos_integer(), non_neg_integer() -> {:ok, map()} | {:error, term()}),
            repos: %{optional(String.t()) => RepoState.t()}
          }
  end

  @type option ::
          {:config_path, Path.t()}
          | {:name, GenServer.name()}
          | {:schedule_ticks, boolean()}
          | {:time_fn, (-> integer())}
          | {:runtime_start, (RepoConfig.t(), map(), map() -> {:ok, term()} | {:error, term()})}
          | {:runtime_stop, (term(), non_neg_integer() -> :ok)}
          | {:fetch_state, (pos_integer(), non_neg_integer() -> {:ok, map()} | {:error, term()})}

  @type snapshot :: %{
          config_path: Path.t(),
          config_mtime: integer() | nil,
          repos: [map()]
        }

  @type repo_api_error :: :repo_disabled | :repo_not_found | :repo_unavailable | :unavailable
  @type repo_api_response :: {:ok, non_neg_integer(), map()} | {:error, repo_api_error}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @spec snapshot(GenServer.server()) :: snapshot() | :unavailable
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _ -> :unavailable
  end

  @spec tick(GenServer.server()) :: snapshot()
  def tick(server \\ __MODULE__) do
    GenServer.call(server, :tick)
  end

  @spec reload_config(GenServer.server()) :: snapshot()
  def reload_config(server \\ __MODULE__) do
    GenServer.call(server, :reload_config)
  end

  @spec repo(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, :repo_not_found | :unavailable}
  def repo(server \\ __MODULE__, repo_id) when is_binary(repo_id) do
    GenServer.call(server, {:repo, repo_id})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec repo_state(GenServer.server(), String.t()) :: repo_api_response()
  def repo_state(server \\ __MODULE__, repo_id) when is_binary(repo_id) do
    GenServer.call(server, {:repo_state, repo_id})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec repo_issue(GenServer.server(), String.t(), String.t()) :: repo_api_response()
  def repo_issue(server \\ __MODULE__, repo_id, issue_identifier)
      when is_binary(repo_id) and is_binary(issue_identifier) do
    GenServer.call(server, {:repo_issue, repo_id, issue_identifier})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec restart_repo(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, :repo_disabled | :repo_not_found | :unavailable}
  def restart_repo(server \\ __MODULE__, repo_id) when is_binary(repo_id) do
    GenServer.call(server, {:restart_repo, repo_id})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec restart(GenServer.server()) :: :ok | {:error, :unavailable}
  def restart(server \\ __MODULE__) do
    GenServer.call(server, :restart)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    state = %State{
      config_path: Path.expand(Keyword.fetch!(opts, :config_path)),
      schedule_ticks: Keyword.get(opts, :schedule_ticks, true),
      time_fn: Keyword.get(opts, :time_fn, fn -> System.monotonic_time(:millisecond) end),
      runtime_start: Keyword.get(opts, :runtime_start, &default_runtime_start/3),
      runtime_stop: Keyword.get(opts, :runtime_stop, &default_runtime_stop/2),
      fetch_state: Keyword.get(opts, :fetch_state, &default_fetch_state/2)
    }

    case do_tick(state, force_reload: true) do
      {:ok, next_state} -> {:ok, schedule_next_tick(next_state)}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call({:repo, repo_id}, _from, state) do
    case Map.get(state.repos, repo_id) do
      nil -> {:reply, {:error, :repo_not_found}, state}
      repo_state -> {:reply, {:ok, repo_snapshot(repo_state)}, state}
    end
  end

  def handle_call({:repo_state, repo_id}, _from, state) do
    {:reply, repo_state_response(state, repo_id), state}
  end

  def handle_call({:repo_issue, repo_id, issue_identifier}, _from, state) do
    {:reply, repo_issue_response(state, repo_id, issue_identifier), state}
  end

  def handle_call(:tick, _from, state) do
    {:ok, next_state} = do_tick(state)
    {:reply, snapshot_from_state(next_state), schedule_next_tick(next_state)}
  end

  def handle_call(:reload_config, _from, state) do
    {:ok, next_state} = do_tick(state, force_reload: true)
    {:reply, snapshot_from_state(next_state), schedule_next_tick(next_state)}
  end

  def handle_call({:restart_repo, repo_id}, _from, state) do
    case Map.get(state.repos, repo_id) do
      nil ->
        {:reply, {:error, :repo_not_found}, state}

      %RepoState{repo: %RepoConfig{enabled: false}} ->
        {:reply, {:error, :repo_disabled}, state}

      repo_state ->
        refreshed_repo_state =
          repo_state
          |> stop_repo_runtime(state, "manual restart")
          |> Map.put(:blocked_reason, nil)
          |> Map.put(:blocked_until_config_change, false)
          |> Map.put(:next_start_time_ms, state.time_fn.())
          |> Map.put(:last_exit_status, :manual_restart)

        next_state =
          %{state | repos: Map.put(state.repos, repo_id, refreshed_repo_state)}
          |> reconcile()
          |> schedule_next_tick()

        {:reply, {:ok, repo_snapshot(Map.fetch!(next_state.repos, repo_id))}, next_state}
    end
  end

  def handle_call(:restart, _from, state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {:ok, next_state} = do_tick(state)
    {:noreply, schedule_next_tick(next_state)}
  end

  def handle_info({runtime, {:data, _data}}, state) when is_port(runtime) do
    {:noreply, state}
  end

  def handle_info({runtime, {:exit_status, status}}, state) when is_port(runtime) do
    {:noreply, handle_runtime_exit(state, runtime, status)}
  end

  def handle_info({:runtime_exit, runtime, status}, state) do
    {:noreply, handle_runtime_exit(state, runtime, status)}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_all_runtimes(state, "manager shutdown")
    :ok
  end

  defp do_tick(state, opts \\ []) do
    force_reload = Keyword.get(opts, :force_reload, false)

    with {:ok, loaded_state} <- maybe_reload_config(state, force_reload) do
      {:ok, reconcile(loaded_state)}
    end
  end

  defp maybe_reload_config(state, force_reload) do
    now = state.time_fn.()

    case config_mtime(state.config_path) do
      {:ok, current_mtime} ->
        maybe_reload_config_with_mtime(state, force_reload, now, current_mtime)

      {:error, _reason} when is_nil(state.config) ->
        load_manager_config(state, now, nil)

      {:error, reason} ->
        maybe_handle_config_stat_error(state, now, reason)
    end
  end

  defp maybe_reload_config_with_mtime(state, force_reload, now, current_mtime) do
    if force_reload or is_nil(state.config) or should_reload_config?(state, now, current_mtime) do
      load_manager_config(state, now, current_mtime)
    else
      {:ok, state}
    end
  end

  defp load_manager_config(state, now, current_mtime) do
    case ManagerConfig.load_and_persist(state.config_path) do
      {:ok, config} ->
        {:ok,
         %{
           state
           | config: config,
             config_mtime: refreshed_config_mtime(state.config_path, current_mtime),
             last_config_check_ms: now,
             repos: clear_blocked_repo_markers(state.repos)
         }}

      {:error, reason} ->
        Logger.warning("manager config_reload_failed config_path=#{state.config_path} reason=#{inspect(reason)}")

        config_reload_error(state, now, reason)
    end
  end

  defp config_reload_error(%State{config: nil}, _now, reason), do: {:error, reason}
  defp config_reload_error(state, now, _reason), do: {:ok, %{state | last_config_check_ms: now}}

  defp maybe_handle_config_stat_error(state, now, reason) do
    Logger.warning("manager config_stat_failed config_path=#{state.config_path} reason=#{inspect(reason)}")

    {:ok, %{state | last_config_check_ms: now}}
  end

  defp reconcile(state) do
    desired_repo_ids =
      state.config["repos"]
      |> Enum.reduce(MapSet.new(), fn entry, acc ->
        {:ok, repo} = ManagerConfig.parse_repo(entry)
        MapSet.put(acc, repo.id)
      end)

    managed_repos =
      Enum.reduce(state.config["repos"], state.repos, fn entry, repos ->
        {:ok, repo} = ManagerConfig.parse_repo(entry)
        existing_state = Map.get(repos, repo.id, %RepoState{repo: repo})
        repo_state = maybe_apply_repo_config_change(state, existing_state, repo)

        reconciled_repo =
          cond do
            not repo.enabled ->
              repo_state
              |> stop_repo_runtime(state, "repo disabled")
              |> Map.put(:blocked_reason, nil)
              |> Map.put(:blocked_until_config_change, false)
              |> Map.put(:last_health, :disabled)

            repo_state.blocked_until_config_change ->
              %{repo_state | last_health: :blocked}

            true ->
              ensure_repo_running(state, repo_state)
          end

        Map.put(repos, repo.id, reconciled_repo)
      end)

    final_repos =
      Enum.reduce(Map.keys(managed_repos), managed_repos, fn repo_id, repos ->
        if MapSet.member?(desired_repo_ids, repo_id) do
          repos
        else
          repo_state = Map.fetch!(repos, repo_id)
          _ = stop_repo_runtime(repo_state, state, "repo removed from config")
          Map.delete(repos, repo_id)
        end
      end)

    %{state | repos: final_repos}
  end

  defp maybe_apply_repo_config_change(state, existing_state, repo) do
    repo_state = %{existing_state | repo: repo}

    if runtime_config_changed?(existing_state.repo, repo) do
      changed_fields = changed_runtime_fields(existing_state.repo, repo)

      Logger.info("manager repo_config_changed repo_id=#{repo.id} fields=#{Enum.join(changed_fields, ",")}")

      repo_state
      |> stop_repo_runtime(state, "repo config changed")
      |> Map.put(:failure_count, 0)
      |> Map.put(:restart_attempts, 0)
      |> Map.put(:next_start_time_ms, state.time_fn.())
      |> Map.put(:blocked_reason, nil)
      |> Map.put(:blocked_until_config_change, false)
      |> Map.put(:last_exit_status, :config_reloaded)
      |> Map.put(:last_error, nil)
    else
      repo_state
    end
  end

  defp ensure_repo_running(state, %RepoState{repo: %RepoConfig{port: nil}} = repo_state) do
    block_repo(state, repo_state, "repo has no assigned port after config load")
  end

  defp ensure_repo_running(state, %RepoState{runtime: nil} = repo_state) do
    if state.time_fn.() >= repo_state.next_start_time_ms do
      start_repo_runtime(state, repo_state)
    else
      %{repo_state | last_health: :backoff}
    end
  end

  defp ensure_repo_running(state, repo_state) do
    timeout_ms = manager_http_timeout_ms(state.config)

    case state.fetch_state.(repo_state.repo.port, timeout_ms) do
      {:ok, payload} when is_map(payload) ->
        %{
          repo_state
          | failure_count: 0,
            last_health: :ok,
            last_state_payload: payload,
            last_error: nil
        }

      {:ok, _payload} ->
        handle_health_failure(state, repo_state, "state endpoint returned a non-object payload")

      {:error, reason} ->
        handle_health_failure(state, repo_state, format_reason(reason))
    end
  end

  defp handle_health_failure(state, repo_state, reason) do
    failure_count = repo_state.failure_count + 1
    threshold = state.config["manager"]["failure_threshold"]

    Logger.warning("manager repo_health_failed repo_id=#{repo_state.repo.id} failure=#{failure_count} threshold=#{threshold} reason=#{reason}")

    if failure_count < threshold do
      %{repo_state | failure_count: failure_count, last_health: :failing, last_error: reason}
    else
      repo_state
      |> stop_repo_runtime(state, "health check threshold reached")
      |> schedule_restart(state, "health check failure")
    end
  end

  defp start_repo_runtime(state, repo_state) do
    with :ok <- validate_repo_prerequisites(state.config, repo_state.repo),
         :ok <- File.mkdir_p(repo_state.repo.logs_root),
         {:ok, runtime_env} <- runtime_env(repo_state.repo) do
      case state.runtime_start.(repo_state.repo, state.config, runtime_env) do
        {:ok, runtime} ->
          Logger.info("manager repo_started repo_id=#{repo_state.repo.id} port=#{repo_state.repo.port}")

          %{
            repo_state
            | runtime: runtime,
              failure_count: 0,
              restart_attempts: 0,
              next_start_time_ms: 0,
              blocked_reason: nil,
              blocked_until_config_change: false,
              last_health: :starting,
              last_exit_status: nil,
              last_error: nil
          }

        {:error, reason} ->
          schedule_start_retry(repo_state, state, format_reason(reason))
      end
    else
      {:error, reason} ->
        block_repo(state, repo_state, format_reason(reason))
    end
  end

  defp schedule_start_retry(repo_state, state, reason) do
    repo_state
    |> Map.put(:blocked_reason, nil)
    |> Map.put(:blocked_until_config_change, false)
    |> Map.put(:last_exit_status, :start_failed)
    |> Map.put(:last_state_payload, nil)
    |> schedule_restart(state, "start failure: #{reason}")
  end

  defp block_repo(state, repo_state, reason) do
    Logger.error("manager repo_blocked repo_id=#{repo_state.repo.id} reason=#{reason}")

    repo_state
    |> stop_repo_runtime(state, "blocking repo: #{reason}")
    |> Map.put(:blocked_reason, reason)
    |> Map.put(:blocked_until_config_change, true)
    |> Map.put(:next_start_time_ms, 0)
    |> Map.put(:last_health, :blocked)
    |> Map.put(:last_error, reason)
  end

  defp schedule_restart(repo_state, state, reason) do
    backoff_steps = state.config["manager"]["restart_backoff_seconds"]
    index = min(repo_state.restart_attempts, length(backoff_steps) - 1)
    delay_ms = Enum.at(backoff_steps, index) * 1_000
    next_start_time_ms = state.time_fn.() + delay_ms

    Logger.warning("manager repo_restart_scheduled repo_id=#{repo_state.repo.id} delay_ms=#{delay_ms} reason=#{reason}")

    %{
      repo_state
      | restart_attempts: repo_state.restart_attempts + 1,
        next_start_time_ms: next_start_time_ms,
        last_health: :backoff,
        last_error: reason
    }
  end

  defp stop_repo_runtime(%RepoState{runtime: nil} = repo_state, _state, _reason), do: repo_state

  defp stop_repo_runtime(repo_state, state, reason) do
    Logger.info("manager repo_stopped repo_id=#{repo_state.repo.id} reason=#{reason}")
    graceful_timeout_ms = state.config["manager"]["graceful_shutdown_seconds"] * 1_000
    :ok = state.runtime_stop.(repo_state.runtime, graceful_timeout_ms)

    %{
      repo_state
      | runtime: nil,
        failure_count: 0,
        last_health: :stopped,
        last_state_payload: nil,
        last_error: format_reason(reason)
    }
  end

  defp handle_runtime_exit(state, runtime, status) do
    case Enum.find(state.repos, fn {_repo_id, repo_state} -> repo_state.runtime == runtime end) do
      nil ->
        state

      {repo_id, repo_state} ->
        Logger.warning("manager repo_exited repo_id=#{repo_id} exit_status=#{inspect(status)}")

        next_repo_state =
          repo_state
          |> Map.put(:runtime, nil)
          |> Map.put(:last_exit_status, status)
          |> Map.put(:last_state_payload, nil)
          |> schedule_restart(state, "process exit")

        %{state | repos: Map.put(state.repos, repo_id, next_repo_state)}
    end
  end

  defp validate_repo_prerequisites(config, repo) do
    symphony_bin = Path.expand(config["symphony_bin"])

    cond do
      is_nil(repo.port) ->
        {:error, "repo has no assigned port"}

      not File.dir?(repo.repo_path) ->
        {:error, "repo_path does not exist: #{repo.repo_path}"}

      not File.regular?(repo.workflow_path) ->
        {:error, "workflow_path does not exist: #{repo.workflow_path}"}

      repo.local_env_path != nil and not File.regular?(repo.local_env_path) ->
        {:error, "local_env_path does not exist: #{repo.local_env_path}"}

      not File.exists?(symphony_bin) ->
        {:error, "symphony_bin does not exist: #{symphony_bin}"}

      true ->
        :ok
    end
  end

  defp runtime_env(%RepoConfig{local_env_path: nil, env: env}) do
    {:ok, Map.merge(System.get_env(), env)}
  end

  defp runtime_env(%RepoConfig{local_env_path: local_env_path, env: env}) do
    with {:ok, file_env} <- ManagerConfig.load_env_file(local_env_path) do
      {:ok,
       System.get_env()
       |> Map.merge(file_env)
       |> Map.merge(env)}
    end
  end

  defp snapshot_from_state(state) do
    %{
      config_path: state.config_path,
      config_mtime: state.config_mtime,
      repos:
        state.repos
        |> Map.values()
        |> Enum.sort_by(& &1.repo.id)
        |> Enum.map(&repo_snapshot/1)
    }
  end

  defp repo_snapshot(repo_state) do
    %{
      id: repo_state.repo.id,
      name: repo_state.repo.name,
      enabled: repo_state.repo.enabled,
      repo_path: repo_state.repo.repo_path,
      workflow_path: repo_state.repo.workflow_path,
      logs_root: repo_state.repo.logs_root,
      local_env_path: repo_state.repo.local_env_path,
      port: repo_state.repo.port,
      running: not is_nil(repo_state.runtime),
      health: repo_state.last_health,
      failure_count: repo_state.failure_count,
      restart_attempts: repo_state.restart_attempts,
      next_start_time_ms: repo_state.next_start_time_ms,
      blocked_reason: repo_state.blocked_reason,
      last_exit_status: repo_state.last_exit_status,
      last_error: repo_state.last_error,
      last_state_payload: repo_state.last_state_payload
    }
  end

  defp repo_state_response(state, repo_id) do
    with {:ok, repo_state} <- repo_state_lookup(state, repo_id) do
      proxy_repo_api(state, repo_state, "/api/v1/state")
    end
  end

  defp repo_issue_response(state, repo_id, issue_identifier) do
    with {:ok, repo_state} <- repo_state_lookup(state, repo_id) do
      proxy_repo_api(state, repo_state, "/api/v1/#{URI.encode(issue_identifier)}")
    end
  end

  defp repo_state_lookup(state, repo_id) do
    case Map.get(state.repos, repo_id) do
      nil ->
        {:error, :repo_not_found}

      %RepoState{repo: %RepoConfig{enabled: false}} ->
        {:error, :repo_disabled}

      %RepoState{runtime: nil} ->
        {:error, :repo_unavailable}

      %RepoState{repo: %RepoConfig{port: nil}} ->
        {:error, :repo_unavailable}

      repo_state ->
        {:ok, repo_state}
    end
  end

  defp proxy_repo_api(state, repo_state, path) do
    url = "http://127.0.0.1:#{repo_state.repo.port}#{path}"

    with {:ok, response} <-
           Req.get(url, receive_timeout: manager_http_timeout_ms(state.config), retry: false),
         {:ok, payload} <- decode_repo_api_payload(response) do
      {:ok, response.status, payload}
    else
      {:error, _reason} ->
        {:error, :repo_unavailable}
    end
  end

  defp decode_repo_api_payload(%Req.Response{body: body}) when is_map(body), do: {:ok, body}

  defp decode_repo_api_payload(%Req.Response{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :non_map_repo_api_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_repo_api_payload(_response), do: {:error, :invalid_repo_api_payload}

  defp should_reload_config?(state, now, current_mtime) do
    reload_interval_ms = state.config["manager"]["config_reload_seconds"] * 1_000

    is_nil(state.last_config_check_ms) or
      now - state.last_config_check_ms >= reload_interval_ms or
      current_mtime != state.config_mtime
  end

  defp clear_blocked_repo_markers(repos) do
    Map.new(repos, fn {repo_id, repo_state} ->
      {repo_id, %{repo_state | blocked_reason: nil, blocked_until_config_change: false}}
    end)
  end

  defp runtime_config_changed?(%RepoConfig{} = previous_repo, %RepoConfig{} = repo) do
    changed_runtime_fields(previous_repo, repo) != []
  end

  defp changed_runtime_fields(%RepoConfig{} = previous_repo, %RepoConfig{} = repo) do
    [
      {:repo_path, previous_repo.repo_path, repo.repo_path},
      {:workflow_path, previous_repo.workflow_path, repo.workflow_path},
      {:logs_root, previous_repo.logs_root, repo.logs_root},
      {:local_env_path, previous_repo.local_env_path, repo.local_env_path},
      {:port, previous_repo.port, repo.port},
      {:env, previous_repo.env, repo.env}
    ]
    |> Enum.flat_map(fn {field, previous_value, value} ->
      if previous_value == value, do: [], else: [Atom.to_string(field)]
    end)
  end

  defp schedule_next_tick(%State{schedule_ticks: false} = state), do: %{state | tick_ref: nil}

  defp schedule_next_tick(state) do
    if is_reference(state.tick_ref) do
      Process.cancel_timer(state.tick_ref)
    end

    check_interval_ms =
      case state.config do
        %{"manager" => %{"check_interval_seconds" => seconds}}
        when is_integer(seconds) and seconds > 0 ->
          seconds * 1_000

        _ ->
          1_000
      end

    %{state | tick_ref: Process.send_after(self(), :tick, check_interval_ms)}
  end

  defp stop_all_runtimes(%State{config: nil}, _reason), do: :ok

  defp stop_all_runtimes(state, reason) do
    Enum.each(state.repos, fn {_repo_id, repo_state} ->
      _ = stop_repo_runtime(repo_state, state, reason)
    end)

    :ok
  end

  defp config_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat.mtime}
      {:error, reason} -> {:error, {:config_mtime_failed, path, reason}}
    end
  end

  defp refreshed_config_mtime(path, fallback_mtime) do
    case config_mtime(path) do
      {:ok, mtime} -> mtime
      {:error, _reason} -> fallback_mtime
    end
  end

  defp manager_http_timeout_ms(config) do
    config["manager"]["http_timeout_seconds"] * 1_000
  end

  defp default_runtime_start(repo, config, env) do
    executable = Path.expand(config["symphony_bin"])

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(runtime_args(repo), &String.to_charlist/1),
          cd: String.to_charlist(repo.repo_path),
          env:
            Enum.map(env, fn {key, value} ->
              {String.to_charlist(key), String.to_charlist(value)}
            end),
          line: @line_bytes
        ]
      )

    {:ok, port}
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp default_runtime_stop(runtime, _graceful_timeout_ms) when is_port(runtime) do
    case :erlang.port_info(runtime, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end

    try do
      Port.close(runtime)
    catch
      :error, _reason -> :ok
    end

    :ok
  end

  defp default_fetch_state(port, timeout_ms) do
    url = "http://127.0.0.1:#{port}/api/v1/state"

    with {:ok, response} <- Req.get(url, receive_timeout: timeout_ms, retry: false),
         {:ok, payload} <- decode_state_payload(response) do
      {:ok, payload}
    else
      {:error, _} = error -> error
    end
  end

  defp decode_state_payload(%Req.Response{status: 200, body: body}) when is_map(body),
    do: {:ok, body}

  defp decode_state_payload(%Req.Response{status: 200, body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :non_map_state_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_state_payload(%Req.Response{status: status}),
    do: {:error, {:unexpected_status, status}}

  defp runtime_args(repo) do
    [
      "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
      "--logs-root",
      repo.logs_root,
      "--port",
      Integer.to_string(repo.port),
      repo.workflow_path
    ]
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  if Code.ensure_loaded?(Mix) and Mix.env() == :test do
    @doc false
    def __test_decode_repo_api_payload__(response), do: decode_repo_api_payload(response)

    @doc false
    def __test_refreshed_config_mtime__(path, fallback_mtime),
      do: refreshed_config_mtime(path, fallback_mtime)
  end
end
