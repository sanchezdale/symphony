#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_LABEL = "dev.symphony.manager"
GUARDRAIL_ACK = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
DEFAULT_PORT_RANGE = {"start": 43_100, "end": 48_999}


@dataclass(frozen=True)
class CheckResult:
    name: str
    passed: bool
    detail: str
    remediation: str | None = None


@dataclass(frozen=True)
class PlannedChange:
    target: str
    detail: str


@dataclass(frozen=True)
class MigrationPlan:
    config_path: Path
    plist_path: Path
    repo_root: Path
    label: str
    service: str
    desired_config: dict[str, Any]
    current_plist: dict[str, Any] | None
    desired_plist: dict[str, Any]
    service_loaded: bool
    checks: list[CheckResult]
    changes: list[PlannedChange]

    @property
    def blockers(self) -> list[CheckResult]:
        return [check for check in self.checks if not check.passed]

    @property
    def config_changed(self) -> bool:
        return any(change.target == "config.json" for change in self.changes)

    @property
    def plist_changed(self) -> bool:
        return any(change.target == "launchd.plist" for change in self.changes)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Migrate the removed Python Symphony manager LaunchAgent to the current Elixir manager flow."
    )
    parser.add_argument("--config", type=Path, default=default_config_path(), help="Path to config.json")
    parser.add_argument("--plist-path", type=Path, help="Path to the LaunchAgent plist to rewrite")
    parser.add_argument("--label", help="launchd label override")
    parser.add_argument(
        "--repo-root",
        type=Path,
        help="Symphony checkout that should own the new manager (defaults to this script's repo root)",
    )
    parser.add_argument(
        "--use-current-repo",
        action="store_true",
        help="Rewrite symphony_repo and symphony_bin to the current checkout before cutover",
    )
    parser.add_argument("--dry-run", action="store_true", help="Audit only; print the migration report without changes")
    parser.add_argument("--apply", action="store_true", help="Apply the migration and verify runtime health")
    parser.add_argument(
        "--health-timeout-seconds",
        type=int,
        default=30,
        help="Seconds to wait for enabled repo health endpoints after cutover",
    )
    return parser


def default_config_path() -> Path:
    return Path.home() / ".config" / "symphony" / "config.json"


def default_log_path(filename: str) -> str:
    return str(Path.home() / ".config" / "symphony" / filename)


def repo_root_from_script() -> Path:
    current = Path(__file__).resolve()
    for candidate in current.parents:
        # Intentionally stop at the first repo that contains the Elixir wrapper.
        if (candidate / ".git").exists() and (candidate / "elixir" / "bin" / "symphony").exists():
            return candidate
    raise RuntimeError(f"Could not find Symphony repo root from {current}")


def timestamp() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError("Config root must be a JSON object")
    return payload


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temp_path = Path(handle.name)
    os.replace(temp_path, path)


def backup_file(path: Path) -> Path:
    backup_path = path.with_name(f"{path.name}.bak.{timestamp()}")
    shutil.copy2(path, backup_path)
    return backup_path


def build_launchd_plist(
    *,
    label: str,
    config_path: Path,
    symphony_repo: Path,
    symphony_bin: Path,
    stdout_path: Path,
    stderr_path: Path,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    environment = {"PYTHONUNBUFFERED": "1"}
    current_path = None if env is None else env.get("PATH")
    if current_path:
        environment["PATH"] = current_path

    return {
        "Label": label,
        "ProgramArguments": [
            str(symphony_bin),
            GUARDRAIL_ACK,
            "manager",
            "--config",
            str(config_path),
            "run",
        ],
        "WorkingDirectory": str(symphony_repo),
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "EnvironmentVariables": environment,
        "StandardOutPath": str(stdout_path),
        "StandardErrorPath": str(stderr_path),
    }


def read_plist(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    with path.open("rb") as handle:
        payload = plistlib.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"LaunchAgent plist {path} did not decode to an object")
    return payload


def write_plist(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)


def plist_mode(payload: dict[str, Any] | None) -> str:
    if payload is None:
        return "missing"

    arguments = payload.get("ProgramArguments")
    if not isinstance(arguments, list):
        return "unknown"

    normalized = [str(argument) for argument in arguments]
    if len(normalized) >= 3 and normalized[1:3] == ["-m", "scripts.symphony_manager"]:
        return "legacy_python"
    if "manager" in normalized and GUARDRAIL_ACK in normalized:
        return "elixir_manager"
    return "unknown"


def default_manager_values() -> dict[str, Any]:
    return {
        "check_interval_seconds": 30,
        "http_timeout_seconds": 5,
        "failure_threshold": 3,
        "restart_backoff_seconds": [5, 15, 30, 60, 300],
        "port_range": dict(DEFAULT_PORT_RANGE),
        "graceful_shutdown_seconds": 10,
        "config_reload_seconds": 5,
        "launchd_label": DEFAULT_LABEL,
        "launchd_log_path": default_log_path("manager.log"),
        "launchd_error_log_path": default_log_path("manager.error.log"),
    }


def normalize_config(config: dict[str, Any], *, repo_root: Path, use_current_repo: bool) -> tuple[dict[str, Any], list[PlannedChange]]:
    desired = copy.deepcopy(config)
    changes: list[PlannedChange] = []

    manager = desired.get("manager")
    if manager is None:
        manager = {}
        desired["manager"] = manager
    if not isinstance(manager, dict):
        return desired, changes

    for key, value in default_manager_values().items():
        if key not in manager:
            manager[key] = copy.deepcopy(value)
            changes.append(PlannedChange("config.json", f"Set manager.{key} to its Elixir-manager default"))

    if use_current_repo:
        repo_root_str = str(repo_root)
        symphony_bin = str(repo_root / "elixir" / "bin" / "symphony")
        if desired.get("symphony_repo") != repo_root_str:
            desired["symphony_repo"] = repo_root_str
            changes.append(PlannedChange("config.json", f"Point symphony_repo at {repo_root_str}"))
        if desired.get("symphony_bin") != symphony_bin:
            desired["symphony_bin"] = symphony_bin
            changes.append(PlannedChange("config.json", f"Point symphony_bin at {symphony_bin}"))

    return desired, changes


def validate_config_shape(config: dict[str, Any]) -> list[CheckResult]:
    checks: list[CheckResult] = []

    if config.get("version") != 1:
        checks.append(
            CheckResult(
                "config.version",
                False,
                f"Expected version 1, found {config.get('version')!r}",
                "Restore a manager config with `version: 1` before migrating.",
            )
        )

    for key in ("symphony_repo", "symphony_bin"):
        value = config.get(key)
        if not isinstance(value, str) or not value.strip():
            checks.append(
                CheckResult(
                    f"config.{key}",
                    False,
                    f"{key} must be a non-empty string",
                    f"Edit {default_config_path()} so `{key}` points at a real path.",
                )
            )

    manager = config.get("manager")
    if not isinstance(manager, dict):
        checks.append(
            CheckResult(
                "config.manager",
                False,
                "manager must be a JSON object",
                "Restore the manager object in config.json before migrating.",
            )
        )
        return checks

    repos = config.get("repos")
    if not isinstance(repos, list):
        checks.append(
            CheckResult(
                "config.repos",
                False,
                "repos must be a JSON array",
                "Restore the repo definitions in config.json before migrating.",
            )
        )
        return checks

    for index, repo in enumerate(repos):
        if not isinstance(repo, dict):
            checks.append(
                CheckResult(
                    f"config.repos[{index}]",
                    False,
                    "repo entry must be an object",
                    "Rewrite the invalid repo entry in config.json before migrating.",
                )
            )
            continue

        repo_id = repo.get("id", f"repos[{index}]")
        for field in ("id", "name", "repo_path", "workflow_path", "logs_root"):
            value = repo.get(field)
            if not isinstance(value, str) or not value.strip():
                checks.append(
                    CheckResult(
                        f"config.repo:{repo_id}.{field}",
                        False,
                        f"{field} must be a non-empty string",
                        f"Fix repo `{repo_id}` field `{field}` in config.json before migrating.",
                    )
                )

        local_env_path = repo.get("local_env_path")
        if local_env_path is not None and (not isinstance(local_env_path, str) or not local_env_path.strip()):
            checks.append(
                CheckResult(
                    f"config.repo:{repo_id}.local_env_path",
                    False,
                    "local_env_path must be a non-empty string when present",
                    f"Fix repo `{repo_id}` local_env_path in config.json before migrating.",
                )
            )

        port = repo.get("port")
        if port is not None and (not isinstance(port, int) or port <= 0):
            checks.append(
                CheckResult(
                    f"config.repo:{repo_id}.port",
                    False,
                    "port must be a positive integer when present",
                    f"Fix repo `{repo_id}` port in config.json before migrating.",
                )
            )

    return checks


def path_exists_check(name: str, path: Path, kind: str, remediation: str) -> CheckResult:
    if kind == "directory":
        passed = path.is_dir()
    elif kind == "file":
        passed = path.is_file()
    else:
        raise ValueError(f"Unsupported kind: {kind}")

    detail = f"Found {path}" if passed else f"Missing {kind}: {path}"
    return CheckResult(name, passed, detail, None if passed else remediation)


def latest_build_input_mtime(repo_root: Path) -> tuple[float | None, Path | None]:
    candidates = [repo_root / "elixir" / "mix.exs"]
    candidates.extend((repo_root / "elixir" / "lib").rglob("*.ex"))

    latest_path: Path | None = None
    latest_mtime: float | None = None

    for candidate in candidates:
        try:
            stat = candidate.stat()
        except OSError:
            continue
        if latest_mtime is None or stat.st_mtime > latest_mtime:
            latest_mtime = stat.st_mtime
            latest_path = candidate

    return latest_mtime, latest_path


def parse_env_file(path: Path) -> dict[str, str]:
    content = path.read_text(encoding="utf-8")
    env: dict[str, str] = {}

    for line_number, raw_line in enumerate(content.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            raise ValueError(f"Invalid env file line {line_number} in {path}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            raise ValueError(f"Invalid env file line {line_number} in {path}: missing variable name")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        env[key] = value

    return env


def required_workflow_env_vars(workflow_path: Path) -> set[str]:
    try:
        content = workflow_path.read_text(encoding="utf-8")
    except OSError:
        return set()

    required: set[str] = set()
    if "LINEAR_API_KEY" in content or "kind: linear" in content:
        required.add("LINEAR_API_KEY")
    return required


def validate_prerequisites(config: dict[str, Any], config_path: Path) -> list[CheckResult]:
    checks: list[CheckResult] = []

    is_macos = platform.system() == "Darwin"
    launchctl_path = shutil.which("launchctl")
    checks.append(
        CheckResult(
            "host.launchd",
            is_macos and launchctl_path is not None,
            "launchctl is available" if is_macos and launchctl_path is not None else "launchctl is unavailable",
            None if is_macos and launchctl_path is not None else "Run the migration on macOS with launchctl available.",
        )
    )

    codex_path = shutil.which("codex")
    checks.append(
        CheckResult(
            "host.codex",
            codex_path is not None,
            codex_path or "codex is not on PATH",
            None if codex_path is not None else "Install Codex and ensure the launchd user can resolve `codex` on PATH.",
        )
    )

    symphony_repo_value = config.get("symphony_repo")
    symphony_bin_value = config.get("symphony_bin")
    if not isinstance(symphony_repo_value, str) or not isinstance(symphony_bin_value, str):
        return checks

    symphony_repo = Path(symphony_repo_value).expanduser()
    symphony_bin = Path(symphony_bin_value).expanduser()
    checks.append(
        path_exists_check(
            "manager.symphony_repo",
            symphony_repo,
            "directory",
            f"Update `symphony_repo` in {config_path} so it points at the desired Symphony checkout.",
        )
    )
    checks.append(
        path_exists_check(
            "manager.symphony_bin",
            symphony_bin,
            "file",
            f"Build or restore the wrapper at {symphony_bin} before migrating.",
        )
    )

    escript_path = symphony_bin.parent / "symphony.escript"
    checks.append(
        path_exists_check(
            "manager.symphony_escript",
            escript_path,
            "file",
            f"Build Symphony once with `cd {symphony_repo / 'elixir'} && mise trust && mise install && mise exec -- mix build`.",
        )
    )
    if escript_path.is_file():
        latest_input_mtime, latest_input_path = latest_build_input_mtime(symphony_repo)
        try:
            escript_mtime = escript_path.stat().st_mtime
        except OSError:
            escript_mtime = None

        if latest_input_mtime is not None and latest_input_path is not None and escript_mtime is not None:
            escript_current = escript_mtime >= latest_input_mtime
            detail = (
                f"{escript_path} is newer than Elixir sources"
                if escript_current
                else f"{escript_path} is older than {latest_input_path}"
            )
            remediation = None
            if not escript_current:
                remediation = (
                    f"Rebuild Symphony with `cd {symphony_repo / 'elixir'} && mise trust && mise install && "
                    "`mise exec -- mix build` before migrating."
                )
            checks.append(CheckResult("manager.symphony_escript_current", escript_current, detail, remediation))

    repos = config.get("repos")
    if not isinstance(repos, list):
        return checks

    for repo in repos:
        if not isinstance(repo, dict):
            continue

        repo_id = str(repo.get("id", "unknown"))
        repo_path_value = repo.get("repo_path")
        workflow_path_value = repo.get("workflow_path")
        if not isinstance(repo_path_value, str) or not isinstance(workflow_path_value, str):
            continue

        repo_path = Path(repo_path_value).expanduser()
        workflow_path = Path(workflow_path_value).expanduser()
        checks.append(
            path_exists_check(
                f"repo:{repo_id}.repo_path",
                repo_path,
                "directory",
                f"Clone or mount repo `{repo_id}` at {repo_path}, or fix repo_path in {config_path}.",
            )
        )
        checks.append(
            path_exists_check(
                f"repo:{repo_id}.workflow_path",
                workflow_path,
                "file",
                f"Create the workflow file for `{repo_id}` at {workflow_path}, or fix workflow_path in {config_path}.",
            )
        )

        effective_env = dict(os.environ)

        local_env_path_raw = repo.get("local_env_path")
        if isinstance(local_env_path_raw, str) and local_env_path_raw.strip():
            local_env_path = Path(local_env_path_raw).expanduser()
            env_check = path_exists_check(
                f"repo:{repo_id}.local_env_path",
                local_env_path,
                "file",
                f"Create repo `{repo_id}` env file at {local_env_path}, or update local_env_path in {config_path}.",
            )
            checks.append(env_check)

            if env_check.passed:
                try:
                    effective_env.update(parse_env_file(local_env_path))
                    checks.append(
                        CheckResult(
                            f"repo:{repo_id}.local_env_loaded",
                            True,
                            f"Loaded variables from {local_env_path}",
                        )
                    )
                except ValueError as exc:
                    checks.append(
                        CheckResult(
                            f"repo:{repo_id}.local_env_loaded",
                            False,
                            str(exc),
                            f"Fix the env file syntax in {local_env_path}.",
                        )
                    )

        inline_env = repo.get("env", {})
        if isinstance(inline_env, dict):
            for key, value in inline_env.items():
                if isinstance(key, str) and isinstance(value, str):
                    effective_env[key] = value

        for required_var in sorted(required_workflow_env_vars(workflow_path)):
            present = bool(effective_env.get(required_var))
            checks.append(
                CheckResult(
                    f"repo:{repo_id}.env:{required_var}",
                    present,
                    f"{required_var} is set" if present else f"{required_var} is missing",
                    None
                    if present
                    else (
                        f"Add {required_var} to the launchd environment, repo `{repo_id}` local env file, "
                        "or repos[].env before migrating."
                    ),
                )
            )

    return checks


def service_loaded(service: str) -> bool:
    result = subprocess.run(["launchctl", "print", service], capture_output=True, text=True, check=False)
    return result.returncode == 0


def plan_migration(
    config: dict[str, Any],
    *,
    config_path: Path,
    repo_root: Path,
    label_override: str | None,
    plist_path_override: Path | None,
    use_current_repo: bool,
) -> MigrationPlan:
    desired_config, config_changes = normalize_config(config, repo_root=repo_root, use_current_repo=use_current_repo)
    shape_checks = validate_config_shape(desired_config)
    checks = list(shape_checks)

    manager = desired_config.get("manager", {}) if isinstance(desired_config.get("manager"), dict) else {}
    label = label_override or str(manager.get("launchd_label") or DEFAULT_LABEL)
    plist_path = (plist_path_override or Path.home() / "Library" / "LaunchAgents" / f"{label}.plist").expanduser()
    service = f"gui/{os.getuid()}/{label}"

    current_plist = read_plist(plist_path)
    plist_status = plist_mode(current_plist)

    desired_plist = build_launchd_plist(
        label=label,
        config_path=config_path.expanduser(),
        symphony_repo=Path(str(desired_config.get("symphony_repo", ""))).expanduser(),
        symphony_bin=Path(str(desired_config.get("symphony_bin", ""))).expanduser(),
        stdout_path=Path(str(manager.get("launchd_log_path", default_log_path("manager.log")))).expanduser(),
        stderr_path=Path(str(manager.get("launchd_error_log_path", default_log_path("manager.error.log")))).expanduser(),
        env=os.environ,
    )

    checks.extend(validate_prerequisites(desired_config, config_path.expanduser()))

    changes = list(config_changes)
    if current_plist is None:
        changes.append(PlannedChange("launchd.plist", f"Create {plist_path} for label {label}"))
    elif current_plist != desired_plist:
        detail = {
            "legacy_python": "Rewrite the legacy Python LaunchAgent to the Elixir manager command",
            "elixir_manager": "Refresh the existing Elixir LaunchAgent so it matches the desired manager command",
            "unknown": "Rewrite the existing LaunchAgent to the desired Elixir manager command",
        }.get(plist_status, "Rewrite the LaunchAgent to the desired Elixir manager command")
        changes.append(PlannedChange("launchd.plist", f"{detail} at {plist_path}"))

    loaded = False
    if all(check.passed for check in checks if check.name.startswith("host.launchd")):
        loaded = service_loaded(service)
        if not loaded:
            changes.append(PlannedChange("launchd.service", f"Bootstrap and kickstart {service}"))
        elif current_plist != desired_plist or any(change.target == "config.json" for change in config_changes):
            changes.append(PlannedChange("launchd.service", f"Restart {service} so it picks up the migrated config"))

    return MigrationPlan(
        config_path=config_path.expanduser(),
        plist_path=plist_path,
        repo_root=repo_root,
        label=label,
        service=service,
        desired_config=desired_config,
        current_plist=current_plist,
        desired_plist=desired_plist,
        service_loaded=loaded,
        checks=checks,
        changes=changes,
    )


def launchctl(args: list[str]) -> None:
    result = subprocess.run(["launchctl", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        stderr = result.stderr.strip() or result.stdout.strip() or f"launchctl exited with {result.returncode}"
        raise RuntimeError(f"launchctl {' '.join(args)} failed: {stderr}")


def verify_repo_health(config_path: Path, timeout_seconds: int) -> list[CheckResult]:
    deadline = time.monotonic() + timeout_seconds
    last_errors: dict[str, str] = {}
    completed: dict[str, CheckResult] = {}

    while time.monotonic() < deadline:
        config = read_json(config_path)
        repos = config.get("repos", [])

        for repo in repos:
            if not isinstance(repo, dict):
                continue

            repo_id = str(repo.get("id", "unknown"))
            if repo_id in completed:
                continue
            if repo.get("enabled", True) is False:
                completed[repo_id] = CheckResult(f"repo:{repo_id}.health", True, "Skipped disabled repo")
                continue

            port = repo.get("port")
            if not isinstance(port, int) or port <= 0:
                last_errors[repo_id] = "manager has not assigned a repo port yet"
                continue

            try:
                with urllib.request.urlopen(
                    urllib.request.Request(f"http://127.0.0.1:{port}/api/v1/state"),
                    timeout=2,
                ) as response:
                    body = response.read()
            except urllib.error.URLError as exc:
                last_errors[repo_id] = str(exc.reason)
                continue
            except OSError as exc:
                last_errors[repo_id] = str(exc)
                continue

            try:
                decoded = json.loads(body.decode("utf-8"))
            except json.JSONDecodeError as exc:
                last_errors[repo_id] = f"invalid JSON from /api/v1/state: {exc}"
                continue

            if not isinstance(decoded, dict):
                last_errors[repo_id] = "state endpoint did not return a JSON object"
                continue

            completed[repo_id] = CheckResult(
                f"repo:{repo_id}.health",
                True,
                f"/api/v1/state responded on port {port}",
            )

        enabled_repo_ids = [
            str(repo.get("id", "unknown"))
            for repo in repos
            if isinstance(repo, dict) and repo.get("enabled", True) is not False
        ]
        if all(repo_id in completed for repo_id in enabled_repo_ids):
            break
        time.sleep(1)

    final_results = list(completed.values())
    config = read_json(config_path)
    for repo in config.get("repos", []):
        if not isinstance(repo, dict):
            continue
        repo_id = str(repo.get("id", "unknown"))
        if repo.get("enabled", True) is False or repo_id in completed:
            continue
        logs_root = repo.get("logs_root")
        remediation = "Inspect the manager log and repo logs for the failing runtime."
        if isinstance(logs_root, str) and logs_root.strip():
            remediation = f"Inspect {logs_root} plus the manager log to determine why repo `{repo_id}` never became healthy."
        final_results.append(
            CheckResult(
                f"repo:{repo_id}.health",
                False,
                last_errors.get(repo_id, "repo health endpoint never became reachable"),
                remediation,
            )
        )

    return sorted(final_results, key=lambda item: item.name)


def render_report(plan: MigrationPlan, *, mode: str, post_checks: list[CheckResult] | None = None, backups: list[Path] | None = None) -> str:
    lines = [
        f"Migration status: {'SUCCESS' if not plan.blockers and not failed_post_checks(post_checks) else 'FAILED'}",
        f"Mode: {mode}",
        f"Config: {plan.config_path}",
        f"LaunchAgent: {plan.plist_path}",
        f"Service: {plan.service}",
        "",
        "Checks:",
    ]

    for check in plan.checks:
        status = "PASS" if check.passed else "FAIL"
        lines.append(f"- [{status}] {check.name}: {check.detail}")
        if check.remediation and not check.passed:
            lines.append(f"  Remediation: {check.remediation}")

    if post_checks:
        lines.append("")
        lines.append("Post-cutover checks:")
        for check in post_checks:
            status = "PASS" if check.passed else "FAIL"
            lines.append(f"- [{status}] {check.name}: {check.detail}")
            if check.remediation and not check.passed:
                lines.append(f"  Remediation: {check.remediation}")

    lines.append("")
    lines.append("Planned changes:" if mode == "dry-run" else "Applied changes:")
    if plan.changes:
        for change in plan.changes:
            lines.append(f"- {change.target}: {change.detail}")
    else:
        lines.append("- None. The existing manager setup already matches the Elixir flow.")

    if backups:
        lines.append("")
        lines.append("Backups:")
        for path in backups:
            lines.append(f"- {path}")

    follow_up = collect_follow_up(plan, post_checks or [])
    lines.append("")
    lines.append("Manual follow-up:")
    if follow_up:
        for item in follow_up:
            lines.append(f"- {item}")
    else:
        lines.append("- None.")

    return "\n".join(lines)


def failed_post_checks(post_checks: list[CheckResult] | None) -> bool:
    return any(not check.passed for check in (post_checks or []))


def collect_follow_up(plan: MigrationPlan, post_checks: list[CheckResult]) -> list[str]:
    items: list[str] = []
    if plan.blockers:
        for check in plan.blockers:
            if check.remediation:
                items.append(check.remediation)
    for check in post_checks:
        if not check.passed and check.remediation:
            items.append(check.remediation)
    return dedupe(items)


def dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            ordered.append(item)
    return ordered


def apply_migration(plan: MigrationPlan, timeout_seconds: int) -> tuple[list[CheckResult], list[Path]]:
    backups: list[Path] = []

    if plan.config_changed and plan.config_path.is_file():
        backups.append(backup_file(plan.config_path))
        atomic_write_json(plan.config_path, plan.desired_config)

    if plan.plist_changed and plan.plist_path.is_file():
        backups.append(backup_file(plan.plist_path))
    if plan.plist_changed or not plan.plist_path.is_file():
        write_plist(plan.plist_path, plan.desired_plist)

    if any(change.target == "launchd.service" for change in plan.changes):
        if plan.service_loaded:
            try:
                launchctl(["bootout", f"gui/{os.getuid()}", str(plan.plist_path)])
            except RuntimeError:
                launchctl(["bootout", plan.service])
        launchctl(["bootstrap", f"gui/{os.getuid()}", str(plan.plist_path)])
        launchctl(["kickstart", "-k", plan.service])

    manager_loaded = service_loaded(plan.service)
    manager_check = CheckResult(
        "manager.launchd",
        manager_loaded,
        f"{plan.service} is loaded" if manager_loaded else f"{plan.service} is not loaded",
        None if manager_loaded else f"Inspect {plan.plist_path} and run `launchctl print {plan.service}` for details.",
    )
    repo_checks = verify_repo_health(plan.config_path, timeout_seconds)
    return [manager_check, *repo_checks], backups


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.apply == args.dry_run:
        parser.error("Pass exactly one of --dry-run or --apply.")

    repo_root = args.repo_root.expanduser().resolve() if args.repo_root else repo_root_from_script()
    config_path = args.config.expanduser()

    try:
        config = read_json(config_path)
    except FileNotFoundError:
        print(
            f"Migration status: FAILED\nMode: {'apply' if args.apply else 'dry-run'}\n"
            f"Config: {config_path}\n\nChecks:\n"
            f"- [FAIL] config.read: Config file does not exist at {config_path}\n"
            "  Remediation: Restore ~/.config/symphony/config.json or pass --config with the real file.",
            file=sys.stdout,
        )
        return 1
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(
            f"Migration status: FAILED\nMode: {'apply' if args.apply else 'dry-run'}\n"
            f"Config: {config_path}\n\nChecks:\n"
            f"- [FAIL] config.read: {exc}\n"
            "  Remediation: Fix the manager config JSON before migrating.",
            file=sys.stdout,
        )
        return 1

    try:
        plan = plan_migration(
            config,
            config_path=config_path,
            repo_root=repo_root,
            label_override=args.label,
            plist_path_override=args.plist_path.expanduser() if args.plist_path else None,
            use_current_repo=args.use_current_repo,
        )
    except Exception as exc:  # pragma: no cover - defensive reporting
        print(
            f"Migration status: FAILED\nMode: {'apply' if args.apply else 'dry-run'}\n"
            f"Config: {config_path}\n\nChecks:\n"
            f"- [FAIL] planning: {exc}\n"
            "  Remediation: Fix the migration inputs and rerun.",
            file=sys.stdout,
        )
        return 1

    if plan.blockers:
        print(render_report(plan, mode="dry-run" if args.dry_run else "apply"))
        return 1

    if args.dry_run:
        print(render_report(plan, mode="dry-run"))
        return 0

    post_checks, backups = apply_migration(plan, args.health_timeout_seconds)
    print(render_report(plan, mode="apply", post_checks=post_checks, backups=backups))
    return 0 if not failed_post_checks(post_checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
