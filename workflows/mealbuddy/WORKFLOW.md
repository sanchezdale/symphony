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
    mkdir -p .cache .cache/go .cache/npm .cache/pip .cache/uv .venv
    if [ -d frontend ] && command -v npm >/dev/null 2>&1; then
      cd frontend && npm install && cd ..
    fi
    if [ -d workers/recipe-parser ] && command -v uv >/dev/null 2>&1; then
      cd workers/recipe-parser && uv sync && cd ../..
    fi
  timeout_ms: 180000
agent:
  max_concurrent_agents: 2
  max_turns: 14
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on MealBuddy, a mixed-stack product with a Go backend, a Svelte
frontend, and Python Cloudflare worker experiments.

Repository context:

- `backend/` is the Go service.
- `frontend/` is the Svelte/Vite application.
- `workers/` contains Python worker experiments and deployment code.

Operating rules:

1. Work only inside the provided workspace copy.
2. Keep all language caches and temp state inside the workspace. Prefer:
   - `GOMODCACHE=$PWD/.cache/go/pkg/mod`
   - `GOCACHE=$PWD/.cache/go/build`
   - `GOPATH=$PWD/.cache/go`
   - `npm_config_cache=$PWD/.cache/npm`
   - `PIP_CACHE_DIR=$PWD/.cache/pip`
   - `UV_CACHE_DIR=$PWD/.cache/uv`
3. Reproduce the issue first in the relevant subsystem before editing code.
4. Match existing patterns in the touched subsystem instead of introducing a
   cross-stack abstraction.
5. When the issue is scoped to one subsystem, avoid unrelated edits in the
   others.
6. Run the narrowest useful validation first, then the repo-appropriate check
   for the changed area before finishing.
7. Use `gh` for GitHub operations when a pull request is involved.
8. Stop only for true missing auth, secrets, or external services that cannot
   be resolved in-session.

Validation expectations by subsystem:

- Go backend: targeted `go test` for touched packages, then broader backend
  validation when warranted.
- Frontend: `npm run check` or the repo’s equivalent for touched UI changes.
- Workers: dependency sync plus the targeted worker validation for the changed
  flow.
