---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: $SYMPHONY_PROJECT_SLUG
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 10000
  jitter_ms: 5000
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
  timeout_ms: 120000
agent:
  max_concurrent_agents: 2
  max_turns: 12
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on a Linear issue for the current repository.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Operating rules:

1. Work only inside the provided workspace copy.
2. Reproduce the issue or confirm the requested behavior before making edits.
3. Keep changes narrowly scoped and consistent with the target repo's patterns.
4. Run targeted validation after meaningful changes and report what you verified.
5. Stop only for true blockers such as missing credentials or unavailable external services.
