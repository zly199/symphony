---
name: git-mr-summary
description: "Generate a fixed-format Chinese Markdown MR description from git branch changes. Use when the user asks to prepare Git merge request text, MR summary, or change notes with a strict two-section format: (1) direct, ticket/email-style design points in plain Chinese, and (2) class-level change details for every modified class. Prefer blunt, concrete wording over official or generic phrasing."
---

# Git MR Summary

Generate MR description text with a strict, reusable format.

## Workflow

1. Detect change scope from git.
- Always determine the intended scope before reading large diffs.
- Extract the ticket id from the current branch name when one exists, for example `KYUYO_NEW-4570`.
- Before trusting a scope, verify ticket consistency across branch name, commit subjects, merge commit message, and changed files. A branch named for ticket A can accidentally point at a merge/amend/rebase result for ticket B.
- If the user only says `git`, `MR summary`, or similar without naming a base branch, inspect scope in this order:
  1. `git status --short --branch`
  2. staged files: `git diff --cached --name-only`
  3. working tree files: `git diff --name-only`
  4. if the worktree is clean and `HEAD` is a merge commit, inspect `git show --no-patch --pretty=fuller HEAD` before summarizing it. If the merge subject names a different ticket than the current branch, treat it as a scope conflict and continue with the ticket-recovery checks below.
  5. if the worktree is clean and `HEAD` is a merge commit matching the intended ticket, merge-resolution files: `git diff-tree --cc --name-only -r HEAD` and concrete changes from `git show --cc HEAD`
  6. if the worktree is clean and there is a tracking branch with local commits, local commit files: `git diff --name-only @{u}..HEAD`
  7. default branch diff only as a fallback: `git diff --name-only <base>...HEAD`
- If the branch ticket and detected scope conflict, do not produce a summary from the conflicting diff. Run ticket-recovery checks:
  - `git log --oneline --decorate --max-count=50 --all --grep=<ticket>`
  - `git reflog --date=iso --max-count=80`
  - for candidate same-ticket commits found in reflog, inspect `git show --stat --oneline <commit>` and `git show --name-only --pretty=format: <commit>`
  - use the newest same-ticket implementation commit only after reading `git show <commit>` or `git diff <commit>^..<commit>`
- If the current branch pointer was overwritten by another ticket's merge/amend/rebase result, say the scope is conflicted and list the candidate same-ticket commit hashes. Do not claim the branch has no ticket changes until reflog and `git log --all --grep=<ticket>` have both been checked.
- Prefer `git diff --name-only <base>...HEAD` only when the user asks for the whole current branch or when the earlier scope checks produce no changed files.
- For merge commits, do not summarize every file brought in from the merged branch unless the user asks for the merged branch content. Use combined diff (`git show --cc`) for conflict-resolution/manual merge changes.
- Use `git diff -- <file>`, `git diff --cached -- <file>`, `git show --cc HEAD -- <file>`, or `git diff @{u}..HEAD -- <file>` according to the detected scope.
- State the internal scope to yourself before writing: source command, ticket id, commit hash or range, file count, and changed file list. If this conflicts with the user's stated ticket/count or the branch ticket, re-check the scope before producing the summary.
- Ignore non-source files unless the user explicitly asks to include them.
- Read the full detected-scope diff before writing. Do not stop after only controller/service/test files if other changed files in the detected scope still affect behavior or API contract.

2. Build class-level change list.
- For Java/Kotlin/C#/TypeScript projects, map file path to class/interface/module names.
- For each changed class, extract exactly what changed and why it matters.
- If a class only has formatting changes, mark it as formatting-only instead of inventing behavior changes.

3. Write design rationale like a normal mail or ticket reply.
- Do not write one big official summary paragraph.
- Write 2-5 short numbered points when the change actually has multiple points.
- Organize the points by feature/function area first, not by sentence variety or by implementation detail.
- Keep one function point in one numbered item. Do not split the same function point across multiple items.
- Put subordinate logic inside the same function point. Example: a query API and its default-year fallback belong to one query function point.
- Say the concrete thing that changed first. Examples: "增加 xx 接口", "1.0/1.5 不变", "删除废弃字段", "统一到新的 service".
- Write plain declarative sentences. Keep each point short and direct.
- If APIs are involved, explicitly list the API declarations in this section with method + path + rough purpose.
- When there are multiple APIs, write one API per line. Do not join multiple API declarations in one sentence or one numbered item.
- Do not write empty phrases like "提升可维护性", "优化整体设计", "降低风险" unless the diff proves a specific matching change.
- Do not use contrast or rhetorical patterns such as `不是...而是...`, `不再...而是...`, `不仅...也...`, `不只...还...`, or similar variants. Rewrite them as simple statements.
- Keep the tone blunt and practical. Write like a developer replying in mail, ticket, or MR, not like a weekly report.

4. Emit final Markdown only.
- Return only the final template content.
- Do not include analysis process, command logs, or "maybe/possibly" wording.
- Output must be directly pasteable into a `.md` file without further cleanup.
- Never wrap output in code fences such as ```markdown.
- Never add any prefix/suffix text (for example: assumptions, notes, explanations, or "以下是...").

## Output Template

Always output the following Markdown structure exactly (raw Markdown text, no code fence):

## 1. 设计思想
1. <先写第一个最核心的改动点，直接说改了什么。>
2. <如果有第二个独立改动点，继续写；没有就不要凑数。>
3. <如果涉及版本边界、前后端配合、删除废弃逻辑、兼容性约束，也直接单列。>
4. <如果有多个 API，就逐行列 method + path + 作用，一行一个。>

## 2. 修改详情
1. <类名A><br>
<该类的精确修改点与行为变化。>

2. <类名B><br>
<该类的精确修改点与行为变化。>

## Quality Bar

- Section 1 must read like normal engineering communication. No official, inflated, or generic wording.
- Prefer short direct sentences over abstract summaries.
- Use declarative sentences only.
- Group section 1 by function points.
- Do not split one function point into multiple numbered items.
- Keep supporting logic under the owning function point instead of promoting it to a separate main point.
- If API behavior changes, section 1 must mention the concrete `GET/POST/PUT/DELETE {path}` and what each one does.
- If there are multiple APIs, each API must be on its own line.
- Mention important non-change boundaries when they matter, for example `1.0/1.5 不变` or `只改 2.0`.
- Do not use `不是...而是...`, `不再...而是...`, `不仅...也...`, `不只...还...`, or equivalent contrast phrasing.
- The summary must be based on the full current branch diff. Do not omit changed classes, API declarations, or behavior-affecting OpenAPI/schema/config files that are actually part of the branch.
- The summary scope must match the intended ticket. If the current branch name, HEAD commit, and diff point to different tickets, resolve the conflict with reflog/history checks before writing.
- Never summarize another ticket's merge commit just because it is current `HEAD` on a ticket-named branch.
- Never report that a ticket has no changes until both direct history (`git log --all --grep=<ticket>`) and reflog (`git reflog --date=iso`) have been checked for same-ticket implementation commits.
- Cover every modified class in section 2; do not skip classes with real logic change.
- Keep class names and technical terms consistent with the code.
- Do not fabricate classes, methods, or business effects.
- If the base branch is unknown, assume the repository default branch silently and continue.
- Keep output strictly limited to the two required sections; no extra heading/paragraph before or after.
