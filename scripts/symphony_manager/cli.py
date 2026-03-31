from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from .config import DEFAULT_CONFIG_PATH, DEFAULT_MANAGER_LABEL, atomic_write_json, default_config, ensure_config_dir, load_config
from .launchd import default_plist_path, write_launchd_plist
from .prereqs import run_prerequisite_checks, summarize_results
from .supervisor import Supervisor, configure_logging, install_signal_handlers


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage multiple Symphony instances on one host.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH, help="Path to config.json")
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging")

    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Scaffold ~/.config/symphony/config.json")
    init_parser.add_argument("--force", action="store_true", help="Overwrite an existing config file")
    init_parser.add_argument("--interactive", action="store_true", help="Prompt for the first repo entry")

    check_parser = subparsers.add_parser("check", help="Run prerequisite checks")
    check_parser.add_argument("--require-launchd", action="store_true", help="Fail if launchd tooling is unavailable")

    plist_parser = subparsers.add_parser("plist", help="Generate a launchd plist without installing it")
    plist_parser.add_argument("--label", default=DEFAULT_MANAGER_LABEL, help="launchd Label value")
    plist_parser.add_argument("--output", type=Path, help="Destination plist path")

    setup_parser = subparsers.add_parser("setup", help="Combine init/check/plist steps in one run")
    setup_parser.add_argument("--force", action="store_true", help="Overwrite an existing config file")
    setup_parser.add_argument("--interactive", action="store_true", help="Prompt for the first repo entry")
    setup_parser.add_argument("--skip-init", action="store_true", help="Skip config scaffolding")
    setup_parser.add_argument("--skip-check", action="store_true", help="Skip prerequisite checks")
    setup_parser.add_argument("--skip-plist", action="store_true", help="Skip launchd plist generation")
    setup_parser.add_argument("--require-launchd", action="store_true", help="Require launchd during checks")
    setup_parser.add_argument("--label", default=DEFAULT_MANAGER_LABEL, help="launchd Label value")
    setup_parser.add_argument("--output", type=Path, help="Destination plist path")

    subparsers.add_parser("run", help="Run the long-lived Symphony supervisor")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    configure_logging(verbose=args.verbose)

    if args.command == "init":
        init_config(args.config, args.force, args.interactive)
        return 0

    if args.command == "check":
        return run_checks(args.config, require_launchd=args.require_launchd)

    if args.command == "plist":
        generate_plist(args.config, args.label, args.output)
        return 0

    if args.command == "setup":
        return run_setup(args)

    if args.command == "run":
        return run_supervisor(args.config)

    parser.error(f"Unsupported command: {args.command}")
    return 2


def init_config(config_path: Path, force: bool, interactive: bool) -> None:
    ensure_config_dir(config_path)
    if config_path.exists() and not force:
        raise SystemExit(f"Config already exists at {config_path}. Pass --force to overwrite it.")

    config = default_config()
    if interactive:
        config["repos"] = [prompt_repo_entry()]
    atomic_write_json(config_path, config)
    print(f"Wrote {config_path}")


def prompt_repo_entry() -> dict:
    print("Enter the first managed repo. Leave the port blank to auto-assign it later.")
    repo_id = input("Repo id: ").strip()
    name = input("Repo name: ").strip() or repo_id
    repo_path = input("Repo path: ").strip()
    workflow_path = input("Workflow path: ").strip()
    logs_root = input("Logs root (blank for default): ").strip()
    port_raw = input("Port (blank for auto): ").strip()

    config_dir = DEFAULT_CONFIG_PATH.parent
    return {
        "id": repo_id,
        "name": name,
        "repo_path": repo_path,
        "workflow_path": workflow_path,
        "logs_root": logs_root or str(config_dir / "logs" / repo_id),
        "port": int(port_raw) if port_raw else None,
        "enabled": True,
        "env": {},
    }


def run_checks(config_path: Path, require_launchd: bool) -> int:
    results = run_prerequisite_checks(config_path, require_launchd=require_launchd)
    passed, report = summarize_results(results)
    print(report)
    return 0 if passed else 1


def generate_plist(config_path: Path, label: str, output: Path | None) -> None:
    config = load_config(config_path)
    repo_root = Path(config["symphony_repo"]).expanduser()
    destination = output or default_plist_path(label)
    manager = config["manager"]
    plist_path = write_launchd_plist(
        destination=destination,
        label=label,
        python_executable=sys.executable,
        repo_root=repo_root,
        config_path=config_path,
        stdout_path=Path(manager["launchd_log_path"]).expanduser(),
        stderr_path=Path(manager["launchd_error_log_path"]).expanduser(),
    )
    print(f"Wrote {plist_path}")
    print("Install manually with:")
    print(f"  launchctl bootstrap gui/$(id -u) {plist_path}")


def run_setup(args: argparse.Namespace) -> int:
    if not args.skip_init:
        init_config(args.config, args.force, args.interactive)
    if not args.skip_check:
        check_exit = run_checks(args.config, require_launchd=args.require_launchd)
        if check_exit != 0:
            return check_exit
    if not args.skip_plist:
        generate_plist(args.config, args.label, args.output)
    return 0


def run_supervisor(config_path: Path) -> int:
    supervisor = Supervisor(config_path=config_path)
    install_signal_handlers(supervisor)
    supervisor.run_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
