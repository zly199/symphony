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
  mode: worktree
  root: /Users/user/IdeaProjects/kyuyo-worktrees
  repository: /Users/user/IdeaProjects/kyuyo-backend
  base_ref: origin/master
agent:
  max_concurrent_agents: 2
  max_turns: 60
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - /Users/user/IdeaProjects/kyuyo-worktrees
      - /Users/user/symphony/workflows/kyuyo-backend
    readOnlyAccess:
      type: fullAccess
    networkAccess: true
---

You are implementing Backlog ticket `{{ issue.identifier }}` in a dedicated git worktree of the
kyuyo-backend repository. The worktree is your working directory; it was created from
`origin/master` and shares its Git history with `/Users/user/IdeaProjects/kyuyo-backend`.

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

1. Use the worktree you were started in as the only product-code working directory. Never edit,
   switch branches in, or run destructive Git commands against
   `/Users/user/IdeaProjects/kyuyo-backend`; the user works there. Reading it and running
   `git fetch origin` from the worktree are allowed.
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
   resumed with its local changes preserved.
7. For a new ticket branch, run the repository branch-preparation step immediately after reading
   the issue and before code or documentation analysis. It fetches `origin` and creates the ticket
   branch directly from `origin/master` inside the worktree. It never checks out `master`, so the
   user's own checkout keeps its branch.
8. Use the ticket's Backlog issue type and every category as branch nature inputs. The scope
   precedence is `bug -> fix`, `ci` or documentation -> `doc`, and every other nature -> `feat`.
   Branch names use `<scope>/<issue identifier>-<complete Backlog title>`.
9. Sanitize the branch component by changing whitespace and Git-invalid ref characters to `-`,
   collapsing repeated separators, preserving valid Unicode text, avoiding a trailing `.lock`,
   and truncating safely when the UTF-8 component exceeds the filesystem-safe limit.
10. Reproduce or establish a concrete code-based baseline before editing.
11. Keep changes scoped to the ticket. Preserve unrelated work.
12. Run tests and static checks proportional to the affected modules. Record exact results.
13. Do not claim completion while required validation is failing.
14. Do not change Backlog status, categories, assignee, or comments unless the ticket explicitly
    requests it or the workflow below authorizes it.
15. Keep exactly one commit on the ticket branch. The first completed change creates it; every
    later change on the same ticket amends it with `git commit --amend`. Never stack a second
    commit, and never rewrite commits that already exist on `origin/master`.
16. A committed and pushed ticket branch must always have an open merge request targeting
    `master`. Creating that merge request is part of finishing the ticket, not an optional step.
    Its title is the branch name with the first `/` replaced by an ASCII `:`.

Execution workflow:

1. Fetch `/issues/{{ issue.identifier }}` and
   `/issues/{{ issue.identifier }}/comments` with `backlog_api`.
2. Reuse the current branch when its name contains `{{ issue.identifier }}`. For a new branch, run:

   ```sh
   python3 /Users/user/symphony/workflows/kyuyo-backend/scripts/prepare_ticket_branch.py \
     --repo "$(pwd)" \
     --ticket '{{ issue.identifier }}' \
     --title '{{ issue.title }}' \
     --nature '<Backlog issueType.name>' \
     --nature '<each Backlog category name>'
   ```

   Pass one `--nature` argument for the issue type and one for each category. Quote every value.
   Stop before implementation when the script reports a dirty unrelated branch, a missing
   `origin/master`, or another Git failure.
3. Confirm the resulting branch contains `{{ issue.identifier }}` and its HEAD equals
   `origin/master` when the script reports `created:`. Example:
   `feat/KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー`.
4. Build a concise implementation and validation plan from the ticket and actual code.
5. Implement the smallest complete change.
6. Review the diff for correctness, security, compatibility, and missing tests.
7. Run the relevant Maven/module tests and any repository-required checks.
8. Commit the completed work with a message containing `{{ issue.identifier }}`. When the ticket
   branch already carries its own commit, amend that commit instead of adding a new one:

   ```sh
   git add -A
   git commit --amend --no-edit   # use -m only when the message itself must change
   ```

   Check with `git log --oneline origin/master..HEAD` first: zero commits means create, one commit
   means amend, more than one means squash back to one before pushing.
9. Push the branch. Use `git push -u origin HEAD` for the first push and
   `git push --force-with-lease origin HEAD` after an amend. `--force-with-lease` is allowed only
   on the ticket branch; never use plain `--force`, and never push to `master`.
10. Open the merge request targeting `master` as soon as the branch is pushed, before reporting the
    ticket as finished:

    ```sh
    branch="$(git branch --show-current)"
    title="$(printf '%s' "$branch" | sed 's|/|:|')"
    glab mr create --source-branch "$branch" --target-branch master \
      --title "$title" --description '<summary>' --yes
    ```

    The title is the branch name with its first `/` replaced by an ASCII `:`, for example branch
    `fix/KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー` becomes title
    `fix:KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー`. Nothing else is added, removed,
    or translated.

    Reuse the existing merge request when one is already open for the branch; an amended push
    updates it automatically. Never merge it. When `glab` is not authenticated or the create call
    fails, report the exact failure as a blocker instead of ending the ticket silently.
11. Finish with a compact report of changes, commit, merge-request URL, validation, and blockers.
    When work is incomplete, still commit and push what is validated so the merge request reflects
    the current state, and name what is left.

Backlog status handling:

- `Open`: implementation may start. Do not transition status automatically during the initial
  rollout.
- `In Progress`: implement or resume the ticket.
- `Resolved` and `Closed`: terminal; make no changes.
- On blockers, leave ticket metadata unchanged and report the precise blocker.
- Human review and final status transitions remain manual during the initial rollout.
