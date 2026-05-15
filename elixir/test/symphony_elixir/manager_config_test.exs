defmodule SymphonyElixir.ManagerConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ManagerConfig

  test "load_raw returns config map from JSON" do
    config = valid_config()

    with_temp_file!(Jason.encode!(config), fn path ->
      assert {:ok, ^config} = ManagerConfig.load_raw(path)
    end)
  end

  test "default-path loaders use HOME-scoped config.json" do
    config = valid_config()

    with_temp_home_config!(config, fn default_path ->
      assert default_path == ManagerConfig.default_config_path()
      assert {:ok, ^config} = ManagerConfig.load_raw()
      assert {:ok, assigned} = ManagerConfig.load()
      assert {:ok, persisted} = ManagerConfig.load_and_persist()

      assigned_port = get_in(assigned, ["repos", Access.at(1), "port"])
      assert is_integer(assigned_port)
      assert get_in(persisted, ["repos", Access.at(1), "port"]) == assigned_port
      assert {:ok, reloaded} = ManagerConfig.load_raw(default_path)
      assert get_in(reloaded, ["repos", Access.at(1), "port"]) == assigned_port
    end)
  end

  test "default_config_path falls back to System.user_home when HOME is unset" do
    previous_home = System.get_env("HOME")
    System.delete_env("HOME")

    try do
      assert ManagerConfig.default_config_path() ==
               Path.join([System.user_home!(), ".config", "symphony", "config.json"])
    after
      restore_env("HOME", previous_home)
    end
  end

  test "load_raw surfaces missing, unreadable, malformed, and non-map configs" do
    missing_path = Path.join(System.tmp_dir!(), "manager-config-missing-#{System.unique_integer([:positive])}.json")

    assert {:error, {:config_error, message}} = ManagerConfig.load_raw(missing_path)
    assert message =~ "Config file does not exist"

    with_temp_dir!(fn dir ->
      assert {:error, {:config_error, message}} = ManagerConfig.load_raw(dir)
      assert message =~ "Failed to read config"
      assert message =~ ":eisdir"
    end)

    with_temp_file!("{", fn path ->
      assert {:error, {:config_error, message}} = ManagerConfig.load_raw(path)
      assert message =~ "Failed to parse JSON config"
    end)

    with_temp_file!(Jason.encode!([1, 2, 3]), fn path ->
      assert {:error, {:config_error, "Config root must be an object"}} = ManagerConfig.load_raw(path)
    end)
  end

  test "validate accepts valid manager config" do
    assert :ok = ManagerConfig.validate(valid_config())
  end

  test "validate and assign_missing_ports reject non-map config roots" do
    assert {:error, {:config_error, "Config root must be an object"}} = ManagerConfig.validate([])
    assert {:error, {:config_error, "Config root must be an object"}} = ManagerConfig.assign_missing_ports([])
  end

  test "validate rejects duplicate repo ids" do
    config =
      valid_config()
      |> put_in(["repos", Access.at(1), "id"], "repo-a")

    assert {:error, {:config_error, "Duplicate repo id `repo-a`"}} = ManagerConfig.validate(config)
  end

  test "validate rejects duplicate ports" do
    config =
      valid_config()
      |> put_in(["repos", Access.at(1), "port"], 43_101)

    assert {:error, {:config_error, "Duplicate port 43101 across repos"}} = ManagerConfig.validate(config)
  end

  test "validate rejects out-of-range ports" do
    config = put_in(valid_config(), ["repos", Access.at(0), "port"], 50_000)

    assert {:error, {:config_error, message}} = ManagerConfig.validate(config)
    assert message =~ "must be inside configured port range 43100-43105"
  end

  test "validate rejects invalid env entries" do
    config = put_in(valid_config(), ["repos", Access.at(0), "env"], %{"OK" => 1})

    assert {:error, {:config_error, message}} = ManagerConfig.validate(config)
    assert message =~ "field `env` must be an object of string pairs"
  end

  test "validate rejects non-map repo env values" do
    config = put_in(valid_config(), ["repos", Access.at(0), "env"], "nope")

    assert {:error, {:config_error, message}} = ManagerConfig.validate(config)
    assert message =~ "field `env` must be an object of string pairs"
  end

  test "validate rejects malformed repo and manager fields" do
    invalid_symphony_repo = Map.put(valid_config(), "symphony_repo", "")
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_symphony_repo)
    assert message =~ "Config `symphony_repo` must be a non-empty string"

    invalid_enabled = put_in(valid_config(), ["repos", Access.at(0), "enabled"], "yes")
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_enabled)
    assert message =~ "field `enabled` must be a boolean"

    invalid_port = put_in(valid_config(), ["repos", Access.at(0), "port"], "43101")
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_port)
    assert message =~ "field `port` must be a positive integer"

    invalid_local_env = put_in(valid_config(), ["repos", Access.at(0), "local_env_path"], "")
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_local_env)
    assert message =~ "field `local_env_path` must be a non-empty string"

    invalid_restart_backoff = put_in(valid_config(), ["manager", "restart_backoff_seconds"], [])
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_restart_backoff)
    assert message =~ "restart_backoff_seconds"

    invalid_restart_backoff_type = put_in(valid_config(), ["manager", "restart_backoff_seconds"], "soon")
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_restart_backoff_type)
    assert message =~ "restart_backoff_seconds"

    invalid_check_interval = put_in(valid_config(), ["manager", "check_interval_seconds"], 0)
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_check_interval)
    assert message =~ "check_interval_seconds"

    invalid_port_range_shape = put_in(valid_config(), ["manager", "port_range", "start"], "43100")
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_port_range_shape)
    assert message =~ "port_range"

    invalid_port_range = put_in(valid_config(), ["manager", "port_range"], %{"start" => 43_105, "end" => 43_100})
    assert {:error, {:config_error, message}} = ManagerConfig.validate(invalid_port_range)
    assert message =~ "port_range"

    invalid_manager = Map.put(valid_config(), "manager", "bad")
    assert {:error, {:config_error, "Config `manager` must be an object"}} = ManagerConfig.validate(invalid_manager)

    invalid_repos = Map.put(valid_config(), "repos", %{})
    assert {:error, {:config_error, "Config `repos` must be a list"}} = ManagerConfig.validate(invalid_repos)

    invalid_repo_id = put_in(valid_config(), ["repos", Access.at(0), "id"], nil)
    assert {:error, {:config_error, "Repo field `id` must be a non-empty string"}} = ManagerConfig.validate(invalid_repo_id)
  end

  test "validate accepts optional local_env_path and env map" do
    config =
      valid_config()
      |> put_in(["repos", Access.at(0), "local_env_path"], nil)
      |> put_in(["repos", Access.at(0), "env"], %{"LINEAR_API_KEY" => "token"})

    assert :ok = ManagerConfig.validate(config)
  end

  test "assign_missing_ports fills nil repo ports from manager range" do
    config = valid_config()

    assert {:ok, assigned} = ManagerConfig.assign_missing_ports(config)

    ports = Enum.map(assigned["repos"], & &1["port"])

    assert Enum.all?(ports, &is_integer/1)
    assert Enum.uniq(ports) == ports
    assert Enum.all?(ports, &(&1 >= 43_100 and &1 <= 43_105))
  end

  test "assign_missing_ports fails when no loopback ports are available" do
    {port, socket_v4, socket_v6} = reserve_dual_stack_loopback_port!()

    config =
      valid_config()
      |> put_in(["manager", "port_range"], %{"start" => port, "end" => port})
      |> put_in(["repos"], [
        put_in(hd(valid_config()["repos"]), ["port"], nil)
      ])

    try do
      assert {:error, {:config_error, message}} = ManagerConfig.assign_missing_ports(config)
      assert message =~ "No available loopback ports in range #{port}-#{port}"
    after
      :ok = :gen_tcp.close(socket_v4)
      :ok = :gen_tcp.close(socket_v6)
    end
  end

  test "load_and_persist writes assigned ports back to config.json" do
    config = valid_config()

    with_temp_file!(Jason.encode!(config), fn path ->
      assert {:ok, assigned} = ManagerConfig.load_and_persist(path)
      assert is_integer(get_in(assigned, ["repos", Access.at(1), "port"]))

      assert {:ok, persisted} = ManagerConfig.load_raw(path)
      assert get_in(persisted, ["repos", Access.at(1), "port"]) == get_in(assigned, ["repos", Access.at(1), "port"])
    end)
  end

  test "load_and_persist surfaces persistence failures" do
    config = valid_config()

    with_temp_dir!(fn dir ->
      path = Path.join(dir, "config.json")
      File.write!(path, Jason.encode!(config))
      File.chmod!(dir, 0o500)

      try do
        assert {:error, {:config_error, message}} = ManagerConfig.load_and_persist(path)
        assert message =~ "Failed to persist config"
      after
        File.chmod!(dir, 0o700)
      end
    end)
  end

  test "parse_repo expands configured repo paths into a struct" do
    assert {:ok, repo} = ManagerConfig.parse_repo(hd(valid_config()["repos"]))

    assert repo.id == "repo-a"
    assert repo.name == "Repo A"
    assert repo.repo_path == Path.expand("/tmp/repo-a")
    assert repo.workflow_path == Path.expand("/tmp/workflows/repo-a/WORKFLOW.md")
    assert repo.logs_root == Path.expand("/tmp/logs/repo-a")
    assert repo.local_env_path == Path.expand("/tmp/repo-a/local.env")
    assert repo.port == 43_101
    assert repo.enabled == true
    assert repo.env == %{"A" => "1"}
  end

  test "parse_repo rejects non-map repo entries" do
    assert {:error, {:config_error, "Each repo entry must be an object"}} = ManagerConfig.parse_repo("repo-a")
  end

  test "load_env_file supports comments, export prefixes, and quoted values" do
    env_file = """
    # ignored
    export LINEAR_API_KEY="token"
    SYMPHONY_PROJECT_SLUG='leftoff'
    ESCAPED="say \\"hi\\""
    """

    with_temp_file!(env_file, fn path ->
      assert {:ok, env} = ManagerConfig.load_env_file(path)

      assert env == %{
               "LINEAR_API_KEY" => "token",
               "SYMPHONY_PROJECT_SLUG" => "leftoff",
               "ESCAPED" => "say \"hi\""
             }
    end)
  end

  test "load_env_file surfaces read failures and malformed lines" do
    missing_path = Path.join(System.tmp_dir!(), "manager-env-missing-#{System.unique_integer([:positive])}.env")
    assert {:error, {:config_error, message}} = ManagerConfig.load_env_file(missing_path)
    assert message =~ "Failed to read env file"

    with_temp_file!("BROKEN\n", fn path ->
      assert {:error, {:config_error, message}} = ManagerConfig.load_env_file(path)
      assert message =~ "expected KEY=VALUE"
    end)

    with_temp_file!("export =oops\n", fn path ->
      assert {:error, {:config_error, message}} = ManagerConfig.load_env_file(path)
      assert message =~ "expected KEY=VALUE"
    end)

    with_temp_file!("BROKEN_QUOTE=\"oops\n", fn path ->
      assert {:error, {:config_error, message}} = ManagerConfig.load_env_file(path)
      assert message =~ "expected KEY=VALUE"
    end)
  end

  defp valid_config do
    %{
      "version" => 1,
      "symphony_repo" => "/tmp/symphony",
      "symphony_bin" => "/tmp/symphony/elixir/bin/symphony",
      "manager" => %{
        "check_interval_seconds" => 30,
        "http_timeout_seconds" => 5,
        "failure_threshold" => 3,
        "restart_backoff_seconds" => [5, 15, 30],
        "port_range" => %{"start" => 43_100, "end" => 43_105},
        "graceful_shutdown_seconds" => 10,
        "config_reload_seconds" => 5
      },
      "repos" => [
        %{
          "id" => "repo-a",
          "name" => "Repo A",
          "repo_path" => "/tmp/repo-a",
          "workflow_path" => "/tmp/workflows/repo-a/WORKFLOW.md",
          "logs_root" => "/tmp/logs/repo-a",
          "local_env_path" => "/tmp/repo-a/local.env",
          "port" => 43_101,
          "enabled" => true,
          "env" => %{"A" => "1"}
        },
        %{
          "id" => "repo-b",
          "name" => "Repo B",
          "repo_path" => "/tmp/repo-b",
          "workflow_path" => "/tmp/workflows/repo-b/WORKFLOW.md",
          "logs_root" => "/tmp/logs/repo-b",
          "local_env_path" => nil,
          "port" => nil,
          "enabled" => true,
          "env" => %{}
        }
      ]
    }
  end

  defp with_temp_file!(contents, fun) do
    path = Path.join(System.tmp_dir!(), "manager-config-#{System.unique_integer([:positive])}.json")
    File.write!(path, contents)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp with_temp_dir!(fun) do
    path = Path.join(System.tmp_dir!(), "manager-config-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    try do
      fun.(path)
    after
      File.rm_rf(path)
    end
  end

  defp with_temp_home_config!(config, fun) do
    temp_home = Path.join(System.tmp_dir!(), "manager-config-home-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("HOME")
    config_path = Path.join([temp_home, ".config", "symphony", "config.json"])

    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, Jason.encode!(config))
    System.put_env("HOME", temp_home)

    try do
      fun.(config_path)
    after
      restore_env("HOME", previous_home)
      File.rm_rf(temp_home)
    end
  end

  defp reserve_dual_stack_loopback_port! do
    Enum.find_value(43_100..48_999, fn port ->
      with {:ok, socket_v4} <- :gen_tcp.listen(port, [:binary, :inet, {:active, false}, {:ip, {127, 0, 0, 1}}, {:reuseaddr, true}]),
           {:ok, socket_v6} <- :gen_tcp.listen(port, [:binary, :inet6, {:active, false}, {:ip, {0, 0, 0, 0, 0, 0, 0, 1}}, {:reuseaddr, true}]) do
        {port, socket_v4, socket_v6}
      else
        {:error, _reason} ->
          nil
      end
    end) || raise "could not reserve a dual-stack loopback port in the manager test range"
  end

  defp restore_env(_key, nil), do: System.delete_env("HOME")
  defp restore_env(key, value), do: System.put_env(key, value)
end
