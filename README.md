# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## What's Different In This Fork

This fork currently differs from upstream `openai/symphony` in a few practical ways:

- workflow files are expected under `workflows/<repo>/WORKFLOW.md` inside the Symphony checkout
  instead of living in each target repo root
- the Elixir launcher builds `bin/symphony.escript` and uses a small `bin/symphony` wrapper script
- Codex launch commands can be selected by issue state via `codex.command_by_state`
- the Elixir docs have been updated to reflect the centralized workflow layout and required CLI
  acknowledgement flag

If you are comparing behavior with upstream, start with
[elixir/README.md](elixir/README.md) and the checked-in workflow example under
[workflows/elixir/WORKFLOW.md](workflows/elixir/WORKFLOW.md).

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
and run the Elixir-based Symphony implementation. The current setup uses centralized workflow
definitions under `workflows/<repo>/WORKFLOW.md` inside the Symphony checkout. You can also ask
your favorite coding agent to help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
