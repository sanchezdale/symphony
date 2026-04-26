from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "scripts" / "migrate_manager.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location("migrate_manager", MODULE_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class MigrateManagerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def valid_config(self, root: Path) -> dict:
        repo_path = root / "repo-a"
        workflow_path = root / "workflows" / "repo-a" / "WORKFLOW.md"
        return {
            "version": 1,
            "symphony_repo": str(root / "legacy-symphony"),
            "symphony_bin": str(root / "legacy-symphony" / "elixir" / "bin" / "symphony"),
            "manager": {
                "check_interval_seconds": 30,
                "http_timeout_seconds": 5,
                "failure_threshold": 3,
                "restart_backoff_seconds": [5, 15, 30],
                "port_range": {"start": 43_100, "end": 43_105},
                "graceful_shutdown_seconds": 10,
                "config_reload_seconds": 5,
                "launchd_label": "dev.symphony.manager",
                "launchd_log_path": str(root / "manager.log"),
                "launchd_error_log_path": str(root / "manager.error.log"),
            },
            "repos": [
                {
                    "id": "repo-a",
                    "name": "Repo A",
                    "repo_path": str(repo_path),
                    "workflow_path": str(workflow_path),
                    "logs_root": str(root / "logs" / "repo-a"),
                    "local_env_path": str(repo_path / "local.env"),
                    "port": 43_101,
                    "enabled": True,
                    "env": {},
                }
            ],
        }

    def test_normalize_config_can_pin_current_repo_without_touching_repos(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config = self.valid_config(root)
            repo_root = root / "current-symphony"

            normalized, changes = self.module.normalize_config(
                config,
                repo_root=repo_root,
                use_current_repo=True,
            )

            self.assertEqual(str(repo_root), normalized["symphony_repo"])
            self.assertEqual(str(repo_root / "elixir" / "bin" / "symphony"), normalized["symphony_bin"])
            self.assertEqual(config["repos"], normalized["repos"])
            self.assertTrue(any(change.target == "config.json" for change in changes))

    def test_build_launchd_plist_uses_elixir_manager_program_arguments(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = self.module.build_launchd_plist(
                label="dev.symphony.manager",
                config_path=root / "config.json",
                symphony_repo=root / "symphony",
                symphony_bin=root / "symphony" / "elixir" / "bin" / "symphony",
                stdout_path=root / "manager.log",
                stderr_path=root / "manager.error.log",
                env={"PATH": "/usr/bin:/bin"},
            )

            self.assertEqual(
                [
                    str(root / "symphony" / "elixir" / "bin" / "symphony"),
                    self.module.GUARDRAIL_ACK,
                    "manager",
                    "--config",
                    str(root / "config.json"),
                    "run",
                ],
                payload["ProgramArguments"],
            )
            self.assertEqual("dev.symphony.manager", payload["Label"])

    def test_plist_mode_detects_legacy_python_launch_agent(self):
        payload = {
            "ProgramArguments": [
                "/usr/bin/python3",
                "-m",
                "scripts.symphony_manager",
                "--config",
                "/tmp/config.json",
                "run",
            ]
        }

        self.assertEqual("legacy_python", self.module.plist_mode(payload))

    def test_plan_migration_is_idempotent_when_plist_already_matches(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            symphony_repo = root / "symphony"
            (symphony_repo / ".git").mkdir(parents=True)
            (symphony_repo / "elixir" / "bin").mkdir(parents=True)
            (symphony_repo / "elixir" / "bin" / "symphony").write_text("", encoding="utf-8")

            repo_path = root / "repo-a"
            workflow_path = root / "workflows" / "repo-a" / "WORKFLOW.md"
            repo_path.mkdir(parents=True)
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text("tracker:\n  kind: linear\n", encoding="utf-8")
            (repo_path / "local.env").write_text("LINEAR_API_KEY=test\n", encoding="utf-8")

            config = self.valid_config(root)
            config["symphony_repo"] = str(symphony_repo)
            config["symphony_bin"] = str(symphony_repo / "elixir" / "bin" / "symphony")
            config_path = root / "config.json"
            config_path.write_text("{}", encoding="utf-8")

            desired_plist = self.module.build_launchd_plist(
                label=self.module.DEFAULT_LABEL,
                config_path=config_path,
                symphony_repo=symphony_repo,
                symphony_bin=symphony_repo / "elixir" / "bin" / "symphony",
                stdout_path=Path(config["manager"]["launchd_log_path"]),
                stderr_path=Path(config["manager"]["launchd_error_log_path"]),
                env=os.environ,
            )

            original_read_plist = self.module.read_plist
            original_service_loaded = self.module.service_loaded
            original_validate_prerequisites = self.module.validate_prerequisites
            self.addCleanup(setattr, self.module, "read_plist", original_read_plist)
            self.addCleanup(setattr, self.module, "service_loaded", original_service_loaded)
            self.addCleanup(setattr, self.module, "validate_prerequisites", original_validate_prerequisites)
            self.module.read_plist = lambda _path: desired_plist
            self.module.service_loaded = lambda _service: True
            self.module.validate_prerequisites = lambda _config, _config_path: []

            plan = self.module.plan_migration(
                config,
                config_path=config_path,
                repo_root=symphony_repo,
                label_override=None,
                plist_path_override=root / "dev.symphony.manager.plist",
                use_current_repo=False,
            )

            self.assertFalse(plan.blockers)
            self.assertFalse(plan.changes)


if __name__ == "__main__":
    unittest.main()
