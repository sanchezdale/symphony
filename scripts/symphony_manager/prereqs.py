from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from .config import ConfigError, load_config, parse_repo


@dataclass(frozen=True)
class CheckResult:
    name: str
    passed: bool
    detail: str
    fix: str | None = None


def find_command(command: str, env: dict[str, str] | None = None) -> str | None:
    search_path = None if env is None else env.get("PATH")
    return shutil.which(command, path=search_path)


def parse_workflow_env_requirements(workflow_path: Path) -> set[str]:
    try:
        content = workflow_path.read_text(encoding="utf-8")
    except OSError:
        return set()

    required: set[str] = set()
    if "LINEAR_API_KEY" in content or "tracker:\n  kind: linear" in content or "kind: linear" in content:
        required.add("LINEAR_API_KEY")
    return required


def run_prerequisite_checks(
    config_path: Path,
    require_launchd: bool = False,
    env: dict[str, str] | None = None,
) -> list[CheckResult]:
    active_env = dict(os.environ if env is None else env)
    results: list[CheckResult] = []

    python_path = find_command("python3", active_env)
    results.append(
        CheckResult(
            name="python3",
            passed=python_path is not None,
            detail=python_path or "python3 not found in PATH",
            fix="Install Python 3 and ensure `python3` is on PATH." if python_path is None else None,
        )
    )

    if require_launchd:
        is_macos = active_env.get("OSTYPE", "").startswith("darwin") or os.uname().sysname == "Darwin"
        launchctl_path = find_command("launchctl", active_env)
        passed = is_macos and launchctl_path is not None
        results.append(
            CheckResult(
                name="launchd",
                passed=passed,
                detail="launchd tooling available" if passed else "launchd requires macOS with `launchctl` available",
                fix="Run this on macOS and ensure `launchctl` is available before generating or loading the plist."
                if not passed
                else None,
            )
        )

    try:
        config = load_config(config_path)
        results.append(CheckResult(name="config", passed=True, detail=f"Loaded {config_path}"))
    except ConfigError as exc:
        results.append(
            CheckResult(
                name="config",
                passed=False,
                detail=str(exc),
                fix="Run the init command to scaffold a valid config.json, then update the repo entries.",
            )
        )
        return results

    symphony_repo = Path(config["symphony_repo"]).expanduser()
    symphony_bin = Path(config["symphony_bin"]).expanduser()
    escript_path = symphony_bin.parent / "symphony.escript"

    results.extend(
        [
            path_check(
                "symphony_repo",
                symphony_repo,
                "directory",
                f"Clone Symphony to {symphony_repo} or update `symphony_repo` in config.json.",
            ),
            path_check(
                "symphony_bin",
                symphony_bin,
                "file",
                "Ensure `elixir/bin/symphony` exists and is executable in the Symphony checkout.",
            ),
        ]
    )

    if escript_path.is_file():
        results.append(CheckResult(name="symphony_escript", passed=True, detail=f"Found {escript_path}"))
    else:
        mise_path = find_command("mise", active_env)
        escript_bin = find_command("escript", active_env)
        mix_bin = find_command("mix", active_env)
        passed = (mise_path is not None) or (escript_bin is not None and mix_bin is not None)
        fix = (
            "Build Symphony once with `cd <symphony_repo>/elixir && mise trust && mise install && mise exec -- mix build`, "
            "or install Elixir/Erlang so `mix build` can create `bin/symphony.escript`."
        )
        detail_parts = []
        if mise_path:
            detail_parts.append(f"mise available at {mise_path}")
        if escript_bin:
            detail_parts.append(f"escript available at {escript_bin}")
        if mix_bin:
            detail_parts.append(f"mix available at {mix_bin}")
        if not detail_parts:
            detail_parts.append("Missing `symphony.escript` and no build toolchain detected")
        results.append(
            CheckResult(
                name="symphony_escript",
                passed=passed,
                detail="; ".join(detail_parts),
                fix=None if passed else fix,
            )
        )

    codex_path = find_command("codex", active_env)
    results.append(
        CheckResult(
            name="codex",
            passed=codex_path is not None,
            detail=codex_path or "codex not found in PATH",
            fix="Install Codex and ensure the `codex` binary is on PATH for the launchd user."
            if codex_path is None
            else None,
        )
    )

    for entry in config["repos"]:
        repo = parse_repo(entry)
        prefix = f"repo:{repo.id}"
        results.append(
            path_check(
                f"{prefix}:repo_path",
                repo.repo_path,
                "directory",
                f"Clone or mount the repo at {repo.repo_path}, or update `repo_path`.",
            )
        )
        results.append(
            path_check(
                f"{prefix}:workflow_path",
                repo.workflow_path,
                "file",
                f"Create the workflow at {repo.workflow_path}, or update `workflow_path`.",
            )
        )

        required_env = parse_workflow_env_requirements(repo.workflow_path)
        effective_env = dict(active_env)
        effective_env.update(repo.env)
        for variable in sorted(required_env):
            present = bool(effective_env.get(variable))
            results.append(
                CheckResult(
                    name=f"{prefix}:env:{variable}",
                    passed=present,
                    detail=f"{variable} is set" if present else f"{variable} is missing",
                    fix=f"Export {variable} for the launchd user or set it in repos[].env for `{repo.id}`."
                    if not present
                    else None,
                )
            )

    return results


def path_check(name: str, path: Path, expected: str, fix: str) -> CheckResult:
    if expected == "directory":
        passed = path.is_dir()
    elif expected == "file":
        passed = path.is_file()
    else:
        raise ValueError(f"Unsupported expected path kind: {expected}")

    detail = f"Found {path}" if passed else f"Missing {expected}: {path}"
    return CheckResult(name=name, passed=passed, detail=detail, fix=None if passed else fix)


def summarize_results(results: Iterable[CheckResult]) -> tuple[bool, str]:
    lines: list[str] = []
    passed_all = True
    for result in results:
        status = "PASS" if result.passed else "FAIL"
        lines.append(f"[{status}] {result.name}: {result.detail}")
        if result.fix and not result.passed:
            lines.append(f"       Fix: {result.fix}")
            passed_all = False
        elif not result.passed:
            passed_all = False
    return passed_all, "\n".join(lines)
