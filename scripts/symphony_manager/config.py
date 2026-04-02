from __future__ import annotations

import json
import os
import socket
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_CONFIG_DIR = Path.home() / ".config" / "symphony"
DEFAULT_CONFIG_PATH = DEFAULT_CONFIG_DIR / "config.json"
DEFAULT_MANAGER_LABEL = "dev.symphony.manager"
DEFAULT_PORT_RANGE = {"start": 43100, "end": 48999}
GUARDRAIL_ACK = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"


class ConfigError(ValueError):
    """Raised when the manager config is invalid."""


@dataclass(frozen=True)
class RepoConfig:
    id: str
    name: str
    repo_path: Path
    workflow_path: Path
    logs_root: Path
    local_env_path: Path | None
    port: int | None
    enabled: bool
    env: dict[str, str]


def default_config() -> dict[str, Any]:
    home = Path.home()
    symphony_repo = home / "code" / "symphony"
    return {
        "version": 1,
        "symphony_repo": str(symphony_repo),
        "symphony_bin": str(symphony_repo / "elixir" / "bin" / "symphony"),
        "manager": {
            "check_interval_seconds": 30,
            "http_timeout_seconds": 5,
            "failure_threshold": 3,
            "restart_backoff_seconds": [5, 15, 30, 60, 300],
            "port_range": dict(DEFAULT_PORT_RANGE),
            "graceful_shutdown_seconds": 10,
            "config_reload_seconds": 5,
            "launchd_label": DEFAULT_MANAGER_LABEL,
            "launchd_log_path": str(DEFAULT_CONFIG_DIR / "manager.log"),
            "launchd_error_log_path": str(DEFAULT_CONFIG_DIR / "manager.error.log"),
        },
        "repos": [
            {
                "id": "example-repo",
                "name": "Example Repo",
                "repo_path": str(home / "code" / "example-repo"),
                "workflow_path": str(symphony_repo / "workflows" / "example-repo" / "WORKFLOW.md"),
                "logs_root": str(DEFAULT_CONFIG_DIR / "logs" / "example-repo"),
                "local_env_path": str(home / "code" / "example-repo" / "local.env"),
                "port": None,
                "enabled": True,
                "env": {},
            }
        ],
    }


def ensure_config_dir(config_path: Path = DEFAULT_CONFIG_PATH) -> Path:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    return config_path.parent


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    ensure_config_dir(path)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temp_path = Path(handle.name)

    os.replace(temp_path, path)


def load_raw_config(path: Path = DEFAULT_CONFIG_PATH) -> dict[str, Any]:
    if not path.is_file():
        raise ConfigError(f"Config file does not exist: {path}")

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ConfigError(f"Failed to parse JSON config {path}: {exc}") from exc


def load_config(path: Path = DEFAULT_CONFIG_PATH) -> dict[str, Any]:
    config = load_raw_config(path)
    validate_config(config)
    return config


def validate_config(config: dict[str, Any]) -> None:
    if config.get("version") != 1:
        raise ConfigError("Config `version` must be 1")

    if not isinstance(config.get("symphony_repo"), str) or not config["symphony_repo"].strip():
        raise ConfigError("Config `symphony_repo` must be a non-empty string")

    if not isinstance(config.get("symphony_bin"), str) or not config["symphony_bin"].strip():
        raise ConfigError("Config `symphony_bin` must be a non-empty string")

    manager = config.get("manager")
    if not isinstance(manager, dict):
        raise ConfigError("Config `manager` must be an object")

    for field in [
        "check_interval_seconds",
        "http_timeout_seconds",
        "failure_threshold",
        "graceful_shutdown_seconds",
        "config_reload_seconds",
    ]:
        value = manager.get(field)
        if not isinstance(value, int) or value <= 0:
            raise ConfigError(f"Manager field `{field}` must be a positive integer")

    backoff = manager.get("restart_backoff_seconds")
    if not isinstance(backoff, list) or not backoff or any(
        not isinstance(value, int) or value <= 0 for value in backoff
    ):
        raise ConfigError("Manager `restart_backoff_seconds` must be a non-empty list of positive integers")

    port_range = manager.get("port_range")
    if not isinstance(port_range, dict):
        raise ConfigError("Manager `port_range` must be an object")

    start = port_range.get("start")
    end = port_range.get("end")
    if not isinstance(start, int) or not isinstance(end, int) or start <= 0 or end < start:
        raise ConfigError("Manager `port_range` must contain valid integer `start` and `end`")

    repos = config.get("repos")
    if not isinstance(repos, list):
        raise ConfigError("Config `repos` must be a list")

    repo_ids: set[str] = set()
    repo_ports: set[int] = set()
    for entry in repos:
        repo = parse_repo(entry)
        if repo.id in repo_ids:
            raise ConfigError(f"Duplicate repo id `{repo.id}`")
        repo_ids.add(repo.id)

        if repo.port is not None:
            if repo.port < start or repo.port > end:
                raise ConfigError(
                    f"Repo `{repo.id}` port {repo.port} must be inside configured port range {start}-{end}"
                )
            if repo.port in repo_ports:
                raise ConfigError(f"Duplicate port {repo.port} across repos")
            repo_ports.add(repo.port)


def parse_repo(entry: dict[str, Any]) -> RepoConfig:
    if not isinstance(entry, dict):
        raise ConfigError("Each repo entry must be an object")

    def require_string(key: str) -> str:
        value = entry.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ConfigError(f"Repo field `{key}` must be a non-empty string")
        return value

    repo_id = require_string("id")
    name = require_string("name")
    repo_path = Path(require_string("repo_path")).expanduser()
    workflow_path = Path(require_string("workflow_path")).expanduser()
    logs_root = Path(require_string("logs_root")).expanduser()
    local_env_path_raw = entry.get("local_env_path")
    if local_env_path_raw is not None and (not isinstance(local_env_path_raw, str) or not local_env_path_raw.strip()):
        raise ConfigError(f"Repo `{repo_id}` field `local_env_path` must be a non-empty string when present")
    local_env_path = Path(local_env_path_raw).expanduser() if isinstance(local_env_path_raw, str) else None

    enabled = entry.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ConfigError(f"Repo `{repo_id}` field `enabled` must be a boolean")

    env = entry.get("env", {})
    if not isinstance(env, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in env.items()):
        raise ConfigError(f"Repo `{repo_id}` field `env` must be an object of string pairs")

    port = entry.get("port")
    if port is not None and (not isinstance(port, int) or port <= 0):
        raise ConfigError(f"Repo `{repo_id}` field `port` must be a positive integer when present")

    return RepoConfig(
        id=repo_id,
        name=name,
        repo_path=repo_path,
        workflow_path=workflow_path,
        logs_root=logs_root,
        local_env_path=local_env_path,
        port=port,
        enabled=enabled,
        env=env,
    )


def load_env_file(path: Path) -> dict[str, str]:
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError(f"Failed to read env file {path}: {exc}") from exc

    env: dict[str, str] = {}
    for line_number, raw_line in enumerate(content.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("export "):
            line = line[7:].strip()

        if "=" not in line:
            raise ConfigError(f"Invalid env file line {line_number} in {path}: expected KEY=VALUE")

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if not key:
            raise ConfigError(f"Invalid env file line {line_number} in {path}: missing variable name")

        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", "\""}:
            value = value[1:-1]

        env[key] = value

    return env


def assign_missing_ports(config: dict[str, Any]) -> bool:
    validate_config(config)
    manager = config["manager"]
    start = manager["port_range"]["start"]
    end = manager["port_range"]["end"]
    allocated = {
        entry["port"]
        for entry in config["repos"]
        if isinstance(entry, dict) and isinstance(entry.get("port"), int)
    }

    changed = False
    for entry in config["repos"]:
        if entry.get("port") is not None:
            continue

        entry["port"] = choose_available_port(start, end, allocated)
        allocated.add(entry["port"])
        changed = True

    return changed


def choose_available_port(start: int, end: int, reserved: set[int]) -> int:
    for port in range(start, end + 1):
        if port in reserved:
            continue
        if is_loopback_port_available(port):
            return port

    raise ConfigError(f"No available loopback ports in range {start}-{end}")


def is_loopback_port_available(port: int) -> bool:
    for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind((host, port))
        except OSError:
            return False
    return True
