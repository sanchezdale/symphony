from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from urllib import error, request

from .config import (
    GUARDRAIL_ACK,
    ConfigError,
    RepoConfig,
    assign_missing_ports,
    atomic_write_json,
    load_config,
    load_env_file,
    parse_repo,
)
from .prereqs import CheckResult, run_prerequisite_checks

LOGGER = logging.getLogger("symphony_manager")


def configure_logging(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def healthcheck(port: int, timeout_seconds: int) -> bool:
    return fetch_state_payload(port, timeout_seconds) is not None


def fetch_state_payload(port: int, timeout_seconds: int) -> dict | None:
    url = f"http://127.0.0.1:{port}/api/v1/state"
    try:
        with request.urlopen(url, timeout=timeout_seconds) as response:
            if response.status != 200:
                return None
            payload = json.loads(response.read().decode("utf-8"))
            return payload if isinstance(payload, dict) else None
    except (error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def post_webhook(url: str, payload: dict, timeout_seconds: int) -> None:
    body = json.dumps(payload, sort_keys=True).encode("utf-8")
    webhook_request = request.Request(
        url,
        data=body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    with request.urlopen(webhook_request, timeout=timeout_seconds) as response:
        response.read()


def repo_runtime_env(repo: RepoConfig) -> dict[str, str]:
    env = dict(os.environ)
    if repo.local_env_path is not None:
        env.update(load_env_file(repo.local_env_path))
    env.update(repo.env)
    return env


@dataclass
class ManagedProcess:
    repo: RepoConfig
    process: subprocess.Popen[str] | None = None
    failure_count: int = 0
    restart_attempts: int = 0
    blocked_reason: str | None = None
    blocked_until_config_change: bool = False
    next_start_time: float = 0.0


@dataclass
class Supervisor:
    config_path: Path
    sleep_fn: Callable[[float], None] = time.sleep
    time_fn: Callable[[], float] = time.time
    popen_factory: Callable[..., subprocess.Popen[str]] = subprocess.Popen
    healthcheck_fn: Callable[[int, int], bool] = healthcheck
    fetch_state_fn: Callable[[int, int], dict | None] = fetch_state_payload
    notify_fn: Callable[[str, dict, int], None] = post_webhook
    states: dict[str, ManagedProcess] = field(default_factory=dict)
    notification_cache: dict[str, float] = field(default_factory=dict)
    _config: dict | None = None
    _config_mtime: float | None = None

    def run_forever(self) -> None:
        LOGGER.info("Starting Symphony manager with config %s", self.config_path)
        while True:
            self.reload_config_if_needed(force=self._config is None)
            self.reconcile()
            manager = self.config["manager"]
            self.sleep_fn(float(manager["check_interval_seconds"]))

    @property
    def config(self) -> dict:
        if self._config is None:
            raise RuntimeError("Config not loaded")
        return self._config

    def reload_config_if_needed(self, force: bool = False) -> bool:
        try:
            mtime = self.config_path.stat().st_mtime
        except FileNotFoundError as exc:
            raise ConfigError(f"Config file disappeared: {self.config_path}") from exc

        manager_reload_seconds = 5
        if self._config is not None:
            manager_reload_seconds = self.config["manager"]["config_reload_seconds"]

        if not force and self._config_mtime == mtime:
            return False

        if not force and self._config_mtime is not None:
            elapsed = self.time_fn() - self._config_mtime
            if elapsed < manager_reload_seconds and mtime <= self._config_mtime:
                return False

        config = load_config(self.config_path)
        changed = assign_missing_ports(config)
        if changed:
            atomic_write_json(self.config_path, config)
            mtime = self.config_path.stat().st_mtime
            LOGGER.info("Assigned missing repo ports and persisted %s", self.config_path)

        self._config = config
        self._config_mtime = mtime
        for state in self.states.values():
            state.blocked_until_config_change = False
            state.blocked_reason = None
        LOGGER.info("Loaded config with %d repo(s)", len(config["repos"]))
        return True

    def reconcile(self) -> None:
        desired_ids = set()
        for entry in self.config["repos"]:
            repo = parse_repo(entry)
            desired_ids.add(repo.id)
            state = self.states.setdefault(repo.id, ManagedProcess(repo=repo))
            state.repo = repo

            if not repo.enabled:
                self.stop_repo(state, "repo disabled")
                continue

            if state.blocked_until_config_change:
                LOGGER.error("Repo %s is blocked until config changes: %s", repo.id, state.blocked_reason)
                continue

            self.ensure_repo_running(state)

        for repo_id in list(self.states):
            if repo_id not in desired_ids:
                self.stop_repo(self.states[repo_id], "repo removed from config")
                del self.states[repo_id]

    def ensure_repo_running(self, state: ManagedProcess) -> None:
        now = self.time_fn()
        if state.process is None:
            if now >= state.next_start_time:
                self.start_repo(state)
            return

        process = state.process
        if process.poll() is not None:
            LOGGER.warning("Repo %s exited with code %s", state.repo.id, process.returncode)
            state.process = None
            self.schedule_restart(state, "process exit")
            return

        timeout_seconds = self.config["manager"]["http_timeout_seconds"]
        if state.repo.port is None:
            self.block_repo(state, "repo has no assigned port after config load")
            return

        if self.healthcheck_fn(state.repo.port, timeout_seconds):
            if state.failure_count:
                LOGGER.info("Repo %s recovered after %d failed health check(s)", state.repo.id, state.failure_count)
            state.failure_count = 0
            self.observe_repo_state(state, self.fetch_state_fn(state.repo.port, timeout_seconds))
            return

        state.failure_count += 1
        threshold = self.config["manager"]["failure_threshold"]
        LOGGER.warning(
            "Repo %s failed health check %d/%d",
            state.repo.id,
            state.failure_count,
            threshold,
        )
        if state.failure_count < threshold:
            return

        self.stop_repo(state, "health check threshold reached")
        self.schedule_restart(state, "health check failure")

    def start_repo(self, state: ManagedProcess) -> None:
        repo = state.repo
        prereq_results = self._repo_start_checks(repo)
        failures = [result for result in prereq_results if not result.passed]
        if failures:
            detail = "; ".join(f"{result.name}: {result.detail}" for result in failures)
            self.block_repo(state, detail)
            LOGGER.error("Skipping repo %s due to prerequisite failures: %s", repo.id, detail)
            return

        repo.logs_root.mkdir(parents=True, exist_ok=True)
        try:
            runtime_env = repo_runtime_env(repo)
        except ConfigError as exc:
            self.block_repo(state, str(exc))
            LOGGER.error("Skipping repo %s due to env loading failure: %s", repo.id, exc)
            return

        command = [
            str(Path(self.config["symphony_bin"]).expanduser()),
            GUARDRAIL_ACK,
            "--logs-root",
            str(repo.logs_root),
            "--port",
            str(repo.port),
            str(repo.workflow_path),
        ]
        LOGGER.info("Starting repo %s on port %s", repo.id, repo.port)
        process = self.popen_factory(
            command,
            cwd=str(repo.repo_path),
            env=runtime_env,
            text=True,
        )
        state.process = process
        state.failure_count = 0

    def stop_repo(self, state: ManagedProcess, reason: str) -> None:
        process = state.process
        state.process = None
        state.failure_count = 0
        if process is None:
            return

        LOGGER.info("Stopping repo %s: %s", state.repo.id, reason)
        try:
            process.terminate()
            graceful_timeout = self.config["manager"]["graceful_shutdown_seconds"]
            process.wait(timeout=graceful_timeout)
        except subprocess.TimeoutExpired:
            LOGGER.warning("Force killing repo %s after graceful shutdown timeout", state.repo.id)
            process.kill()
            process.wait(timeout=5)

    def schedule_restart(self, state: ManagedProcess, reason: str) -> None:
        backoff_steps = self.config["manager"]["restart_backoff_seconds"]
        index = min(state.restart_attempts, len(backoff_steps) - 1)
        delay = backoff_steps[index]
        state.restart_attempts += 1
        state.next_start_time = self.time_fn() + delay
        LOGGER.warning("Scheduling restart for repo %s in %ss due to %s", state.repo.id, delay, reason)

    def block_repo(self, state: ManagedProcess, reason: str) -> None:
        self.stop_repo(state, f"blocking repo: {reason}")
        state.blocked_reason = reason
        state.blocked_until_config_change = True
        self.notify_event(
            "blocked_repo",
            f"{state.repo.id}:blocked:{reason}",
            {
                "repo": {
                    "id": state.repo.id,
                    "name": state.repo.name,
                    "path": str(state.repo.repo_path),
                },
                "details": {"reason": reason},
            },
        )

    def _repo_start_checks(self, repo: RepoConfig) -> list[CheckResult]:
        full_results = run_prerequisite_checks(self.config_path)
        prefix = f"repo:{repo.id}"
        relevant_names = {
            "python3",
            "config",
            "symphony_repo",
            "symphony_bin",
            "symphony_escript",
            "codex",
            f"{prefix}:repo_path",
            f"{prefix}:workflow_path",
            f"{prefix}:local_env_path",
            f"{prefix}:local_env_loaded",
        }
        return [result for result in full_results if result.name in relevant_names or result.name.startswith(f"{prefix}:env:")]

    def observe_repo_state(self, state: ManagedProcess, payload: dict | None) -> None:
        if not isinstance(payload, dict):
            return

        for issue in payload.get("running", []):
            pending = issue.get("pending_approval")
            if isinstance(pending, dict):
                event_type = pending.get("type")
                if isinstance(event_type, str) and event_type:
                    dedupe_source = pending.get("requested_at") or pending.get("summary") or issue.get("issue_identifier")
                    self.notify_event(
                        event_type,
                        f"{state.repo.id}:{issue.get('issue_identifier')}:{event_type}:{dedupe_source}",
                        {
                            "repo": {
                                "id": state.repo.id,
                                "name": state.repo.name,
                                "path": str(state.repo.repo_path),
                                "port": state.repo.port,
                            },
                            "issue": {
                                "id": issue.get("issue_id"),
                                "identifier": issue.get("issue_identifier"),
                                "state": issue.get("state"),
                            },
                            "details": pending,
                        },
                    )

        for issue in payload.get("retrying", []):
            pending = issue.get("pending_approval")
            if isinstance(pending, dict):
                event_type = pending.get("type")
                if isinstance(event_type, str) and event_type:
                    dedupe_source = pending.get("requested_at") or pending.get("summary") or issue.get("issue_identifier")
                    self.notify_event(
                        event_type,
                        f"{state.repo.id}:{issue.get('issue_identifier')}:{event_type}:{dedupe_source}",
                        {
                            "repo": {
                                "id": state.repo.id,
                                "name": state.repo.name,
                                "path": str(state.repo.repo_path),
                                "port": state.repo.port,
                            },
                            "issue": {
                                "id": issue.get("issue_id"),
                                "identifier": issue.get("issue_identifier"),
                                "attempt": issue.get("attempt"),
                            },
                            "details": pending,
                        },
                    )

            attempt = issue.get("attempt")
            if isinstance(attempt, int) and attempt >= 3:
                self.notify_event(
                    "retrying_issue",
                    f"{state.repo.id}:{issue.get('issue_identifier')}:retry:{attempt}",
                    {
                        "repo": {
                            "id": state.repo.id,
                            "name": state.repo.name,
                            "path": str(state.repo.repo_path),
                            "port": state.repo.port,
                        },
                        "issue": {
                            "id": issue.get("issue_id"),
                            "identifier": issue.get("issue_identifier"),
                            "attempt": attempt,
                        },
                        "details": {
                            "error": issue.get("error"),
                            "due_at": issue.get("due_at"),
                        },
                    },
                )

    def notify_event(self, event_type: str, dedupe_key: str, payload: dict) -> None:
        notifications = self.config.get("notifications", {})
        if not isinstance(notifications, dict):
            return

        if notifications.get("enabled") is not True:
            return

        webhook_url = notifications.get("webhook_url")
        if not isinstance(webhook_url, str) or not webhook_url.strip():
            return

        allowed_events = notifications.get("events", [])
        if isinstance(allowed_events, list) and allowed_events and event_type not in allowed_events:
            return

        cooldown_seconds = notifications.get("cooldown_seconds", 300)
        now = self.time_fn()
        last_sent_at = self.notification_cache.get(dedupe_key)
        if isinstance(last_sent_at, (int, float)) and now - last_sent_at < cooldown_seconds:
            return

        envelope = {
            "source": "symphony_manager",
            "event": event_type,
            "sent_at": datetime.now(timezone.utc).isoformat(),
            **payload,
        }

        try:
            self.notify_fn(webhook_url, envelope, self.config["manager"]["http_timeout_seconds"])
            self.notification_cache[dedupe_key] = now
        except Exception as exc:  # pragma: no cover - defensive logging
            LOGGER.warning("Failed sending notification %s: %s", event_type, exc)


def install_signal_handlers(supervisor: Supervisor) -> None:
    def handle_signal(signum: int, _frame: object) -> None:
        LOGGER.info("Received signal %s, shutting down managed repos", signum)
        for state in list(supervisor.states.values()):
            supervisor.stop_repo(state, f"signal {signum}")
        raise SystemExit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
