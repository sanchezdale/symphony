---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: $SYMPHONY_PROJECT_SLUG
  active_states:
    - Todo
    - In Progress
    - Rework
    - Human Review
    - Merging
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 10000
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
    fi
    mkdir -p .cache/deno
  timeout_ms: 120000
agent:
  max_concurrent_agents: 2
  max_turns: 12
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on ms.minutes, which currently includes a Deno scheduler under
`scheduler/`.

Operating rules:

1. Work only inside the provided workspace copy.
2. Keep Deno’s cache in the workspace with `DENO_DIR=$PWD/.cache/deno`.
3. Respect runtime permissions already declared by the repo’s Deno tasks. Do
   not widen them casually.
4. Reproduce the issue first, then edit only the minimum scheduler surface
   needed.
5. Prefer targeted `deno task` or `deno test` validation for the touched flow
   before broader checks.
6. Stop only for true missing secrets, credentials, or external dependencies
   that cannot be resolved inside the workspace.
