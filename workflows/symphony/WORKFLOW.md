---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: $SYMPHONY_PROJECT_SLUG
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    if [ -z "$SOURCE_REPO_URL" ]; then
      echo "SOURCE_REPO_URL is required for git-backed Symphony workspaces." >&2
      exit 1
    fi
    git clone "$SOURCE_REPO_URL" .
    if [ -n "$SOURCE_REPO_BASE_BRANCH" ]; then
      git fetch origin "$SOURCE_REPO_BASE_BRANCH"
      git checkout "$SOURCE_REPO_BASE_BRANCH"
      git reset --hard "origin/$SOURCE_REPO_BASE_BRANCH"
    fi
    mkdir -p .cache/mix .cache/hex
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - /Users/daniel/.config/symphony/symphony
    readOnlyAccess:
      type: fullAccess
    networkAccess: true
---

You are working on the Symphony codebase itself.

Repository context:

- The Elixir app lives under `elixir/`.
- Manager and host utilities live under `scripts/symphony_manager/`.
- Shared workflows live under `workflows/`.

Operating rules:

1. Work only inside the provided workspace copy.
2. Keep Mix and Hex caches inside the workspace when possible. Prefer:
   - `MIX_HOME=$PWD/.cache/mix`
   - `HEX_HOME=$PWD/.cache/hex`
3. Do not end the turn while the issue remains active unless blocked by missing
   required auth, secrets, or external services.
4. Start by reproducing or validating the current behavior before changing code.
5. Run targeted validation for touched areas, and run broader Elixir tests when
   the change affects orchestration, API, or manager behavior.
