---
name: migrate-symphony-manager
description:
  Migrate an existing macOS host from the removed Python Symphony manager flow
  to the current Elixir manager flow; validate config and prerequisites,
  rewrite the LaunchAgent, cut over the service, verify repo health, and print
  a migration report.
---

# Migrate Symphony Manager

Use this skill when the machine already has the legacy Python multi-repo
manager setup and needs to be moved to the supported Elixir manager flow.

## Source Of Truth

- Current manager usage and config: `elixir/README.md`
- Current manager CLI: `elixir/lib/symphony_elixir/manager_cli.ex`
- Current manager config validation: `elixir/lib/symphony_elixir/manager_config.ex`
- Migration helper: `scripts/migrate_manager.py`

Read `elixir/README.md` first if you need current manager behavior or config
details. Use the helper script for the actual migration instead of recreating
the cutover logic by hand.

## Main Commands

Run from the repository root:

```bash
python3 .codex/skills/migrate-symphony-manager/scripts/migrate_manager.py \
  --use-current-repo \
  --dry-run

python3 .codex/skills/migrate-symphony-manager/scripts/migrate_manager.py \
  --use-current-repo \
  --apply
```

Common options:

- `--config /path/to/config.json`
- `--plist-path ~/Library/LaunchAgents/dev.symphony.manager.plist`
- `--health-timeout-seconds 45`

## Workflow

1. Confirm the machine is macOS and already has an existing
   `~/.config/symphony/config.json`.
2. Run the helper with `--dry-run` first.
3. If the dry run reports blockers, stop and surface the script remediation
   exactly.
4. If the dry run is clean, rerun with `--apply`.
5. Review the final migration report and highlight any manual follow-up.

## Guardrails

- Use this skill only for existing legacy-manager installs. For first-time
  setup, use `setup-symphony-manager`.
- Run the helper from the Symphony checkout that should own the new manager.
- Treat missing `launchctl`, unreadable `config.json`, missing `codex`, missing
  `elixir/bin/symphony`, missing `elixir/bin/symphony.escript`, or failing repo
  health checks as blockers.
- Do not keep the legacy Python LaunchAgent `ProgramArguments` after a
  successful migration.
- Re-runs must be idempotent: do not create duplicate services or extra plist
  copies when the existing LaunchAgent already matches the Elixir flow.
