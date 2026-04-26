---
name: setup-symphony-manager
description:
  Set up, verify, and operate the multi-repo Symphony host supervisor on a Mac;
  use when asked to scaffold ~/.config/symphony/config.json, audit
  prerequisites on a target machine, or run the supervisor that manages one
  Symphony instance per repo.
---

# Setup Symphony Manager

Use this skill when the user wants Codex to configure or operate the host-side
multi-repo Symphony supervisor introduced in this repo.

## Source Of Truth

- Usage and config details: `elixir/README.md`
- Manager CLI implementation: `elixir/lib/symphony_elixir/manager_cli.ex`
- Manager config validation: `elixir/lib/symphony_elixir/manager_config.ex`

Read `elixir/README.md` first if you need command syntax or config examples.
Do not mention the removed `scripts.symphony_manager` Python CLI.

## Main Commands

Run from `elixir/`:

```bash
mise trust
mise install
mise exec -- mix setup
./bin/symphony manager --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Common options:

- `--config /path/to/config.json`
- `--port 4000`

Optional helper if the user already manages the Elixir manager through a
manually installed LaunchAgent:

```bash
../scripts/symphony-restart
```

## Workflow

1. Confirm the target machine has the Symphony checkout and the Elixir runtime
   prerequisites described in `elixir/README.md`.
2. Scaffold `~/.config/symphony/config.json` from the example in
   `elixir/README.md`.
3. Edit `~/.config/symphony/config.json` so each repo has real `repo_path`,
   `workflow_path`, and preferably a `local_env_path` for workflow variables.
4. Put repo-specific secrets and workflow inputs such as `LINEAR_API_KEY`,
   `SYMPHONY_PROJECT_SLUG`, and `SYMPHONY_WORKSPACE_ROOT` in that `local.env`
   file unless the user explicitly wants inline `repos[].env` overrides.
5. Run the manager in the foreground first with `./bin/symphony manager ...` to
   validate the config and repo startup path.
6. Add `--port` if the user wants the manager dashboard.
7. Only if the user explicitly asks for `launchd`, explain that this repo no
   longer generates plists and any LaunchAgent file must be created and managed
   manually outside Symphony.
8. If a LaunchAgent is already installed, `../scripts/symphony-restart` can
   kick it without reloading the plist path logic by hand.

## Guardrails

- Do not suggest or run `python3 -m scripts.symphony_manager`; that flow is
  removed.
- Do not assume the target host already has `codex`, `mise`, or a built
  `elixir/bin/symphony` wrapper.
- Do not claim Symphony can generate or install a launchd plist.
- Keep `workflow_path` explicit per repo; do not silently derive it.
- Prefer `local_env_path` for repo-specific runtime variables and use
  `repos[].env` only for explicit per-repo overrides.
- Treat missing prerequisites, an unreadable `config.json`, or a manager boot
  failure as blockers, not warnings.
- If the user asks for a ready-to-paste config, generate JSON that matches the
  manager schema documented in `elixir/README.md` and validated by
  `elixir/lib/symphony_elixir/manager_config.ex`.
