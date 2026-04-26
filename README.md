# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

## Multi-Repo Manager

The supported multi-repo manager lives in the Elixir runtime behind
[`elixir/bin/symphony manager`](elixir/README.md#multi-repo-manager).

It provides:

- a per-user config at `~/.config/symphony/config.json`
- a long-running supervisor that assigns stable loopback ports, starts one Symphony runtime per
  enabled repo, and restarts unhealthy repo processes using `/api/v1/state`
- a manager-aware dashboard and JSON API for repo status, issue activity, and restart control

Normal operator flow:

1. Create `~/.config/symphony/config.json` plus one `~/.config/symphony/workflows/<repo>/WORKFLOW.md`
   per managed repo.
2. Start `elixir/bin/symphony manager --i-understand-that-this-will-be-running-without-the-usual-guardrails`
   in the foreground first, adding `--port 4000` when you want the dashboard and JSON API.
3. Let the manager assign missing repo ports, launch enabled repos, reload config changes, and
   restart unhealthy repo runtimes with backoff.
4. Use the dashboard or manager API to switch between repos, inspect repo-scoped issue activity,
   restart a selected repo, or queue a manager restart.
5. If the machine still uses the removed Python-manager LaunchAgent flow, migrate with the
   repo-local `migrate-symphony-manager` skill instead of reviving the old CLI.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## What's Different In This Fork

This fork currently differs from upstream `openai/symphony` in a few practical ways:

- active workflow files are expected under
  `~/.config/symphony/workflows/<repo>/WORKFLOW.md`
- the repo keeps a single public sample workflow at `workflows/sample/WORKFLOW.md`
- the Elixir launcher builds `bin/symphony.escript` and uses a small `bin/symphony` wrapper script
- Codex launch commands can be selected by issue state via `codex.command_by_state`
- the Elixir docs have been updated to reflect the private workflow layout and required CLI
  acknowledgement flag

If you are comparing behavior with upstream, start with
[elixir/README.md](elixir/README.md) and the checked-in sample workflow under
[workflows/sample/WORKFLOW.md](workflows/sample/WORKFLOW.md).

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. The current setup uses explicit workflow paths,
with live workflow files typically stored under
`~/.config/symphony/workflows/<repo>/WORKFLOW.md`. You can also ask
your favorite coding agent to help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
