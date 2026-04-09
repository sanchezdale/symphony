defmodule SymphonyElixir.ManagerConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ManagerConfig

  test "load_raw returns config map from JSON" do
    config = valid_config()

    with_temp_file!(Jason.encode!(config), fn path ->
      assert {:ok, ^config} = ManagerConfig.load_raw(path)
    end)
  end

  test "validate accepts valid legacy config" do
    assert :ok = ManagerConfig.validate(valid_config())
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

  test "load_and_persist writes assigned ports back to config.json" do
    config = valid_config()

    with_temp_file!(Jason.encode!(config), fn path ->
      assert {:ok, assigned} = ManagerConfig.load_and_persist(path)
      assert is_integer(get_in(assigned, ["repos", Access.at(1), "port"]))

      assert {:ok, persisted} = ManagerConfig.load_raw(path)
      assert get_in(persisted, ["repos", Access.at(1), "port"]) == get_in(assigned, ["repos", Access.at(1), "port"])
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

  test "load_env_file supports comments and export prefixes" do
    env_file = """
    # ignored
    export LINEAR_API_KEY=token
    SYMPHONY_PROJECT_SLUG=leftoff
    """

    with_temp_file!(env_file, fn path ->
      assert {:ok, env} = ManagerConfig.load_env_file(path)
      assert env == %{"LINEAR_API_KEY" => "token", "SYMPHONY_PROJECT_SLUG" => "leftoff"}
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
end
