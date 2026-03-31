from __future__ import annotations

import json
import socket
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.symphony_manager.cli import build_parser
from scripts.symphony_manager.config import ConfigError, assign_missing_ports, atomic_write_json, default_config, load_config, parse_repo
from scripts.symphony_manager.launchd import build_launchd_plist
from scripts.symphony_manager.prereqs import run_prerequisite_checks, summarize_results
from scripts.symphony_manager.supervisor import ManagedProcess, Supervisor


class ConfigTests(unittest.TestCase):
    def test_atomic_write_and_load_config(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "config.json"
            config = default_config()
            config["repos"] = []
            atomic_write_json(path, config)
            loaded = load_config(path)
            self.assertEqual(loaded["version"], 1)
            self.assertEqual(loaded["repos"], [])

    def test_assign_missing_ports_preserves_existing_ports(self) -> None:
        config = default_config()
        config["repos"] = [
            {
                "id": "repo-a",
                "name": "Repo A",
                "repo_path": "/tmp/repo-a",
                "workflow_path": "/tmp/repo-a/WORKFLOW.md",
                "logs_root": "/tmp/repo-a/logs",
                "port": 43110,
                "enabled": True,
                "env": {},
            },
            {
                "id": "repo-b",
                "name": "Repo B",
                "repo_path": "/tmp/repo-b",
                "workflow_path": "/tmp/repo-b/WORKFLOW.md",
                "logs_root": "/tmp/repo-b/logs",
                "port": None,
                "enabled": True,
                "env": {},
            },
        ]
        changed = assign_missing_ports(config)
        self.assertTrue(changed)
        self.assertEqual(config["repos"][0]["port"], 43110)
        self.assertIsInstance(config["repos"][1]["port"], int)
        self.assertNotEqual(config["repos"][1]["port"], 43110)

    def test_assign_missing_ports_skips_bound_port(self) -> None:
        config = default_config()
        config["manager"]["port_range"] = {"start": 43100, "end": 43102}
        config["repos"] = [
            {
                "id": "repo-a",
                "name": "Repo A",
                "repo_path": "/tmp/repo-a",
                "workflow_path": "/tmp/repo-a/WORKFLOW.md",
                "logs_root": "/tmp/repo-a/logs",
                "port": None,
                "enabled": True,
                "env": {},
            }
        ]
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 43100))
            assign_missing_ports(config)
        self.assertIn(config["repos"][0]["port"], {43101, 43102})

    def test_assign_missing_ports_fails_when_range_is_exhausted(self) -> None:
        config = default_config()
        config["manager"]["port_range"] = {"start": 43100, "end": 43100}
        config["repos"] = [
            {
                "id": "repo-a",
                "name": "Repo A",
                "repo_path": "/tmp/repo-a",
                "workflow_path": "/tmp/repo-a/WORKFLOW.md",
                "logs_root": "/tmp/repo-a/logs",
                "port": None,
                "enabled": True,
                "env": {},
            }
        ]
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 43100))
            with self.assertRaises(ConfigError):
                assign_missing_ports(config)


class PrerequisiteTests(unittest.TestCase):
    def write_config(self, temp_dir: str) -> Path:
        root = Path(temp_dir)
        symphony_repo = root / "symphony"
        repo_path = root / "repo-a"
        workflow_path = symphony_repo / "workflows" / "repo-a" / "WORKFLOW.md"
        symphony_bin = symphony_repo / "elixir" / "bin" / "symphony"
        escript_path = symphony_bin.parent / "symphony.escript"

        workflow_path.parent.mkdir(parents=True, exist_ok=True)
        symphony_bin.parent.mkdir(parents=True, exist_ok=True)
        repo_path.mkdir(parents=True, exist_ok=True)
        workflow_path.write_text("tracker:\n  kind: linear\n", encoding="utf-8")
        symphony_bin.write_text("#!/bin/sh\n", encoding="utf-8")
        escript_path.write_text("escript", encoding="utf-8")

        config = default_config()
        config["symphony_repo"] = str(symphony_repo)
        config["symphony_bin"] = str(symphony_bin)
        config["repos"] = [
            {
                "id": "repo-a",
                "name": "Repo A",
                "repo_path": str(repo_path),
                "workflow_path": str(workflow_path),
                "logs_root": str(root / "logs"),
                "port": 43110,
                "enabled": True,
                "env": {},
            }
        ]
        config_path = root / "config.json"
        atomic_write_json(config_path, config)
        return config_path

    def test_prerequisite_checks_report_missing_codex(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = self.write_config(temp_dir)
            env = {"PATH": "/usr/bin", "LINEAR_API_KEY": "token", "OSTYPE": "darwin"}
            with mock.patch("scripts.symphony_manager.prereqs.find_command") as find_command:
                find_command.side_effect = lambda command, _env=None: {
                    "python3": "/usr/bin/python3",
                    "launchctl": "/bin/launchctl",
                }.get(command)
                results = run_prerequisite_checks(config_path, require_launchd=True, env=env)
            passed, report = summarize_results(results)
            self.assertFalse(passed)
            self.assertIn("codex", report)

    def test_prerequisite_checks_report_missing_linear_env(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = self.write_config(temp_dir)
            env = {"PATH": "/usr/bin", "OSTYPE": "darwin"}
            with mock.patch("scripts.symphony_manager.prereqs.find_command") as find_command:
                find_command.side_effect = lambda command, _env=None: {
                    "python3": "/usr/bin/python3",
                    "codex": "/usr/bin/codex",
                    "launchctl": "/bin/launchctl",
                }.get(command)
                results = run_prerequisite_checks(config_path, require_launchd=True, env=env)
            passed, report = summarize_results(results)
            self.assertFalse(passed)
            self.assertIn("LINEAR_API_KEY", report)


class FakeProcess:
    def __init__(self, returncode: int | None = None) -> None:
        self.returncode = returncode
        self.terminated = False
        self.killed = False

    def poll(self) -> int | None:
        return self.returncode

    def terminate(self) -> None:
        self.terminated = True
        self.returncode = 0

    def wait(self, timeout: int | None = None) -> int:
        return self.returncode or 0

    def kill(self) -> None:
        self.killed = True
        self.returncode = -9


class SupervisorTests(unittest.TestCase):
    def make_config(self, temp_dir: str) -> Path:
        root = Path(temp_dir)
        symphony_repo = root / "symphony"
        repo_path = root / "repo-a"
        workflow_path = symphony_repo / "workflows" / "repo-a" / "WORKFLOW.md"
        symphony_bin = symphony_repo / "elixir" / "bin" / "symphony"
        escript_path = symphony_bin.parent / "symphony.escript"
        for path in [workflow_path.parent, symphony_bin.parent, repo_path]:
            path.mkdir(parents=True, exist_ok=True)
        workflow_path.write_text("tracker:\n  kind: memory\n", encoding="utf-8")
        symphony_bin.write_text("#!/bin/sh\n", encoding="utf-8")
        escript_path.write_text("escript", encoding="utf-8")
        config = default_config()
        config["symphony_repo"] = str(symphony_repo)
        config["symphony_bin"] = str(symphony_bin)
        config["manager"]["check_interval_seconds"] = 1
        config["repos"] = [
            {
                "id": "repo-a",
                "name": "Repo A",
                "repo_path": str(repo_path),
                "workflow_path": str(workflow_path),
                "logs_root": str(root / "logs"),
                "port": 43110,
                "enabled": True,
                "env": {},
            }
        ]
        config_path = root / "config.json"
        atomic_write_json(config_path, config)
        return config_path

    def test_supervisor_starts_enabled_repo(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = self.make_config(temp_dir)
            spawned: list[list[str]] = []

            def fake_popen(command, **kwargs):
                spawned.append(command)
                return FakeProcess()

            with mock.patch("scripts.symphony_manager.supervisor.run_prerequisite_checks") as checks:
                checks.return_value = []
                supervisor = Supervisor(config_path=config_path, popen_factory=fake_popen, healthcheck_fn=lambda *_: True)
                supervisor.reload_config_if_needed(force=True)
                supervisor.reconcile()

            self.assertEqual(len(spawned), 1)
            self.assertIn("--port", spawned[0])

    def test_supervisor_restarts_on_process_exit(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = self.make_config(temp_dir)
            now = 1000.0

            with mock.patch("scripts.symphony_manager.supervisor.run_prerequisite_checks") as checks:
                checks.return_value = []
                supervisor = Supervisor(
                    config_path=config_path,
                    time_fn=lambda: now,
                    sleep_fn=lambda *_: None,
                    popen_factory=lambda *args, **kwargs: FakeProcess(),
                    healthcheck_fn=lambda *_: True,
                )
                supervisor.reload_config_if_needed(force=True)
            repo = parse_repo(supervisor.config["repos"][0])
            state = ManagedProcess(repo=repo, process=FakeProcess(returncode=1))
            supervisor.states["repo-a"] = state
            supervisor.ensure_repo_running(state)
            self.assertIsNone(state.process)
            self.assertGreater(state.next_start_time, now)

    def test_supervisor_restarts_after_health_threshold(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = self.make_config(temp_dir)
            process = FakeProcess()
            health_results = iter([False, False, False])

            with mock.patch("scripts.symphony_manager.supervisor.run_prerequisite_checks") as checks:
                checks.return_value = []
                supervisor = Supervisor(
                    config_path=config_path,
                    popen_factory=lambda *args, **kwargs: process,
                    healthcheck_fn=lambda *_: next(health_results),
                )
                supervisor.reload_config_if_needed(force=True)
                repo = parse_repo(supervisor.config["repos"][0])
                state = ManagedProcess(repo=repo)
                state.process = process
                supervisor.states["repo-a"] = state
                supervisor.ensure_repo_running(state)
                supervisor.ensure_repo_running(state)
                supervisor.ensure_repo_running(state)

            self.assertIsNone(state.process)
            self.assertEqual(state.failure_count, 0)
            self.assertGreater(state.next_start_time, 0)


class LaunchdTests(unittest.TestCase):
    def test_build_launchd_plist_contains_expected_arguments(self) -> None:
        payload = build_launchd_plist(
            label="dev.symphony.manager",
            python_executable="/usr/bin/python3",
            repo_root=Path("/opt/symphony"),
            config_path=Path("/Users/example/.config/symphony/config.json"),
        )
        text = payload.decode("utf-8")
        self.assertIn("scripts.symphony_manager", text)
        self.assertIn("config.json", text)


class CliTests(unittest.TestCase):
    def test_parser_accepts_setup_command(self) -> None:
        parser = build_parser()
        args = parser.parse_args(["setup"])
        self.assertEqual(args.command, "setup")


if __name__ == "__main__":
    unittest.main()
