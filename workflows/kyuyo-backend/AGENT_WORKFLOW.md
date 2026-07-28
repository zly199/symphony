# kyuyo-backend Agent 工作流

本文件由 Symphony 维护，定义 kyuyo-backend AI 代理的票执行流程、交付纪律和验证口径。
业务事实与代码规则继续由 kyuyo-backend 仓库维护。

## Governance Map

### Rule Files

- `/Users/user/symphony/WORKFLOW.backlog.md`：Backlog 调度配置与无人值守入口提示。
- `/Users/user/symphony/workflows/kyuyo-backend/AGENT_WORKFLOW.md`：流程、工作法、交付、验证纪律。
- `ai-workspace/governance/KYUYO_DOMAIN.md`：业务与系统知识，覆盖模块、代码位置、版本语义、履历化、Cosmos、系统架构、迁移、业务陷阱。
- `ai-workspace/governance/CODING_RULES.md`：代码相关规则，覆盖实现原则、命名、错误码、注释、日志、测试编写、编译、执行、验证、Review、代码风格。

### Update Targets

```text
Preferred:
- 流程、工作法、防再犯动作写入本文件。
- 业务事实、系统知识、代码位置写入 KYUYO_DOMAIN.md。
- 代码、测试、review 规则写入 CODING_RULES.md。
- 票内过程记忆（进度、决策、验证结果、下一步）写入 agentmemory（见 Agent Memory）。
- 需要交付系分时，分析、修改方案、测试方案、上线方案写入对应 HTML。
```

```text
Avoid:
- 在上下文 markdown 或票 HTML 中沉淀 ticket 过程记忆。
- 把业务规则写进本流程文件。
- 把代码风格规则写进 KYUYO_DOMAIN.md。
- 长期维护全局 skill 副本作为 kyuyo 项目专属 skill 来源。
```

## Start Workflow

### Always

- 每次开始任务前，先执行 `git status`。
- 读取目标文件当前磁盘内容后再判断、分析或修改。
- 任何任务先读本文件。
- 所有交付给用户的结果必须用中文。
- 票据标题、Java 注释、`message-kyuyo_ja_JP.properties`、設計書等日语材料作为输入材料处理；回复与交付正文仍使用中文。需要引用日语文言时，只逐字引用该文言字符串，其余说明使用中文包裹。
- 输出只保留交付有用信息：修改内容、修改原因、影响范围、验证结果、剩余风险。
- 禁止使用带有二元对照意味的句式。

### Before Business Or System Judgement

- 先读 `ai-workspace/governance/KYUYO_DOMAIN.md`。
- 再读具体 Backlog、评论、设计资料和代码。
- 涉及模块定位、版本语义、履历化、Cosmos 持久化规则时必须执行本步骤。

### Before Code Work Or Review

- 先读 `ai-workspace/governance/CODING_RULES.md`。
- 写代码、改代码、写测试、跑测试、做 code review 都适用。
- 涉及跨模块、跨版本、common/app 聚合边界时，先确认模块职责、调用方向、既有扩展点与作废条件。

### User Testing Preference

- 用户明确表示自行执行测试时，立即停止后续自动测试执行。
- 交付时说明最后已完成的验证结果。
- 同时列出待用户执行的目标测试。

### Context And Subagent Discipline

- 探索性、只读、体量大的检索——全仓 grep、多文件通读、定位代码、跑测试或构建看输出——交给子代理执行；主线程只接收结论，不把 grep 命中列表、源码全文、命令日志灌进主线程上下文。
- 一个子代理打包一整段探索（定位＋通读＋归纳）返回一份结论；不要为单条 grep 频繁 spawn，冷启动开销会反噬。
- 产出性与破坏性写操作（改代码、写/改 ticket HTML、`git rm`/删除/重置）一律留在主线程执行，保持 diff 对用户可见；不得隐藏在子代理里。此条与防幻觉纪律一致。
- 上下文变重时在阶段收尾处提示用户开新会话；恢复依赖 session-start 自动注入与 `memory_recall(票号)` + `memory_next`，不整份重灌历史。

## Ticket Workflow

### Ticket Detection

- 默认从当前分支名提取票号，例如 `fix/KYUYO_NEW-4175-...` -> `KYUYO_NEW-4175`。
- 无法提取票号且任务需要 ticket 口径时，向用户确认。
- 所有改动默认基于 ticket。

### Workspace Isolation

- Symphony 无人值守跑票时，工作目录是该票专属的 git worktree（`/Users/user/IdeaProjects/kyuyo-worktrees/<票号>`），与用户自己使用的
  `/Users/user/IdeaProjects/kyuyo-backend` 共享同一份 Git 历史但互不干扰。
- 只在自己的 worktree 内改文件、切分支、跑构建。禁止在 `/Users/user/IdeaProjects/kyuyo-backend` 内切分支、改文件、reset、stash 或删除；该目录只允许读取。
- worktree 内不得 checkout `master`：`master` 由用户的检出占用，切换会直接失败。基线一律用 `origin/master`。
- 票结束（Backlog 转入终态）后 Symphony 才回收 worktree；worktree 内还有未提交内容时保留不删。
- 可能同时有多票各自在自己的 worktree 里并行推进。只操作自己这一票的 worktree 和分支，不读改其他票的 worktree，不共用临时文件路径。

### Ticket Branch Preparation

- 读取 Backlog 正文、评论、`issueType.name` 与全部 category 后，先准备票分支，再开始代码分析、系分编写或实现。
- 当前分支名包含目标票号时，保留该分支及本地进度并继续。
- 当前分支属于其他票时，工作区必须干净；发现未提交内容立即停止分支切换，先报告需要保留的文件。
- 新票统一执行
  `/Users/user/symphony/workflows/kyuyo-backend/scripts/prepare_ticket_branch.py`，`--repo` 传当前 worktree 路径。脚本拉取 `origin`，直接从 `origin/master` 创建票分支，不检出也不改写本地 `master`。
- 分支格式固定为 `<scope>/<票号>-<Backlog完整票名>`。性质优先级固定为：Bug 使用 `fix`；CI、文档、設計書使用 `doc`；其余使用 `feat`。
- 性质判断输入包含 Backlog 的 `issueType.name` 与全部 category。多个性质同时命中时按 `fix`、`doc`、`feat` 顺序选择。
- 分支名处理规则：空白与 Git ref 非法字符转为 `-`，连续分隔符合并，合法 Unicode 字符保留，尾部 `.lock` 改写，UTF-8 component 超长时按完整字符安全截断。
- 示例：`feat/KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー`。
- 脚本返回 `created:` 时，继续前确认当前分支含目标票号，且 `HEAD` 等于 `origin/master`。脚本返回 `reuse:` 时，按已有票进度恢复。
- `origin/master` 缺失、目标分支已被其他 worktree 检出、或 Git 命令失败时停止票实现，保留现场并报告具体失败。

### Commit And Merge Request

- 一票一个 commit。票分支上还没有自己的提交时创建提交；之后同一票的任何修改一律 `git commit --amend`，不追加第二个提交。
- 提交前先看 `git log --oneline origin/master..HEAD`：0 个提交则新建，1 个提交则 amend，超过 1 个先压回 1 个再推。
- commit message 必须包含票号。
- 首次推送用 `git push -u origin HEAD`；amend 之后用 `git push --force-with-lease origin HEAD`。`--force-with-lease` 只允许用在本票分支，禁止裸 `--force`，禁止推 `master`。
- 已经进入 `origin/master` 的提交禁止改写。
- 分支推送后必须建 MR 到 `master` 供 review，这是完成票的必要步骤，不是可选项。
- MR 标题固定由分支名推导：把分支名的第一个 `/` 换成全角 `：`，其余原样保留，不加不减不翻译。
  例：分支 `fix/KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー` 对应标题
  `fix：KYUYO_NEW-4658-【backend】【Customer環境】給与計算エラー`。
- 建 MR 命令：
  ```sh
  branch="$(git branch --show-current)"
  title="$(printf '%s' "$branch" | sed 's|/|：|')"
  glab mr create --source-branch "$branch" --target-branch master --title "$title" --description '<摘要>' --yes
  ```
- 该分支已有开着的 MR 时复用它，不重复创建；amend 后的推送会自动更新 MR 内容。
- 禁止自动合并 MR。
- `glab` 未认证或建 MR 失败时，把具体失败原因作为阻断项报告，不得默默结束票。
- 工作未做完也要把已验证的部分提交并推送，让 MR 反映当前状态，同时说明剩余项。

### Backlog Reading

- 只要任务绑定 ticket，在分析、实现、review、测试方案判断前，必须先读取 Backlog 正文。
- 涉及方案判断、review、验收覆盖时，还必须读取评论补充。
- 当前 ticket 正文或评论出现参考票、元课题、关联票、依赖 ticket 等明确编号时，继续读取关联 ticket 正文与评论。
- Backlog 只读链路默认可用：优先检查 `~/.config/opencode/opencode.jsonc` 中的 backlog MCP 配置并注入凭据。
- 没有凭据缺失、凭据失效或网络受限的明确证据时，继续排查可用读取链路。
- 无法完成 Backlog 实读时，先排查凭据源、脚本、MCP 配置与网络权限。

### Design Material Handling

- 需求或设计资料为 Excel（`.xlsx` / `.xlsm`）时，先用 `excel-to-html` skill 转换为 HTML，再读 HTML 做分析；禁止直接 Read 二进制 Excel（会丢失合并单元格、多 sheet、行列网格）。
- 转换产物存到当前票目录：`ai-workspace/docs/tickets/<票号>/design.html`（图片输出到同目录 `design_<...>_images/`），作为设计书快照便于 AI 后续召回。
- 在 `ai-workspace/docs/index.html` 注册该 `design.html` 链接（与票的 `index.html` 同级登记）。
- 设计书用字体颜色标注修订范围（如改訂履歴赤字/青字对应不同版本）时，`excel-to-html` 不保留颜色；需求归属或范围判断依赖颜色时，必须用 openpyxl `rich_text=True` 读 run 级字体颜色确认（单元格内部分着色在 cell-level 读不到），不能只凭转换后的 HTML 文本。
- 同一规则适用于 staging / production / customer hotfix 目录下的 Excel 设计资料。

### Agent Memory

过程记忆由 agentmemory（MCP）承载，票 HTML 不再作为每轮读写的记忆载体。

#### Roles

- 过程记忆（进度、推导结论、决策、验证结果、下一步）一律进 agentmemory；禁止沉淀到票 HTML 或新增上下文 `.md`。
- 票 HTML（`ai-workspace/docs/tickets/<票号>/index.html` 及各 hotfix 目录）只承担系分交付物职责，仅在票需要交付系分时按 Documentation Rules 编写，并在 `ai-workspace/docs/index.html` 注册链接。
- 三个治理文件仍是硬规则唯一权威；违反即事故的约束（Cosmos、分页 cursor 等）不迁入 agentmemory，不依赖检索命中。
- Claude 原生 memory 卡（`~/.claude/projects/-Users-user-IdeaProjects-kyuyo-backend/memory/`）只放对 Claude 行为的约束类反馈；项目过程与领域经验一律进 agentmemory，禁止双写。

#### Conventions

- `project` 固定用稳定标识 `kyuyo-backend`，禁止用文件系统路径。
- 每票一个根 action，标题为票号（如 `KYUYO_NEW-4570`）；子 action 按分析/实现/测试/MR 拆分，依赖用 `requires` 表达。
- action、memory、observation 统一打 facet 标签 `ticket:<票号>`。
- 关键决策、影响范围结论、验证结果用 `memory_save` 落库：`type` 取 architecture/bug/fact，`files` 带涉及路径，`concepts` 必含票号。
- `concepts` 标签统一词表：必含 `kyuyo-backend`；业务锚点概念（模块架构/履历化/domain-map 等）沿用图内既有标签写法，新锚点中英双写（如 `履历化,rirekika`），禁止同一概念另起新词造成词表分裂。
- `memory_save` 前先 `memory_recall` 查重：既有节点已覆盖同一事实时不重复保存，只对增量差异新增节点；发现重复节点报告用户，删除走 `memory_governance_delete` 且需用户确认。
- CI、MR 审批等外部等待用 `memory_checkpoint` 门控对应 action。
- 倾向性经验（非硬规则）用 `memory_lesson_save`，`context` 写清适用场景；是否升格为治理文件硬规则由 weekly-retro 复核决定。

#### Loop

按 gather context → take action → verify work → repeat 循环推进：

- gather context：会话开始依赖 session-start 自动注入；`git status` 从分支名提取票号后，`memory_recall(票号)` + `memory_next` 恢复进度；方案决策前 `memory_lesson_recall`。
- take action：领取 action 置 active；主线程写码、子代理只读探索（见 Context And Subagent Discipline）。
- verify work：编译、测试、review 结果写入 `memory_action_update`（status + result）；外部等待由 checkpoint resolve 解锁。
- repeat：阶段收尾 `memory_save` 结论；票完结（MR 合并）后 action 全部置 done，再 `memory_crystallize` 压缩归档。

#### Runtime Notes

- Codex 运行时没有自动采集 hook，上述 save/update 必须显式执行；Claude 侧同样显式执行，hook 自动采集只作兜底。
- agentmemory 服务不可用时，临时把进度记到 scratchpad 或票目录本地文件，恢复后补录并删除临时文件。

## Documentation Rules

### HTML Asset Rules

- 本节适用于系分交付 HTML：仅在票需要交付系分时编写；过程记忆见 Agent Memory。
- 文档页统一引用 `ai-workspace/docs/assets/docs.css` 与 `ai-workspace/docs/assets/docs.js`。
- HTML 中避免重复写相同的内联 CSS / JS。
- 系分交付 HTML 固定维护 7 个语义区块：目标、业务分析、数据分析、系统分析、修改方案、测试方案、上线方案。可选区块「修订历史&背景」按需出现，紧跟「目标」之后，承接从目标剥离的改訂履歴/版本归属/范围边界/来源背景等历史性内容；简单票（如纯技术票）无此类内容时直接省略，不留空壳。
- 内容优先写结果、证据、边界、结论。
- 更新系分交付 HTML 前后都必须通读全文。
- 结论变化时，同步刷新相关章节。

### Mermaid Rules

- mermaid 图由 `ai-workspace/docs/assets/docs.js` 渲染。
- HTML 中避免自带 mermaid `<script>` 或 `mermaid.initialize`，防止与全局渲染重复初始化导致图空白。
- mermaid 节点标签含 `(` `)` `/` `+` `※` `:` 等特殊字符时，必须用双引号包裹，例如 `V1["必須 / 名称重複(支給区分+支給形態)"]`。
- `stateDiagram` 的状态名使用 `state "中文/日文" as Alias`，节点 id 使用 ASCII。

### System Analysis HTML

- **各节点解释性文字设硬上限**（只算散文与列表说明，图、代码标识符、字段/路径本身不计）：目标、业务分析、数据分析、系统分析、修改方案、上线方案每节 ≤ 100 字；测试方案、修订历史&背景每节 ≤ 200 字。超限即视为尚未收敛，必须精炼后再交付。
- **严禁 HTML 表格（`<table>`）**：任何行列/矩阵/映射/清单信息一律改用 mermaid 图或精简列表承载。影响分析、测试覆盖、上线顺序、字段字典、路径映射等原本表格化的内容，全部转为图或列表。
- 用最精炼的语言把"要做什么"说清：优先写结果、证据、边界、结论，删掉复述票号、通用套话、同义重复。
- 目标必须拆分业务目标与系统目标，各用一句话讲清：业务目标=要达成的业务/工资结果，系统目标=要达到的代码侧状态与受影响模块/数据契约。任一项无法一句话说清，即说明尚未理解目标，必须收敛。改訂履歴/版本归属、前置票关系、范围边界与「明确范围外」声明、来源对照（Backlog 正文/评论、设计书、聊天追加要求）等历史性或分析性内容一律剥离到「修订历史&背景」，严禁混入目标。
- 数据分析必须覆盖代码数据流、数据归属、字段来源、查询条件、默认值、历史数据影响。
- 业务分析必须从代码行为还原业务流程与业务规则。
- 系统分析必须映射到模块、类、方法、异常处理、持久化与 v1/v2/common 边界；多文件/模块用列表逐条给「实现路径→修改点→影响」，不用表格。
- 修改方案必须包含影响范围、兼容性、异常与日志、历史数据处理、备选方案权衡。
- 测试方案必须包含测试范围、case、预期值、行/分支/业务路径覆盖。
- 上线方案必须包含历史数据、发布顺序、回滚、监控与风险。
- 流程型变更的 HTML 必须包含业务流程 `flowchart`、系统协作 `sequenceDiagram`、有状态变化时的 `stateDiagram`、数据/领域关系图（`erDiagram`/graph）；影响、测试覆盖、上线顺序用列表或图表达，不得用表格。
- 分析过程必须覆盖业务流程还原、数据归属与字段来源、模块/类/方法映射、异常处理。
- 缺图或省略分析过程时，按 `system-analysis-review` 的 audit 信号重写。

### Review Gate

- ticket 分析、系统分析、修改方案、测试方案、上线方案或系分交付 HTML 更新，在交付前必须使用 `system-analysis-review` skill 审查。
- 审查未通过时，重写并再次审查，直到通过后再输出给用户。
- 该 skill 必须在当前运行时存在：Codex `~/.codex/skills/` 与 Claude `~/.claude/skills/` 两侧都要装。
- 发现某侧缺失时，先补齐再继续。

## Implementation Boundaries

### Module Boundaries

- 跨模块、跨版本、common/app 聚合边界改动进入实现前，先确认职责归属、依赖方向、扩展点。
- 方案若需要通过反射、字符串类名、运行时查找等方式绕过模块依赖来调用业务服务，立即作废并重新设计。
- 已写内容若放进错误模块、让低层模块承担上层聚合职责、或让同级版本模块互相知道业务服务，视为草稿并废弃。

### Skills

- kyuyo 工作流 skill 唯一源目录是
  `/Users/user/symphony/workflows/kyuyo-backend/skills/`。
- kyuyo 工作流 skill 只维护 Symphony 中这一份。
- 开票、review、上线前，对照本文件的默认检查项。

### Release And Cherry Pick

- `staging hotfix` / `staging cp` 的 cherry-pick 基线必须是当日 `origin/staging-hotfix-YYYYMMDD`；当日分支不存在时，先执行 staging release 创建当日基线，再创建 `staging-cherry-pick/*` MR，禁止退回旧日期 staging 分支。
- `test cp`、`test-hotfix`、`test-cherry-pick` 默认基线固定为 `origin/production`。
- 用户请求同时出现 ticket 编号和本番 hotfix / 本番 cp 时，默认执行该 ticket 到当日本番 `hotfix-*` 分支的 cherry-pick，并创建 `customer-cherry-pick/*` MR。
- 明确出现发版、发布、部署本番 hotfix 分支时，执行 deploy-only 的 `kyuyo-hotfix-release` 流程。
- 同一仓库内，串行执行会写 git 状态的发布 / cherry-pick 流程，避免 `.git/index.lock` 冲突造成错误分支或半成品 MR。
- cherry-pick 的文件数、增删行数、`shortstat` 只作诊断信息，禁止据此判定回放正确。创建 MR 前必须逐项核对原 MR 的业务条件、分支逻辑、数据读写、输出字段、异常行为与测试意图在目标基线中保持一致；发生冲突时允许统计量不同，仍须完成业务语义映射和目标测试验证。
- hotfix CP 分支是原 MR 的封闭回放产物：提交数与变更文件集合必须对应原 MR，禁止追加测试强化、重构、格式化、文档、配置、工具或顺手修复提交。发现需要额外改动时停止发布，另建分支和 MR，并先取得用户明确授权。
- `prepare-only` 成功后分支立即冻结。语义 review、编译与测试只允许读取或执行当前分支，禁止改写提交和文件；测试覆盖不足时报告验证缺口，禁止在 CP 分支补测试。
- `publish-reviewed` 前必须通过脚本 integrity seal：校验 base SHA、prepared HEAD、提交列表、文件列表和 diff 指纹。任一项变化即拒绝 push 和 MR 创建；冲突解决完成后先用 `--seal-reviewed` 建立一次性封印。

## Default Checks

### Before Ticket Work, Implementation, Review, Or Release

- ticket、分支、实际 diff、MR 摘要要一致；发现混入其他 ticket 代码时，先清理归属。
- 跨模块改动先确认职责归属、依赖方向和扩展点，再比较 diff 大小、风险和验证成本。
- 履历化只传 `baseDate` 时，必须追到 core、adapter、service 的最终查询入口，确认成员集合和关键字段都按同一基准日收敛。
- 测试断言必须对应 ticket 需求；master 既有基线只做基线保护。
- 测试失败先分类，再决定修实现、修测试或标注环境阻断。
- review 覆盖必须断言真实路径的关键输出字段。
- 上游契约收敛后，同一调用链的判空、日志、测试断言必须同步收口。
- 用户明确要求 staging hotfix、test cp、本番 cp 时，执行目标是创建对应 cherry-pick 分支和 MR。
- plan-only、MR 状态检查、脚本提示只作为执行前校验；目标 ticket、base branch、source commit 和现有重复 MR 核对后继续推进到可交付 MR。
- 冲突、重复 MR、目标基线缺失、cherry-pick 失败等会产生错误产物的情况才停止。
- 批量 migration / 修复型分页的 cursor 键必须唯一全序，优先 `id`。
- 写分页前自检同值多行跨页是否会漏，测试必须构造同值跨页场景。

## Search And Context

### Preferred

```text
Preferred:
- 不知道代码位置时，先依据 KYUYO_DOMAIN.md 定位模块，再做范围检索。
- 第一轮只定位候选文件，优先使用 rg -l。
- 限制源码文件类型并排除 target、build、.idea、大资源目录。
- 找到候选文件后，再用 rg -n -C 3、sed -n、awk 读取小范围上下文。
- 单次命令输出尽量控制在 200 行以内。
```

### Avoid

```text
Avoid:
- 对 social、data、info、service、履歴、反映、随時、社会保険 等高频词第一轮全仓 rg -n。
- 把完整 CSV、完整测试资源、模板 JSON/XML、日志、构建输出直接带入上下文。
- 在输出很多时继续扩大检索范围。
```

## Requirement And Delivery

### Requirement Rules

- 需求口径优先于当前实现现状。
- 代码现状与 ticket、评论、已确认上下文结论冲突时，先按实现可能有误处理。
- 输出结论时逐条对照期待项，明确已覆盖、未覆盖、风险点。
- 某个行为属于 `master` 既有基线时，修改测试或实现前明确区分本票新增契约与已有基线。
- Backlog 读取类接口默认可直接执行。
- Backlog 写入类接口必须先申请并获得批准。

### Analysis Output

- 系统分析必须结果导向：先回答条件与结果，再解释原因。
- 用户要求"分析当前票"、"分析票"、"看当前票"等 ticket 分析任务时，若已读取 Backlog/设计书/代码并形成结论，必须产出或更新 `ai-workspace/docs/tickets/<票号>/index.html` 系分文档；票目录缺少 `index.html` 时创建，交付前走 `system-analysis-review`，禁止只给口头分析。
- 涉及多方案时，明确写出方案 A 结果、方案 B 结果、推荐结论。
- 显式区分安全条件、风险条件、确定性问题、条件触发风险。
- 所有风险结论都要给出最短调用链与关键触发点。
- 风险分析拆清当前已使用能力、当前未使用但已具备能力、未来触发后的影响。

### Completion Standard

- 产出的代码必须可运行或可编译。
- 若执行代码需要特定命令，给出简短运行说明。
- 结论里必须明确影响范围、验证结果、剩余风险。
- 验证结果必须分层输出：编译口径结果、目标测试口径结果、失败分类、人手验证步骤。
- 无法完成某项验证时，明确说明阻断原因。

## Incident Feedback

### When A Serious Error Happens

- 明确根因与有效对策后，抽象成可复用防再犯规则。
- 流程或工作法问题写入
  `/Users/user/symphony/workflows/kyuyo-backend/AGENT_WORKFLOW.md`。
- 业务或系统知识写入 `ai-workspace/governance/KYUYO_DOMAIN.md`。
- 代码或测试规则写入 `ai-workspace/governance/CODING_RULES.md`。
- 倾向性、尚不足以成文的经验用 `memory_lesson_save` 落 agentmemory，由 weekly-retro 复核后升格为硬规则或淘汰。

### Preferred

```text
Preferred:
- 规则短、明确、可执行。
- 写入前对照代码或实际流程验证。
- 复盘时清理重复、失效、过期规则。
```

### Avoid

```text
Avoid:
- 把一次性聊天过程堆进规则文件。
- 把未经验证的猜测写成项目事实。
- 在多个治理文件重复维护同一条规则。
```
