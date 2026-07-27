---
tracker:
  kind: backlog
  provider:
    base_url: https://nisshin30.backlog.com
    project_key: KYUYO_NEW
    api_key: $BACKLOG_API_KEY
    assignee_id: 449278
  active_states:
    - In Progress
  terminal_states:
    - Resolved
    - Closed
polling:
  interval_ms: 10000
server:
  host: 127.0.0.1
  port: 4000
observability:
  dashboard_enabled: false
workspace:
  mode: existing
  root: /Users/user/IdeaProjects/kyuyo-backend
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - /Users/user/IdeaProjects/kyuyo-backend
      - /Users/user/symphony/workflows/kyuyo-backend
    readOnlyAccess:
      type: fullAccess
    networkAccess: true
---

You are implementing Backlog ticket `{{ issue.identifier }}` in the existing kyuyo-backend repository
at `/Users/user/IdeaProjects/kyuyo-backend`.

{% if attempt %}
This is continuation attempt {{ attempt }}. Inspect the current workspace and resume completed work.
Do not restart the task or repeat validation that is still current.
{% endif %}

Issue:

- Key: {{ issue.identifier }}
- Title: {{ issue.title }}
- Status: {{ issue.state }}
- Categories: {{ issue.labels }}
- URL: {{ issue.url }}

Description:

{% if issue.description %}
{{ issue.description }}
{% else %}
No description was provided.
{% endif %}

Operating rules:

1. Use `/Users/user/IdeaProjects/kyuyo-backend` as the only product-code working directory.
2. Before ticket work, read
   `/Users/user/symphony/workflows/kyuyo-backend/AGENT_WORKFLOW.md`.
3. Read the repository-owned knowledge and rule files required by that workflow:
   `ai-workspace/governance/KYUYO_DOMAIN.md` and
   `ai-workspace/governance/CODING_RULES.md`.
4. Use the injected `backlog_api` tool for Backlog API v2 access. The host supplies credentials.
   Never request, print, copy, or persist the API key.
5. Re-fetch the issue before implementation. Read its comments and attachments when they affect
   requirements.
6. Inspect the existing branch, local changes, remote branch, and existing merge request before
   planning. A branch containing `{{ issue.identifier }}` is existing ticket work and must be
   resumed without replacement. When the current branch belongs to a different completed ticket
   and the repository is clean, return to the repository's normal integration branch, update it,
   and create the new ticket branch from that baseline.
7. Reproduce or establish a concrete code-based baseline before editing.
8. Keep changes scoped to the ticket. Preserve unrelated work.
9. Run tests and static checks proportional to the affected modules. Record exact results.
10. Do not claim completion while required validation is failing.
11. Do not change Backlog status, categories, assignee, or comments unless the ticket explicitly
    requests it or the workflow below authorizes it.

Execution workflow:

1. Fetch `/issues/{{ issue.identifier }}` and
   `/issues/{{ issue.identifier }}/comments` with `backlog_api`.
2. Reuse the current ticket branch when its name contains `{{ issue.identifier }}`. When a branch
   must be created, follow the kyuyo branch rule `<scope>/<Backlog title>` and preserve the complete
   title where Git permits it.
3. Build a concise implementation and validation plan from the ticket and actual code.
4. Implement the smallest complete change.
5. Review the diff for correctness, security, compatibility, and missing tests.
6. Run the relevant Maven/module tests and any repository-required checks.
7. Commit completed work with a message containing `{{ issue.identifier }}`.
8. Push the branch when authentication is available. Do not force-push.
9. If `glab` is authenticated and no merge request exists, open one targeting the repository's
   normal integration branch. Never merge it automatically.
10. Finish with a compact report of changes, commit, merge-request URL, validation, and blockers.

Backlog status handling:

- `Open`: implementation may start. Do not transition status automatically during the initial
  rollout.
- `In Progress`: implement or resume the ticket.
- `Resolved` and `Closed`: terminal; make no changes.
- On blockers, leave ticket metadata unchanged and report the precise blocker.
- Human review and final status transitions remain manual during the initial rollout.
