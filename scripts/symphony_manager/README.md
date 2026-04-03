# Symphony Manager

This utility manages multiple Symphony instances on a single macOS host.

It creates and reads a per-user config at `~/.config/symphony/config.json`, verifies host
prerequisites before startup, launches one Symphony process per configured repo, and watches the
loopback observability API to restart stuck processes.

## Commands

Run from the repository root:

```bash
python3 -m scripts.symphony_manager init
python3 -m scripts.symphony_manager check
python3 -m scripts.symphony_manager plist
python3 -m scripts.symphony_manager run
```

Or combine setup steps:

```bash
python3 -m scripts.symphony_manager setup
```

Useful options:

- `--config /path/to/config.json` to use a non-default config location
- `init --interactive` to prompt for the first repo entry
- `check --require-launchd` to verify the host is ready for launchd usage
- `plist --output ~/Library/LaunchAgents/dev.symphony.manager.plist` to choose the output path

## Config

The default scaffold looks like this:

```json
{
  "version": 1,
  "symphony_repo": "/Users/example/code/symphony",
  "symphony_bin": "/Users/example/code/symphony/elixir/bin/symphony",
  "manager": {
    "check_interval_seconds": 30,
    "http_timeout_seconds": 5,
    "failure_threshold": 3,
    "restart_backoff_seconds": [5, 15, 30, 60, 300],
    "port_range": {"start": 43100, "end": 48999}
  },
  "notifications": {
    "enabled": false,
    "webhook_url": "",
    "cooldown_seconds": 300,
    "events": ["approval_required", "turn_input_required", "retrying_issue", "blocked_repo"]
  },
  "repos": [
    {
      "id": "example-repo",
      "name": "Example Repo",
      "repo_path": "/Users/example/code/example-repo",
      "workflow_path": "/Users/example/code/symphony/workflows/example-repo/WORKFLOW.md",
      "logs_root": "/Users/example/.config/symphony/logs/example-repo",
      "local_env_path": "/Users/example/code/example-repo/local.env",
      "port": null,
      "enabled": true,
      "env": {}
    }
  ]
}
```

Notes:

- `workflow_path` is explicit for each repo.
- If `port` is missing, the manager picks a free loopback port in `43100-48999` and writes it back
  to `config.json`.
- `local_env_path` points at a simple `KEY=VALUE` file that the manager loads before launch.
- `env` lets you set per-repo environment variables inline in `config.json`; these override values
  loaded from `local_env_path`.
- `notifications` is optional and lets the manager POST structured JSON events to a webhook when a
  repo reports pending approval, repeated retry loops, or a repo becomes manager-blocked.
- A typical `local.env` for workflow-driven repo settings might look like:

```dotenv
LINEAR_API_KEY=lin_api_xxx
SYMPHONY_PROJECT_SLUG=leftoff-app-9d940c1364f1
SYMPHONY_WORKSPACE_ROOT=/Users/example/code/symphony-workspaces/leftoff
SOURCE_REPO_URL=git@github.com:example/leftoff.git
SOURCE_REPO_BASE_BRANCH=main
```

- Precedence is: launchd/user shell environment, then `local_env_path`, then `repos[].env`.
- `check` validates both the env file path and any workflow-required variables resolved through it.

## Notifications

When `notifications.enabled` is true, the manager polls each repo's observability API and emits
JSON webhooks for configured event types:

- `approval_required`
- `turn_input_required`
- `retrying_issue`
- `blocked_repo`

Events are deduplicated for `cooldown_seconds` using the repo, issue, and request identity so a
stuck approval request does not spam the webhook target every poll interval.

The webhook payload shape is:

```json
{
  "source": "symphony_manager",
  "event": "approval_required",
  "sent_at": "2026-04-03T12:00:00+00:00",
  "repo": {
    "id": "leftoff",
    "name": "LeftOff",
    "path": "/Users/example/code/leftoff",
    "port": 43123
  },
  "issue": {
    "id": "issue-123",
    "identifier": "MT-123",
    "state": "In Progress"
  },
  "details": {
    "type": "approval_required",
    "summary": "command approval requested (git push)",
    "requested_at": "2026-04-03T11:59:00Z"
  }
}
```

Use this with Slack, ntfy, Pushover, or a lightweight relay service.

## Prerequisite Checks

The checker validates:

- `python3`
- `codex`
- the Symphony checkout and launcher paths
- whether `symphony.escript` already exists or can be built with the available toolchain
- each configured repo path
- each configured workflow path
- workflow-driven environment requirements such as `LINEAR_API_KEY`
- macOS `launchd` availability when requested

The check command prints a pass/fail report with fixes for every failure and exits non-zero when the
host is not ready.

## launchd

`plist` writes a LaunchAgent file but does not install it. Load it manually when you are ready:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.symphony.manager.plist
launchctl kickstart -k gui/$(id -u)/dev.symphony.manager
```

Unload it with:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.symphony.manager.plist
```
