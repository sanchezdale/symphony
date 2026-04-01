from __future__ import annotations

import os
import plistlib
from pathlib import Path

from .config import DEFAULT_CONFIG_DIR


def default_plist_path(label: str) -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"


def build_launchd_plist(
    *,
    label: str,
    python_executable: str,
    repo_root: Path,
    config_path: Path,
    stdout_path: Path | None = None,
    stderr_path: Path | None = None,
) -> bytes:
    environment = {"PYTHONUNBUFFERED": "1"}
    current_path = os.environ.get("PATH")
    if current_path:
        environment["PATH"] = current_path
    program_arguments = [
        python_executable,
        "-m",
        "scripts.symphony_manager",
        "--config",
        str(config_path),
        "run",
    ]
    payload = {
        "Label": label,
        "ProgramArguments": program_arguments,
        "WorkingDirectory": str(repo_root),
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "EnvironmentVariables": environment,
        "StandardOutPath": str(stdout_path or DEFAULT_CONFIG_DIR / "manager.log"),
        "StandardErrorPath": str(stderr_path or DEFAULT_CONFIG_DIR / "manager.error.log"),
    }
    return plistlib.dumps(payload)


def write_launchd_plist(
    *,
    destination: Path,
    label: str,
    python_executable: str,
    repo_root: Path,
    config_path: Path,
    stdout_path: Path | None = None,
    stderr_path: Path | None = None,
) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = build_launchd_plist(
        label=label,
        python_executable=python_executable,
        repo_root=repo_root,
        config_path=config_path,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
    )
    destination.write_bytes(payload)
    return destination
