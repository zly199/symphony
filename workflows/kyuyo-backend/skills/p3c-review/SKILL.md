---
name: p3c-review
description: Review Java code using Alibaba P3C rules and produce a risk-ranked findings summary with concrete fixes. Use when users ask for code review, coding-standard checks, or pre-merge quality gates on Java/Spring/Maven repositories and explicitly mention P3C, Alibaba Java guidelines, PMD checks, or style violations.
---

# P3C Review

Use this skill to run Alibaba P3C-based static review on Java code, then convert raw violations into actionable review comments ordered by risk.

## Workflow

1. Confirm review scope:
- Default to current branch Java changes: committed changes on current branch (vs merge-base with upstream/base branch) + local staged + local unstaged.
- Prefer `scripts/run_p3c_review.sh` auto-scope to avoid missing committed changes.
- Restrict to `*.java` unless user asks for full-scan.

2. Load project-specific style rules:
- If the target repository is `kyuyo-backend`, always load `references/kyuyo-backend-style.md`.
- Enforce those rules together with P3C findings instead of treating them as optional suggestions.
- If P3C and project style conflict, mark as `project-style override` and follow repository rule.

3. Try automatic scan:
- Run `scripts/run_p3c_review.sh` from repository root.
- If the script reports that P3C rules are not wired in Maven, follow `references/p3c-maven-setup.md` and re-run.

4. Produce review output:
- Focus on `priority in {1,2}` first, then summarize `priority 3`.
- For each finding, include: rule name, file:line, risk, and concrete fix.
- Group repeated findings to avoid noisy duplicate comments.

5. Apply review rigor:
- Treat concurrency, exception handling, logging, SQL, and security-related violations as higher risk.
- When a rule conflicts with established local style, flag it as "style conflict" instead of forcing change.

## Output Format

Use this structure in responses:

1. `Scan scope`: module/path and command used.
2. `High-risk findings`: only blocking issues first.
3. `Project style findings`: README-derived rule violations (if any).
4. `Medium/low findings`: compact grouped summary.
5. `Suggested fixes`: concrete and minimal diffs or code snippets.
6. `Residual risk`: what was not scanned or what needs manual review.

## Commands

From target repository root:

```bash
bash /Users/user/symphony/workflows/kyuyo-backend/skills/p3c-review/scripts/run_p3c_review.sh
```

Default behavior (no args):
- Auto-scan Java files changed in current branch scope:
  - committed on current branch (`merge-base(base, HEAD)...HEAD`)
  - plus staged and unstaged local changes
  - base priority: upstream branch, then `origin/master`, `origin/main`, `master`, `main`

For specific modules or paths:

```bash
bash /Users/user/symphony/workflows/kyuyo-backend/skills/p3c-review/scripts/run_p3c_review.sh --paths kyuyo-app/src/main/java
```

If you need to force a specific compare base:

```bash
bash /Users/user/symphony/workflows/kyuyo-backend/skills/p3c-review/scripts/run_p3c_review.sh --base-ref origin/master
```

If Maven profile/setup is missing, follow:
- `references/p3c-maven-setup.md`

For `kyuyo-backend` repository style checks, follow:
- `references/kyuyo-backend-style.md`
