defmodule SymphonyElixir.ManagerConfig do
  @moduledoc """
  Loader and validator for the legacy multi-repo manager `config.json`.
  """

  @default_port_range %{start: 43_100, end: 48_999}

  @type config_error :: {:config_error, String.t()}
  @type validation_result :: :ok | {:error, config_error()}
  @type load_result :: {:ok, map()} | {:error, config_error()}

  @spec default_config_path() :: Path.t()
  def default_config_path do
    Path.join([System.user_home!(), ".config", "symphony", "config.json"])
  end

  @spec load(Path.t()) :: load_result()
  def load(path \\ default_config_path()) do
    with {:ok, config} <- load_raw(path),
         :ok <- validate(config),
         {:ok, assigned_config} <- assign_missing_ports(config) do
      {:ok, assigned_config}
    end
  end

  @spec load_raw(Path.t()) :: {:ok, map()} | {:error, config_error()}
  def load_raw(path \\ default_config_path()) do
    expanded_path = Path.expand(path)

    with :ok <- ensure_file_exists(expanded_path),
         {:ok, payload} <- File.read(expanded_path),
         {:ok, decoded} <- Jason.decode(payload),
         :ok <- ensure_is_map(decoded, "Config root must be an object") do
      {:ok, decoded}
    else
      {:error, :enoent} ->
        {:error, {:config_error, "Config file does not exist: #{expanded_path}"}}

      {:error, reason} when is_atom(reason) ->
        {:error, {:config_error, "Failed to read config #{expanded_path}: #{inspect(reason)}"}}

      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:config_error, "Failed to parse JSON config #{expanded_path}: #{Exception.message(reason)}"}}

      {:error, _} = error ->
        error
    end
  end

  @spec validate(map()) :: validation_result()
  def validate(config) when is_map(config) do
    with :ok <- require_value(config["version"] == 1, "Config `version` must be 1"),
         :ok <- require_non_empty_string(config["symphony_repo"], "Config `symphony_repo` must be a non-empty string"),
         :ok <- require_non_empty_string(config["symphony_bin"], "Config `symphony_bin` must be a non-empty string"),
         {:ok, manager} <- require_object(config["manager"], "Config `manager` must be an object"),
         {:ok, manager} <- validate_manager(manager),
         {:ok, repos} <- require_list(config["repos"], "Config `repos` must be a list"),
         :ok <- validate_repos(repos, manager) do
      :ok
    end
  end

  def validate(_config), do: {:error, {:config_error, "Config root must be an object"}}

  @spec assign_missing_ports(map()) :: {:ok, map()} | {:error, config_error()}
  def assign_missing_ports(config) when is_map(config) do
    with :ok <- validate(config),
         {:ok, manager} <- require_object(config["manager"], "Config `manager` must be an object"),
         {:ok, port_range} <- require_object(manager["port_range"], "Manager `port_range` must be an object"),
         {:ok, start_port} <- require_positive_integer(port_range["start"], "Manager `port_range` must contain valid integer `start` and `end`"),
         {:ok, end_port} <- require_positive_integer(port_range["end"], "Manager `port_range` must contain valid integer `start` and `end`"),
         :ok <- require_value(end_port >= start_port, "Manager `port_range` must contain valid integer `start` and `end`") do
      allocated =
        config["repos"]
        |> Enum.filter(&is_map/1)
        |> Enum.map(& &1["port"])
        |> Enum.filter(&is_integer/1)
        |> MapSet.new()

      with {:ok, repos} <- assign_ports_for_repos(config["repos"], start_port, end_port, allocated) do
        assigned_config =
          if changed?(config["repos"], repos) do
            Map.put(config, "repos", repos)
          else
            config
          end

        {:ok, assigned_config}
      end
    end
  end

  def assign_missing_ports(_config), do: {:error, {:config_error, "Config root must be an object"}}

  defp validate_manager(manager) do
    with :ok <- validate_positive_integer_field(manager, "check_interval_seconds"),
         :ok <- validate_positive_integer_field(manager, "http_timeout_seconds"),
         :ok <- validate_positive_integer_field(manager, "failure_threshold"),
         :ok <- validate_positive_integer_field(manager, "graceful_shutdown_seconds"),
         :ok <- validate_positive_integer_field(manager, "config_reload_seconds"),
         :ok <- validate_restart_backoff(manager["restart_backoff_seconds"]),
         {:ok, port_range} <- require_object(manager["port_range"], "Manager `port_range` must be an object"),
         :ok <- validate_port_range(port_range) do
      {:ok, Map.put(manager, "port_range", normalize_port_range(port_range))}
    end
  end

  defp validate_repos(repos, manager) do
    start_port = get_in(manager, ["port_range", "start"]) || @default_port_range.start
    end_port = get_in(manager, ["port_range", "end"]) || @default_port_range.end

    Enum.reduce_while(repos, {%{}, MapSet.new()}, fn entry, {ids, ports} ->
      with {:ok, repo} <- parse_repo(entry),
           :ok <- require_value(not Map.has_key?(ids, repo.id), "Duplicate repo id `#{repo.id}`"),
           :ok <- validate_repo_port(repo, ports, start_port, end_port) do
        next_ports =
          case repo.port do
            nil -> ports
            port -> MapSet.put(ports, port)
          end

        {:cont, {Map.put(ids, repo.id, true), next_ports}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {_ids, _ports} -> :ok
    end
  end

  defp parse_repo(entry) when is_map(entry) do
    with {:ok, repo_id} <- require_non_empty_string_value(entry["id"], "Repo field `id` must be a non-empty string"),
         {:ok, _name} <- require_non_empty_string_value(entry["name"], "Repo field `name` must be a non-empty string"),
         {:ok, _repo_path} <- require_non_empty_string_value(entry["repo_path"], "Repo field `repo_path` must be a non-empty string"),
         {:ok, _workflow_path} <- require_non_empty_string_value(entry["workflow_path"], "Repo field `workflow_path` must be a non-empty string"),
         {:ok, _logs_root} <- require_non_empty_string_value(entry["logs_root"], "Repo field `logs_root` must be a non-empty string"),
         :ok <- validate_optional_non_empty_string(entry["local_env_path"], "Repo `#{repo_id}` field `local_env_path` must be a non-empty string when present"),
         :ok <- validate_repo_enabled(entry, repo_id),
         :ok <- validate_repo_env(entry, repo_id),
         :ok <- validate_repo_port_shape(entry, repo_id) do
      {:ok, %{id: repo_id, port: entry["port"]}}
    end
  end

  defp parse_repo(_entry), do: {:error, {:config_error, "Each repo entry must be an object"}}

  defp validate_repo_enabled(entry, repo_id) do
    case Map.get(entry, "enabled", true) do
      value when is_boolean(value) -> :ok
      _ -> {:error, {:config_error, "Repo `#{repo_id}` field `enabled` must be a boolean"}}
    end
  end

  defp validate_repo_env(entry, repo_id) do
    case Map.get(entry, "env", %{}) do
      env when is_map(env) and valid_env_map?(env) ->
        :ok

      _ ->
        {:error, {:config_error, "Repo `#{repo_id}` field `env` must be an object of string pairs"}}
    end
  end

  defp validate_repo_port_shape(entry, repo_id) do
    case Map.get(entry, "port") do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _ -> {:error, {:config_error, "Repo `#{repo_id}` field `port` must be a positive integer when present"}}
    end
  end

  defp validate_repo_port(%{port: nil}, _ports, _start_port, _end_port), do: :ok

  defp validate_repo_port(%{id: repo_id, port: port}, ports, start_port, end_port) do
    cond do
      port < start_port or port > end_port ->
        {:error, {:config_error, "Repo `#{repo_id}` port #{port} must be inside configured port range #{start_port}-#{end_port}"}}

      MapSet.member?(ports, port) ->
        {:error, {:config_error, "Duplicate port #{port} across repos"}}

      true ->
        :ok
    end
  end

  defp validate_positive_integer_field(manager, field_name) do
    message = "Manager field `#{field_name}` must be a positive integer"

    case Map.get(manager, field_name) do
      value when is_integer(value) and value > 0 -> :ok
      _ -> {:error, {:config_error, message}}
    end
  end

  defp validate_restart_backoff(backoff) when is_list(backoff) do
    if backoff != [] and Enum.all?(backoff, &(is_integer(&1) and &1 > 0)) do
      :ok
    else
      {:error, {:config_error, "Manager `restart_backoff_seconds` must be a non-empty list of positive integers"}}
    end
  end

  defp validate_restart_backoff(_backoff) do
    {:error, {:config_error, "Manager `restart_backoff_seconds` must be a non-empty list of positive integers"}}
  end

  defp validate_port_range(port_range) do
    with {:ok, start_port} <-
           require_positive_integer(
             port_range["start"],
             "Manager `port_range` must contain valid integer `start` and `end`"
           ),
         {:ok, end_port} <-
           require_positive_integer(
             port_range["end"],
             "Manager `port_range` must contain valid integer `start` and `end`"
           ),
         :ok <-
           require_value(
             end_port >= start_port,
             "Manager `port_range` must contain valid integer `start` and `end`"
           ) do
      :ok
    end
  end

  defp require_object(value, message) when is_map(value), do: {:ok, value}
  defp require_object(_value, message), do: {:error, {:config_error, message}}

  defp require_list(value, message) when is_list(value), do: {:ok, value}
  defp require_list(_value, message), do: {:error, {:config_error, message}}

  defp require_non_empty_string(value, message) do
    case require_non_empty_string_value(value, message) do
      {:ok, _value} -> :ok
      {:error, _} = error -> error
    end
  end

  defp require_non_empty_string_value(value, message) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, {:config_error, message}}
    else
      {:ok, value}
    end
  end

  defp require_non_empty_string_value(_value, message), do: {:error, {:config_error, message}}

  defp validate_optional_non_empty_string(nil, _message), do: :ok

  defp validate_optional_non_empty_string(value, message) do
    case require_non_empty_string_value(value, message) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp require_positive_integer(value, message) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp require_positive_integer(_value, message), do: {:error, {:config_error, message}}

  defp require_value(true, _message), do: :ok
  defp require_value(false, message), do: {:error, {:config_error, message}}

  defp valid_env_map?(env) do
    Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  defp assign_ports_for_repos(repos, start_port, end_port, allocated) do
    Enum.reduce_while(repos, {:ok, [], allocated}, fn repo, {:ok, acc, reserved} ->
      case repo do
        %{"port" => nil} = repo_entry ->
          case choose_available_port(start_port, end_port, reserved) do
            {:ok, port} ->
              {:cont, {:ok, [Map.put(repo_entry, "port", port) | acc], MapSet.put(reserved, port)}}

            {:error, _} = error ->
              {:halt, error}
          end

        %{} = repo_entry ->
          {:cont, {:ok, [repo_entry | acc], reserved}}

        other ->
          {:cont, {:ok, [other | acc], reserved}}
      end
    end)
    |> case do
      {:ok, acc, _reserved} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  defp choose_available_port(start_port, end_port, reserved) do
    start_port..end_port
    |> Enum.find(fn port ->
      not MapSet.member?(reserved, port) and loopback_port_available?(port)
    end)
    |> case do
      nil -> {:error, {:config_error, "No available loopback ports in range #{start_port}-#{end_port}"}}
      port -> {:ok, port}
    end
  end

  defp loopback_port_available?(port) do
    ipv4? = can_bind?(:inet, {127, 0, 0, 1}, port)
    ipv6? = can_bind?(:inet6, {0, 0, 0, 0, 0, 0, 0, 1}, port)
    ipv4? and ipv6?
  end

  defp can_bind?(family, host, port) do
    case :gen_tcp.listen(port, [:binary, family, {:ip, host}, {:active, false}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp changed?(left, right), do: left != right

  defp normalize_port_range(port_range) do
    %{"start" => port_range["start"], "end" => port_range["end"]}
  end

  defp ensure_is_map(value, _message) when is_map(value), do: :ok
  defp ensure_is_map(_value, message), do: {:error, {:config_error, message}}

  defp ensure_file_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, :enoent}
  end
end
