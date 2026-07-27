---
name: ticket-hotfix-cherry-pick
description: Find merged kyuyo-backend GitLab merge requests by ticket number, create a hotfix cherry-pick branch from the correct release baseline, preserve the original business semantics across clean or conflicting replays, verify the adapted code and tests, and open a review merge request. Use when the user provides a ticket such as KYUYO_NEW-4318 and asks for a staging hotfix, test hotfix, or customer production hotfix cherry-pick flow instead of merging directly.
---

# Ticket Hotfix Cherry Pick

Automate the ticket-driven hotfix cherry-pick workflow for `kyuyo-backend`.

## Communication Language

- Always respond to the user in Chinese (Simplified).
- Keep ticket IDs, branch names, MR titles, and Japanese business text exactly as found when precision matters.

## Workflow

1. Determine mode:
- `staging hotfix`: require today's remote branch `origin/staging-hotfix-YYYYMMDD`; if it does not exist, run `kyuyo-hotfix-release --mode staging-hotfix` to create today's branch first, then rerun cherry-pick; never fall back to an older staging branch
- `test hotfix`: always use remote branch `origin/production` as the cherry-pick baseline and MR target branch
- `production hotfix`: resolve the latest remote branch `origin/hotfix-YYYYMMDD`; if the required hotfix branch does not exist yet, stop and tell the user to create the deploy branch first; use `customer-cherry-pick/*` as the source branch prefix

2. Find merged original MRs related to the ticket:
- Split the ticket into alphanumeric keywords before searching, for example `KYUYO_NEW-4502` -> `KYUYO`, `NEW`, `4502`
- Search GitLab with multiple terms: lower-case and upper-case space-joined keywords, original ticket text, lower-case and upper-case original ticket text, and the numeric ticket keyword when present
- Include an MR when its title contains all ticket keywords after punctuation, symbols, and letter case are ignored
- Keep the original exact-ticket fallback for source branch or description matches
- Exclude generated cherry-pick MRs such as `staging-cherry-pick/*`, `test-cherry-pick/*`, `production-cherry-pick/*`, and temporary `cherry-pick-*`
- Keep only the original merged MRs that should be replayed

3. Sort MRs by `merged_at` ascending.

4. Build the new branch name by referencing the existing hotfix branch naming style:
- `staging hotfix`: `staging-cherry-pick/{MR名称}` for one MR, or `staging-cherry-pick/{首个MR名称}+2+...+n` for multiple MRs
- `test hotfix`: `test-cherry-pick/{MR名称}` for one MR, or `test-cherry-pick/{首个MR名称}+2+...+n` for multiple MRs
- `production hotfix`: `customer-cherry-pick/{MR名称}` for one MR, or `customer-cherry-pick/{首个MR名称}+2+...+n` for multiple MRs
- Prefer the original source branch fragment over MR title when building the branch suffix, so existing repo naming style is preserved
- Sanitize Git-illegal or repo-unfriendly branch characters such as `:`, `/`, `[`, and `]`, but keep the branch recognizable

5. Create the new branch from the resolved base branch.

6. Prepare the cherry-pick in deterministic order:
- Replay older MRs first
- Replay commits inside each MR in API order
- Treat the prepared branch as a sealed replay artifact: its commits and changed files must come only from the original MRs
- Record the original and replayed `--shortstat` for diagnostics only
- Never use file counts, changed-line counts, or `shortstat` equality as evidence that the replay is correct

7. Resolve conflicts by business semantics:
- Keep the cherry-pick state and inspect the original MR diff, the original commit parent, the target baseline, and every conflicted file
- Resolve the conflict when conflict handling is within the user's requested scope; do not stop only because a conflict exists
- Preserve the original behavior contract even when the target baseline has different classes, methods, test fixtures, or APIs
- Do not require matching file counts or line counts for a conflicted replay
- Continue the remaining commits in the plan after resolving the current commit
- Keep conflict resolution inside the original MR file set and original commit count
- Stop when preserving the behavior would require a new file, an extra commit, or an unrelated change; request a separate follow-up MR
- Stop only when the original business behavior cannot be mapped safely to the target baseline or a material product decision is missing

8. Pass the semantic-equivalence gate before publishing:
- Read the Backlog description and comments plus the original MR description, commits, production diff, and tests
- Write a concise behavior checklist covering input/preconditions, branch conditions, data reads/writes, output fields, exceptions/logging, and test intent
- Map every original business change to the replayed implementation; account for every intentional difference introduced by the target baseline
- Compare tests by asserted business result. A test that only executes code, checks compilation, or avoids an exception does not preserve an original output assertion
- Run the target compilation and ticket-focused tests. Assert real output fields or state changes for the affected business path
- Keep verification read-only with respect to the prepared branch. Never add, amend, reformat, or remove production, test, documentation, configuration, or tooling content during semantic review
- When existing tests do not prove the ticket behavior, report the test gap and stop publication when confidence is insufficient. Create a separate improvement branch only after explicit user authorization
- Treat identical `shortstat` as diagnostic confirmation only; semantic review and verification remain mandatory

9. Publish only after the semantic-equivalence gate passes:
- Run the prepare phase first; it must not push or create an MR, and it writes an integrity seal for the prepared HEAD
- After a manually resolved cherry-pick conflict, complete the planned commits, finish semantic review, then run `--seal-reviewed` once
- Do not run `--seal-reviewed` for a clean prepare; the branch is already sealed and must remain unchanged
- After conflict resolution, semantic review, and target tests, run the reviewed publish phase
- The publish phase must reject extra commits, extra files, base movement, amended commits, and any diff change after the integrity seal
- source branch: the new cherry-pick branch
- target branch: the base branch resolved in step 1

10. After creating each MR successfully, return only the fixed Markdown delivery block for that MR:
- Map `staging-hotfix` to `staging hotfix`
- Map `test-hotfix` to `test cp`
- Map `production-hotfix` to `custom hotfix`
- Escape underscores in the ticket ID for Markdown, for example `KYUYO_NEW-4613` -> `KYUYO\_NEW-4613`
- Put one blank line between multiple delivery blocks and keep them in execution order
- Do not add branch names, commit lists, change statistics, CI status, reminders, or explanatory prose to a successful delivery

Use this exact template without a code fence:

```text
**[<action label>]**
**<escaped ticket ID>**:<MR URL>
```

Example:

```text
**[staging hotfix]**
**KYUYO\_NEW-4613**:https://git.onehr.work/smartcompany/kyuyo/backend/kyuyo-backend/-/merge_requests/4445
```

If an MR is not created because of a conflict, mismatch, missing baseline, duplicate change, or other failure, report the diagnostic result in Chinese and do not emit a success delivery block.

## Script

Use `scripts/run_ticket_hotfix_cherry_pick.py`.

Plan only:

```bash
python3 scripts/run_ticket_hotfix_cherry_pick.py --ticket KYUYO_NEW-4318 --mode staging-hotfix --repo /path/to/kyuyo-backend --plan-only
```

Prepare the local branch without pushing or creating an MR:

```bash
python3 scripts/run_ticket_hotfix_cherry_pick.py --ticket KYUYO_NEW-4318 --mode staging-hotfix --repo /path/to/kyuyo-backend --prepare-only
python3 scripts/run_ticket_hotfix_cherry_pick.py --ticket KYUYO_NEW-4318 --mode test-hotfix --repo /path/to/kyuyo-backend --prepare-only
python3 scripts/run_ticket_hotfix_cherry_pick.py --ticket KYUYO_NEW-4318 --mode production-hotfix --repo /path/to/kyuyo-backend --prepare-only
```

After semantic review and verification, publish the reviewed current branch:

```bash
python3 scripts/run_ticket_hotfix_cherry_pick.py --ticket KYUYO_NEW-4318 --mode staging-hotfix --repo /path/to/kyuyo-backend --publish-reviewed
```

After manually resolving a conflict, seal the reviewed branch before publishing:

```bash
python3 scripts/run_ticket_hotfix_cherry_pick.py --ticket KYUYO_NEW-4318 --mode staging-hotfix --repo /path/to/kyuyo-backend --seal-reviewed
python3 scripts/run_ticket_hotfix_cherry_pick.py --ticket KYUYO_NEW-4318 --mode staging-hotfix --repo /path/to/kyuyo-backend --publish-reviewed
```

Options:
- `--ticket`: ticket number, for example `KYUYO_NEW-4318`
- `--mode`: `staging-hotfix`, `test-hotfix`, or `production-hotfix`
- `--repo`: path to `kyuyo-backend`
- `--plan-only`: resolve base branch, MRs, commits, and branch names without changing git state
- `--prepare-only`: create the local branch and replay commits without pushing or creating an MR
- `--seal-reviewed`: seal a manually conflict-resolved branch after confirming the original commit count and file set; it does not push or create an MR
- `--publish-reviewed`: assert that semantic review and target verification are complete, then push the current prepared branch and create the MR
- `--project`: override GitLab project path when remote parsing is not enough
- `--base-date`: required staging hotfix base date in `YYYYMMDD`; default is today and applies to `staging-hotfix`

## Execution Notes

- Require a clean working tree before checkout or cherry-pick.
- Never run two executions of this script in parallel against the same repository.
- Require authenticated `glab` access to the GitLab project.
- Default MR discovery is intentionally conservative: original merged MRs only.
- If the ticket maps to multiple MRs, create one combined cherry-pick branch and one combined review MR.
- When the user says `本番hotfix` together with a ticket number, treat that as `production-hotfix`, and create a `customer-cherry-pick/*` MR that targets the latest `hotfix-*` branch; do not create a `production-cherry-pick/*` branch.
- A `--prepare-only` conflict intentionally leaves the repository in cherry-pick state so the agent can resolve it against the semantic-equivalence checklist.
- A clean `--prepare-only` branch is immutable. Validation commands may read or execute it; they may not change its commits or files.
- The CP branch may contain only the original MR replay commits and original MR file set. Test improvements, refactors, formatting, documentation, configuration, and tooling changes require a separate branch and MR.
- `--publish-reviewed` is an explicit approval and integrity gate. Invoke it only after all planned commits are present, conflicts are resolved, semantic mappings are complete, target verification has passed, and the prepared integrity seal still matches HEAD.
