---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: $SYMPHONY_PROJECT_SLUG
  active_states:
    - Planning
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
    if command -v pnpm >/dev/null 2>&1; then
      pnpm install --frozen-lockfile || pnpm install
    fi
  timeout_ms: 120000
agent:
  max_concurrent_agents: 2
  max_turns: 12
codex:
  command: codex app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
server:
  host: 127.0.0.1
  port: 4100
---

You are working on LeftOff, a Chrome extension MVP that saves and restores a
reader's position on a page.

Repository context:

- Runtime entry points are `src/background.ts`, `src/contentScript.ts`, and
  `popup/popup.ts`.
- Shared helpers live under `src/lib/`.
- Validation is centered on `pnpm check` and focused regression testing for the
  behavior being changed.

Operating rules:

1. Work only inside the provided workspace copy.
2. Start every run by reading the latest issue description and all recent human
   comments or review notes, then incorporate that feedback into the current
   plan before taking action.
3. Treat the newest human comments as the highest-priority clarification of
   intent unless they directly conflict with an explicit non-negotiable
   requirement in the issue.
4. In `Rework` or after any human-review feedback, summarize the requested
   changes in your working notes before making code changes.
5. Start by reproducing the issue or confirming the requested behavior before
   making edits.
6. Favor small, reviewable changes that match existing TypeScript, Vite, and
   Chrome extension patterns already in this repo.
7. Run targeted validation after meaningful changes, and run `pnpm check`
   before considering work complete unless a missing dependency or environment
   issue makes that impossible.
8. Treat browser-extension behavior as high risk around:
   - selection capture and restore logic in `src/contentScript.ts`
   - storage and coordination flow in `src/background.ts`
   - popup actions and saved-item rendering in `popup/`
9. Do not add compatibility hacks, TODO comments, or broad refactors unless the
   task explicitly requires them.
10. If blocked by missing credentials, unavailable tools, or external services,
    stop with a concise blocker summary and the exact missing prerequisite.
11. For implementation work, use a git branch dedicated to the issue and keep
    GitHub pull request state in sync with the current task state.
12. Use the `gh` CLI for GitHub pull request operations instead of web flows.

Completion bar:

- The requested change is implemented.
- Relevant validation has been run and reported.
- Any user-visible behavior change is described clearly in the final summary.

State-specific behavior:

- `Planning`: do not implement yet. Refine the ticket into an execution-ready
  plan by clarifying scope, tightening acceptance criteria, listing assumptions,
  calling out risks, and proposing a concrete task breakdown. If tracker note
  tooling is available, update the task notes with the improved plan, then
  stop. Never move the issue out of `Planning` automatically, and never start
  implementation from `Planning`.
  A human must review the proposed plan, edit the task if needed, and manually
  move it to `Todo` when it is ready for implementation.
- `Todo`: implementation-ready and queued for execution.
- `In Progress`: active implementation and validation.
- `Human Review`: hard pause for human review. Do not continue implementation,
  do not make new code changes, and do not change the issue state
  automatically. Wait for a human to review the output and then manually move
  the issue to `Rework`, `Merging`, `In Progress`, or another chosen state.
- `Rework`: reviewer requested changes; continue from existing context.
- `Merging`: approved for landing. Use the existing pull request for the issue,
  perform final sync and validation, then merge with `gh`.

Required routing:

1. If the current state is `Planning`, only do planning work.
2. In `Planning`, produce or update a concise plan with:
   - problem statement
   - assumptions and open questions
   - acceptance criteria
   - validation approach
   - proposed implementation breakdown
3. After updating the plan, end the run without changing code, branch, or issue
   state.
4. If the current state is `Human Review`, stop active work and wait. Do not
   interpret lack of feedback as approval, and do not resume until a human
   manually moves the issue to a new state.
5. Only begin or resume implementation after a human has manually moved the
   issue to `Todo`, `In Progress`, or `Rework`.
6. When an issue enters `Rework`, begin by reviewing all new human comments
   added since the last implementation pass, update the plan to reflect each
   actionable item, and only then resume implementation.
7. If the current state is `Merging`, do only landing work:
   - inspect the existing pull request
   - sync with the base branch
   - rerun validation
   - merge with `gh pr merge`
   - move the issue to `Done` only after merge succeeds

Git and GitHub workflow:

1. For `Todo`, `In Progress`, and `Rework`, ensure the workspace is on a branch
   named `codex/<issue-identifier-lowercase>-<short-slug>`.
2. If the branch does not exist yet, create it from the configured base branch.
3. Before opening or updating a PR, run `pnpm check` unless blocked by a known
   environment issue outside the code change itself.
4. Commit only the intended changes with clear commit messages.
5. Push with `git push -u origin HEAD`.
6. Create or update the PR with `gh pr create` or `gh pr edit`.
7. Use a concise PR body with these sections:
   - `## Summary`
   - `## Validation`
   - `## Risks`
8. When work is ready for review, ensure an open PR exists and includes the
   latest changes before moving the issue to `Human Review`.
9. In `Rework`, reuse the same branch and PR when possible rather than creating
   a new one.
10. In `Merging`, treat the human move into that state as approval to land.
11. Use `gh pr merge --merge --delete-branch` unless the PR or repo settings
    clearly require a different merge mode.
