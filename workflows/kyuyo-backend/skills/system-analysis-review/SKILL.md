---
name: system-analysis-review
description: Use when creating, rewriting, or updating kyuyo-backend ticket analysis HTML, system-analysis documents, implementation plans, test plans, rollout plans, or docs ticket index HTML content. This skill audits whether the document reflects real code-based business flow, system flow, data flow, impact, exception handling, test coverage, rollout, and diagram/table requirements before delivery.
---

# System Analysis Review

## Purpose

Use this skill as a mandatory quality gate for ticket analysis HTML. It prevents shallow ticket summaries by forcing the analysis to connect Backlog expectations to actual code, data, modules, risks, tests, and rollout work.

For the full standards extracted from `ai-workspace/docs/systemAnalyse/系分入门(系分要什么)_2014_宿莽整理与鲁肃系分 ppt 大体一致 (1).pptx`, read `references/pptx-system-analysis-standards.md` whenever drafting or reviewing a ticket analysis.

## Mandatory Workflow

1. Read the target HTML before editing.
2. Read ticket body and comments when the task is ticket-bound.
3. Read design materials when referenced or available, including Excel/Sheets, Figma, screenshots, specs, attached files, and linked tickets; extract their concrete requirements before judging coverage.
4. Read conversation-added requirements from the current chat, including corrections and newly stated rules, and treat them as expected items for the current HTML.
5. Read code, tests, config, and existing docs enough to map the real business and system flow.
6. Draft the HTML using the repository fixed 7 sections.
7. Run the audit checklist below before saving or delivering, including source-vs-HTML coverage comparison.
8. If any blocking item fails, rewrite the document and audit again.
9. Only deliver after the audit passes.

Every modification to a ticket analysis HTML must pass this skill after the modification. A failed audit means the current draft must be treated as unfit for delivery.

## HTML Composition Rules

Use the fixed 7 sections, but choose the lightest useful carrier inside each section. One optional section, 修订历史&背景, may appear immediately after 目标 to hold revision history, version/scope attribution, prior-ticket relationships, and source background pulled out of 目标; omit it entirely for simple tickets rather than leaving an empty shell.

- Prefer paragraphs for conclusions, causes, scope, and narrative explanations.
- Prefer short unordered lists for conditions, risk points, and verification results.
- Do NOT use HTML tables. Render any row/column, matrix, mapping, dictionary, or checklist content as a Mermaid diagram or a concise list instead. Any `<table>` in the delivered HTML is a blocking failure.
- Enforce per-section caps on explanatory prose (diagrams, code identifiers, and field/path tokens do not count): 目标, 业务分析, 数据分析, 系统分析, 修改方案, 上线方案 ≤ 100 Chinese characters each; 测试方案 and 修订历史&背景 ≤ 200 each. Prose over the cap means the section is not condensed and must be rewritten.
- Keep each section result-first: start with the answer, then give evidence and boundaries. Cut ticket-number paraphrase, generic statements, and synonymous repetition.
- HTML ticket analysis must be Chinese-led. Use Chinese for section titles, conclusions, diagram node labels, and narrative text. Keep Japanese/English only for original UI terms, code identifiers, API paths, class/method names, error messages, item IDs, field names, and direct evidence.
- Keep diagrams for flow, collaboration, state, or ownership. Do not restate the same information in two diagrams unless the second adds a different lookup value.
- Diagram captions must name the concrete flow/data/model being shown, such as a specific save flow, data definition, state transition, or system sequence. Avoid hard-coded generic captions such as `业务流程图`, `ER 图（含继承关系）`, or `系统协作图`. Place each caption immediately below the diagram and center it, using the shared `diagram-caption` style or an equivalent centered `figcaption`.
- For compact tickets, one diagram plus a few short paragraphs/lists is enough.
- Ticket context HTML is a desktop review artifact by default; mobile layout is out of scope unless the user explicitly asks for it.

## Blocking Audit Checklist

The document fails if any item below is missing or only asserted without code evidence.

- **来源覆盖对照**: must compare the generated HTML against all requirement sources used or mentioned in the task: design docs such as Excel/Sheets/Figma/screenshots/specs, Backlog body, Backlog comments, linked tickets, and conversation-added requirements. Every concrete requirement, field, event, validation, exception, data item, flow, dependency, open question, and acceptance point must either appear in the appropriate HTML section or be explicitly marked out of scope with a reason. Missing source requirements are blocking findings.
- **目标**: must split business target and system target, each stated in a single short sentence. The business target = the payroll/business result; the system target = the code-level state to achieve plus the affected modules and data contract. If either cannot be expressed in one sentence, the goal is not understood and must be condensed before delivery. The section fails if it contains 改訂履歴/version history, prior-ticket scope attribution, scope-boundary or 「明确范围外」 lists, source-vs-HTML coverage enumerations, or Backlog/design/chat background — move all of that to the optional 修订历史&背景 section.
- **修订历史&背景（按需）**: present only when the ticket actually carries revision history, version/scope attribution, prior-ticket relationships, or source background worth recording. When present it holds exactly the historical/attribution content stripped out of 目标 (改訂履歴版本、范围归属与边界、来源对照), sits immediately after 目标, and is omitted entirely for simple tickets rather than left empty. It fails if it absorbs business/system/data/flow analysis that belongs in the other sections.
- **业务分析**: must describe the involved business process in business language only, including actor/trigger, normal path, business rules, business exceptions, current business result, and expected business result. It must not contain API paths, class names, service names, method names, file paths, code identifiers, DTO/entity implementation names, or storage/CRUD terms. Move those details to 数据分析 or 系统分析.
- **数据分析**: must trace code data flow, data owners, input fields, stored fields, derived fields, query keys, value precedence, default/null behavior, and historical data/backfill implications. It must include an ER diagram or Mermaid entity/data relationship graph showing relevant persistent entities/DTOs, owned fields, relationships/cardinality where applicable, inheritance chain for the main persistent DTOs up to `AuditableData`, and which module reads or writes each entity. `AuditableData` should be shown by class name only, without fields/details.
- **系统分析**: must map business steps to concrete implementation paths and explain modification points, related logic, impact range, external/internal services, persistence access, exception handling, transaction/update behavior, and v1/v2 or common module boundaries. It must not be a class-name list. When several files or modules are involved, give one concise list item per path (实现路径→修改点→相关逻辑→影响), never a table.
- **修改方案**: must include concrete change points, alternatives when meaningful, chosen plan with reason, impact range, compatibility, data migration/backfill decision, exception/logging decision, and why the change is minimal under the current architecture.
- **测试方案**: must provide test scope, cases, expected values, line/branch/business path coverage target, regression scope, existing test gap, and execution command or verification route.
- **上线方案**: must state deploy scope, historical data handling, release order, rollback, monitoring/verification points, user-visible risk, and whether any operation or migration is required.
- **Visuals**: process-style analysis must include diagrams. Use Mermaid flowchart/sequence/class/state/ER diagrams for flow, collaboration, state, and data relationships. Each diagram must have a concrete centered caption immediately below it. Impact, field lookup, coverage, and rollout ordering are expressed as lists or diagrams, never tables.
- **Evidence**: every major conclusion must cite concrete file paths, class/method names, item IDs, fields, query conditions, or source artifacts such as design sheet/tab names, Backlog issue/comment IDs, attachment names, and chat-stated requirement text.
- **No filler**: remove repeated sentences, ticket-only paraphrase, generic statements, and ungrounded recommendations.
- **No source omission**: fail the document if an Excel/design-sheet item, Backlog expectation/comment, linked-ticket condition, or chat-added requirement is absent from the HTML without an explicit out-of-scope note.
- **No tables**: fail the document if it contains any HTML `<table>`. All row/column, matrix, mapping, dictionary, and checklist content must be rewritten as a Mermaid diagram or a concise list.
- **Length caps**: fail the document if any section's explanatory prose exceeds its cap — 目标/业务分析/数据分析/系统分析/修改方案/上线方案 ≤ 100, 测试方案/修订历史&背景 ≤ 200 Chinese characters (diagrams and code/field/path tokens excluded).

## Diagram Requirements

Include at least one diagram for flow-oriented ticket analysis. Choose based on the question:

- Business flow: `flowchart` with business trigger, calculation step, storage/read step, and output.
- System collaboration: `sequenceDiagram` with API/service/util/storage participants.
- Data ownership: a required ER diagram (`erDiagram`) or Mermaid graph showing entities/DTOs, source, owner, field, consumer, fallback, relationship/cardinality where applicable, and inheritance chain for the main persistent DTOs up to `AuditableData`. Show `AuditableData` by class name only. Add field-level detail as a short list only if needed.
- State/history: a state diagram when confirm status, history, backfill, or migration matters.

## Section Carrier Guidance

Each section's explanatory prose is capped (目标/业务分析/数据分析/系统分析/修改方案/上线方案 ≤ 100, 测试方案/修订历史&背景 ≤ 200 Chinese characters; diagrams and code/field/path tokens excluded). Never use tables.

- **目标**: exactly two short one-sentence statements — business target and system target. Keep it pure: no revision history, no scope attribution, no source lists, no boundary declarations. If it grows past two sentences, the surplus belongs in 修订历史&背景.
- **修订历史&背景（按需）**: only when there is real history/attribution/background. Use a short list for 改訂履歴版本归属、前置票关系、范围边界与「明确范围外」、来源对照（Backlog 正文/评论、设计书、聊天追加）；omit the whole section for simple tickets.
- **业务分析**: a few short sentences plus one business flowchart. Use lists for business rules and exception conditions. Diagram labels must be business actions/outcomes, not API calls, classes, methods, DTOs, services, or storage operations. The flowchart caption must name the concrete business flow and sit below the diagram.
- **数据分析**: brief prose for data flow plus an ER diagram near the beginning. The ER diagram must show the main persistent DTO inheritance chain up to `AuditableData`; `AuditableData` must have no field details. If field-level detail is needed, add a short list, not a table.
- **系统分析**: one sequence diagram plus a concise list. For implementation paths across several files or modules, give one list item per path (实现路径→修改点→相关逻辑→影响); do not paste bare class/route/method/file names without saying why each changed and what it affects. Never a table.
- **修改方案**: a short chosen-plan statement. When comparing multiple real options, use one list item per option (option → reason), not a table.
- **测试方案**: bullets — one per case with expected value, coverage, and the command/verification route. No matrix table.
- **上线方案**: bullets for release order, rollback, historical data, and monitoring. No checklist table.

## Pass/Fail Output

When auditing, produce a short internal result:

```text
Audit: PASS/FAIL
Blocking gaps:
- ...
Required rewrite:
- ...
```

Do not deliver a failed document. Rewrite first, then audit again.
