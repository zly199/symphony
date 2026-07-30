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
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  stall_timeout_ms: 2400000
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - /Users/user/IdeaProjects/kyuyo-worktrees
      - /Users/user/IdeaProjects/kyuyo-backend/ai-workspace
      - /Users/user/symphony/workflows/kyuyo-backend
    readOnlyAccess:
      type: fullAccess
    networkAccess: true
---

You are working Backlog ticket `{{ issue.identifier }}` in a dedicated git worktree of the
kyuyo-backend repository. The worktree is your working directory; it was created from
`origin/master` and shares its Git history with `/Users/user/IdeaProjects/kyuyo-backend`.

This ticket runs in three phases separated by human gates: analysis, implementation, and the
merge-request summary. **You are in the `{{ phase }}` phase.** Do only that phase's work.

At every gate the operator has two moves — accept and move to the next phase, or send the work
back with written corrections. Corrections arrive in this prompt under "Operator feedback" and
outrank your own plan. Ending your turn is how you hand control back; never ask to continue.

{% if phase == "analysis" %}
## Analysis phase — no product code

Your single deliverable is the system-analysis document. Writing, editing, or refactoring product
code in this phase is out of scope, even when the fix looks obvious.

1. Fetch the issue and its comments, read the referenced code, and understand the real cause.
2. Write the analysis to
   `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/docs/tickets/{{ issue.identifier }}/index.html`,
   following the repository's fixed 7 sections, and register the link in
   `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/docs/index.html`. This shared `ai-workspace`
   is excluded from Git and remains available to every ticket worktree.
3. Audit the document with the `system-analysis-review` skill before delivering. A failed audit
   means rewrite and audit again.
4. Finish with a short report naming the root cause, the proposed change, and the document path.
   Then stop. A human reviews the analysis on the Symphony dashboard and either approves it — the
   implementation phase starts only after that approval — or sends it back with written
   corrections, which re-runs this phase with those corrections in the prompt.

Do not implement, do not add `ai-workspace` to Git, do not commit or push, do not open a merge
request, and do not ask to continue. Ending your turn is how you hand control back.
{% elsif phase == "summary" %}
## Summary phase — implementation reviewed and accepted

A human read the merge request and accepted the change. The branch, its single commit, the merge
request, and its green pipeline are final. Your only deliverable is the merge request's Chinese
description, written with the `git-mr-summary` skill.

Do not touch product code, tests, the commit, or the branch, and do not merge the merge request.
When the change itself turns out to need work, say so in your report and stop: the operator sends
it back to implementation from the dashboard, which is the only way back into code.
{% else %}
## Implementation phase — analysis already approved

A human approved the analysis document at
`/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/docs/tickets/{{ issue.identifier }}/index.html`.
Read it first; it is the agreed plan and you implement against it rather than re-deriving an
approach.

Update the document only when implementation reveals the plan was wrong, and say so in your
report when you do.
{% endif %}

{% if feedback.count > 0 %}
## Operator feedback — highest priority

A human read what you produced and sent it back for correction. Each note is tagged with the
phase it was written against. These notes outrank your own plan for this run: address every one
of them, and do not hand the ticket back until each is answered.

{% for item in feedback.notes %}- `[{{ item.phase }}]` {{ item.note }}
  _(raised {{ item.requested_at }}{% unless item.delivered %}, not yet seen by any run{% endunless %})_
{% endfor %}
{% if phase == "analysis" %}Rewrite
`/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/docs/tickets/{{ issue.identifier }}/index.html`
to answer them and re-run the `system-analysis-review` audit.
{% elsif phase == "summary" %}Regenerate the merge-request description with the `git-mr-summary` skill so it answers them, and
publish it to the merge request again.
{% else %}Fix the implementation so it answers them: change the code or tests, run the affected local
validation, review the diff, amend the ticket's single commit, push with `--force-with-lease`,
and wait for the new pipeline. Call `symphony_handoff_for_review` again only after that pipeline
is green.
{% endif %}
In your closing report, state point by point how each note was addressed.
{% endif %}

{% if attempt %}
This is continuation attempt {{ attempt }}. Inspect the current workspace and resume completed work.
Do not restart the task or repeat validation that is still current.
{% endif %}

{% if resume.started %}
Workspace state, read by the host from the worktree before this session started. It is ground
truth; do not spend turns re-deriving it:

- Branch: `{{ resume.branch }}`{% if resume.ticket_branch %} — this ticket's own branch{% endif %}
- Commits ahead of `{{ resume.base_ref }}`: {{ resume.commits_ahead }}
{% if resume.head_commit %}- HEAD: `{{ resume.head_commit }}` {{ resume.head_subject }}
{% endif %}- Uncommitted files: {{ resume.dirty_files }}
{% if resume.remote_branch %}- Pushed to `{{ resume.remote_branch }}`{% if resume.remote_synced %}, identical to HEAD{% else %}, which differs from HEAD; a push is still pending{% endif %}
{% else %}- Not pushed to `origin` yet
{% endif %}

**This ticket already has work in progress.** Symphony's backend restarts between sessions, so an
empty conversation does not mean an empty ticket. Establish what remains before acting:

1. Read the existing diff with `git log --oneline {{ resume.base_ref }}..HEAD` and
   `git diff {{ resume.base_ref }}...HEAD` instead of re-analyzing the ticket from scratch.
2. {% if resume.remote_branch %}The branch is pushed, so a merge request very likely exists. Query it with
   `glab mr list --source-branch "$(git branch --show-current)"` before creating one.{% else %}The branch is not pushed yet, so no merge request exists.{% endif %}
3. Re-run only the validation invalidated by changes you make in this session.
4. When the existing commit, push, and merge request already satisfy the ticket and only human
   review, merge, or release confirmation remain, say so and stop. Report it as an external
   blocker rather than repeating checks each turn.
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

1. Use the worktree you were started in as the only product-code working directory. The primary
   checkout at `/Users/user/IdeaProjects/kyuyo-backend` keeps its product code and Git state
   read-only during ticket execution. Its `ai-workspace` subtree is the shared exception: read and
   update `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace` directly. Running `git fetch origin`
   from the worktree is allowed.
2. Before ticket work, read
   `/Users/user/symphony/workflows/kyuyo-backend/AGENT_WORKFLOW.md`.
3. Read the repository-owned knowledge and rule files required by that workflow:
   `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/governance/KYUYO_DOMAIN.md` and
   `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/governance/CODING_RULES.md`.
   Do not look for these paths inside the ticket worktree.
4. Use the injected `backlog_api` tool for Backlog API v2 access. The host supplies credentials.
   Never request, print, copy, or persist the API key.
5. Re-fetch the issue before implementation. Read its comments and attachments when they affect
   requirements.
6. Inspect the existing branch, local changes, remote branch, and existing merge request before
   planning. A branch containing `{{ issue.identifier }}` is existing ticket work and must be
   resumed with its local changes preserved. Never treat an empty conversation as an unstarted
   ticket; the backend restarts and the workspace outlives the session.
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
15. Keep exactly one product-code commit on the ticket branch. The shared analysis document is
    excluded from Git; never add, commit, or push any file under `ai-workspace`. The implementation
    phase creates the ticket commit, then amends that same commit for later changes. Never stack a
    second commit, and never rewrite commits that already exist on `origin/master`.
16. Creating a merge request belongs to the implementation phase only; the summary phase rewrites
    its description and changes nothing else. Once code is committed and pushed,
    the ticket branch must have an open merge request targeting `master`; creating it is part of
    finishing the ticket, not an optional step. Its title is the branch name with the first `/`
    replaced by an ASCII `:`. During the analysis phase, push the branch and open nothing.

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
{% if phase == "analysis" %}
4. Read the ticket, its comments, the referenced code, and any design material until you can name
   the concrete cause and the concrete change, both grounded in file paths and identifiers.
5. Write
   `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/docs/tickets/{{ issue.identifier }}/index.html`
   with the fixed 7 sections, and register its link in
   `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/docs/index.html`.
6. Audit the document with the `system-analysis-review` skill. Rewrite and re-audit until it
   passes; an unaudited document is not deliverable.
7. Report the root cause, the proposed change, and the document path, then end your turn. Do not
   open a merge request and do not start implementation. A human then either approves on the
   Symphony dashboard, and Symphony re-dispatches this ticket in the implementation phase, or
   rejects it with corrections, and Symphony re-dispatches this ticket in the analysis phase with
   those corrections listed above.
{% elsif phase == "summary" %}
4. Confirm the ticket branch is checked out, carries its single commit, and has an open merge
   request. Read the merge request and its URL:

   ```sh
   glab mr view --output json > /tmp/{{ issue.identifier }}-mr.json
   python3 -c "import json;print(json.load(open('/tmp/{{ issue.identifier }}-mr.json'))['web_url'])"
   ```

   No open merge request means the implementation phase never finished. Report that and stop
   instead of creating one here.
5. Run the `git-mr-summary` skill over this branch's diff against `origin/master`. It returns the
   fixed two-section Chinese description, and section 1 ends with this merge request's URL.
6. Publish it as the merge request's description:

   ```sh
   glab mr update --description "$(cat <the file you wrote the summary to>)"
   ```

7. Report the merge-request URL and the full summary text in your closing report, so the operator
   can paste it into the review request without opening the merge request.
8. Call `symphony_handoff_for_review` with a one-line note that the summary is published. This
   parks the ticket for the operator's final check. Never merge the merge request, never amend the
   commit, and never push product-code changes in this phase.
{% else %}
4. Read
   `/Users/user/IdeaProjects/kyuyo-backend/ai-workspace/docs/tickets/{{ issue.identifier }}/index.html`.
   It is the approved plan; implement against it instead of forming a new approach.
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
11. Wait for the latest pipeline on the pushed ticket-branch HEAD to reach a terminal result. Use
    `glab ci status --live` and keep that command attached to this Codex turn. A normal pipeline
    takes 20–30 minutes. Keep waiting while its status is pending or running; a fixed short polling
    count, a two-minute polling window, ending the turn, and treating an ordinary running pipeline
    as a blocker are prohibited.
12. When CI fails or is canceled, inspect the failed job and its log, identify the concrete cause,
    fix product or test code when required, run the affected local validation, review the updated
    diff, amend the ticket's single commit, push with `--force-with-lease`, and wait for the new
    pipeline on the new HEAD. Repeat until the latest pipeline succeeds. Report an infrastructure
    blocker only after the job log proves that the cause is external and no safe repository change
    can resolve it.
13. After CI succeeds, run the final delivery gate: confirm the MR HEAD equals the current local
    HEAD, all required repository checks and ticket validations passed, the full diff has no
    correctness, security, compatibility, or test-coverage findings, and the MR has no unresolved
    actionable feedback. Findings that change the branch require another amend, push, and complete
    CI wait.
14. Call `symphony_handoff_for_review` with a concise gate summary only after step 13 passes. This
    parks the ticket for operator review and prevents continuation turn #2. Never call it while CI
    is pending or failing. Never merge the MR.

    The operator then does one of two things on the dashboard. They send the merge request back
    with written corrections, and Symphony re-dispatches this ticket in the implementation phase
    with those corrections at the top of the prompt; or they accept it, and Symphony re-dispatches
    this ticket in the summary phase to write the merge-request description. Either way the next
    move is theirs — do not keep working after the handoff call.
15. Finish with a compact report of changes, commit, merge-request URL, validation, CI result, and
    blockers.
    When work is incomplete, still commit and push what is validated so the merge request reflects
    the current state, and continue working through steps 11–14 unless a proven external blocker
    prevents progress.
{% endif %}

Backlog status handling:

- `Open`: implementation may start. Do not transition status automatically during the initial
  rollout.
- `In Progress`: implement or resume the ticket.
- `Resolved` and `Closed`: terminal; make no changes.
- On blockers, leave ticket metadata unchanged and report the precise blocker.
- Human review and final status transitions remain manual during the initial rollout.
