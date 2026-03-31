---
name: setup-symphony-manager
description:
  Set up, verify, and operate the multi-repo Symphony host supervisor on a Mac;
  use when asked to scaffold ~/.config/symphony/config.json, audit
  prerequisites on a target machine, generate a launchd plist, or run the
  supervisor that manages one Symphony instance per repo.
---

# Setup Symphony Manager

Use this skill when the user wants Codex to configure or operate the host-side
multi-repo Symphony supervisor introduced in this repo.

## Source Of Truth

- Manager code: `scripts/symphony_manager/`
- Usage and config details: `scripts/symphony_manager/README.md`

Read the README first if you need command syntax or config examples. Prefer
using the Python CLI instead of re-explaining the workflow from memory.

## Main Commands

Run from the repository root:

```bash
python3 -m scripts.symphony_manager init
python3 -m scripts.symphony_manager check
python3 -m scripts.symphony_manager plist
python3 -m scripts.symphony_manager setup
python3 -m scripts.symphony_manager run
```

Common options:

- `--config /path/to/config.json`
- `init --interactive`
- `check --require-launchd`
- `plist --output ~/Library/LaunchAgents/dev.symphony.manager.plist`

## Workflow

1. Confirm the target machine has the Symphony checkout and build artifacts or
   run the prerequisite checker to see what is missing.
2. Scaffold config with `init` or `setup`.
3. Edit `~/.config/symphony/config.json` so each repo has real `repo_path`,
   `workflow_path`, and preferably a `local_env_path` for workflow variables.
4. Put repo-specific secrets and workflow inputs such as `LINEAR_API_KEY`,
   `SYMPHONY_PROJECT_SLUG`, and `SYMPHONY_WORKSPACE_ROOT` in that `local.env`
   file unless the user explicitly wants inline `repos[].env` overrides.
5. Run `check --require-launchd` and fix every reported failure before launchd
   setup.
6. Generate the plist with `plist`.
7. Only if the user wants it, provide or run the manual `launchctl bootstrap`
   and `launchctl kickstart` commands.
8. For foreground debugging, use `run --verbose`.

## Guardrails

- Do not assume the target host already has `codex`, `mise`, or a built
  `symphony.escript`; use `check` to verify.
- Do not install or load the launchd plist unless the user explicitly asks.
- Keep `workflow_path` explicit per repo; do not silently derive it.
- Prefer `local_env_path` for repo-specific runtime variables and use
  `repos[].env` only for explicit per-repo overrides.
- Treat failing prerequisite checks as blockers, not warnings.
- If the user asks for a ready-to-paste config, generate JSON that matches the
  manager schema in `scripts/symphony_manager/README.md`.
