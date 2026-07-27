---
name: weekly-retro
description: "Use when the user asks to run a weekly retrospective, summarize the past week's sessions/questions, or refactor & consolidate the kyuyo-backend agent's governance files, agentmemory, and memory cards. Mines agentmemory (sessions/reflect/patterns/lessons/audit) plus legacy docs HTML for recurring user feedback, repeated failure patterns, and new domain facts, then merges them into governance files (AGENTS_PROJECT/KYUYO_DOMAIN/CODING_RULES), promotes or retires agentmemory lessons, ingests new atomic memories/lessons into agentmemory every run (mandatory step, per docs/memory-ingest/DOMAIN_INGEST_PROMPT.md), runs memory hygiene (diagnose/crystallize/consolidate/snapshot), and keeps Claude memory cards + MEMORY.md index in sync. Pairs with weekly-ticket-retro, which does the Backlog ticket-stream side. Goal: keep the agent's perception system sharp so each kyuyo dev task is completed better, with fewer repeated mistakes."
---

# Weekly Retro — 感知系统自维护

把"最近一周的所有工作痕迹"提炼成可复用规则：重构治理文件、管理 agentmemory 的 lesson 生命周期、做记忆卫生，让 agent 每次都比上次更少犯错、更快命中给与系统开发任务。

输出与交付一律用中文（见 `[[feedback_reply_in_chinese]]`）。

## 何时触发

- 用户说"总结这周对话 / 周复盘 / retro / 重构记忆 / 重构治理文件 / 合并记忆"。
- 每个迭代结束、或连续踩同类坑后想沉淀规则时。

## 与 weekly-ticket-retro 的分工

本 skill 的原料是 **agentmemory 会话/lesson/audit + 治理文件**，视角是"我这个 agent 哪里反复犯错"。
票流侧的复盘（拉一周 Backlog 票、逐张分析、写入记忆）在 `weekly-ticket-retro`，视角是"这个系统这周暴露了什么业务事实与坑"。

**两者同一天跑时，先 weekly-ticket-retro 再 weekly-retro**：ticket-retro 产出新 lesson 与新记忆，本 skill 的步骤 4 正好把它们纳入当周裁决。反过来跑，新挖的 lesson 要等一周才被处理。
用户只说"周复盘"而这周有实质票流时，提示可以先跑 `weekly-ticket-retro`，由用户决定。

## 知识分层（重构时按此分流）

Symphony 承载流程层和工作流审计；kyuyo-backend 承载业务知识、代码规则与交付文档：

- **`/Users/user/symphony/workflows/kyuyo-backend/AGENT_WORKFLOW.md`（流程层）**：工作流、交付口径、检索纪律、Agent Memory 约定、默认检查项。稳定、少改，**不放具体票号**。
- **`ai-workspace/governance/KYUYO_DOMAIN.md`（业务/系统层）**：模块架构与边界、版本语义、履历化、模块↔代码位置地图、Cosmos 持久化、Public client、业务陷阱。**每周重点扩充，让 agent 越积越懂给与系统**。
- **`ai-workspace/governance/CODING_RULES.md`（代码规则层）**：一切跟代码打交道的规则（实现原则、命名、错误码、注释、日志、测试编写/编译/执行/验证、Review、代码风格）。
- **agentmemory（过程/经验层）**：票内过程记忆（action/observation/memory_save 结论）与 lesson（倾向性经验，confidence 强化/衰减）。过程记忆按票归档，不进治理文件；lesson 是"候选规则池"，由本 skill 每周裁决升格或淘汰。
- **memory 卡（Claude 召回/个人层）**：`/Users/user/.claude/projects/-Users-user-IdeaProjects-kyuyo-backend/memory/`——只放对 Claude 行为的约束类反馈与个人偏好、凭证位置指针；项目过程与领域经验不放这里（进 agentmemory 或治理文件），禁止双写。
- **`/Users/user/symphony/workflows/kyuyo-backend/retro_history.md`（审计日志，仅本 skill 读写）**：复盘的**直接结果不写这里**——结果按内容分流进上面活层。retro_history 只追加"哪次复盘改了什么、票号样本"的变更记录，供下次复盘对照；活文件与日常任务都不引用它。

## 固定路径与工具

- memory 卡目录：见上；索引 `MEMORY.md`（每条一行指针，加载进每个 session）。
- agentmemory 工具：`memory_sessions`（周会话骨架）、`memory_reflect` / `memory_patterns`（反复模式提炼）、`memory_lesson_recall` / `memory_lesson_save`（lesson 池）、`memory_audit`（操作轨迹）、`memory_diagnose` / `memory_crystallize` / `memory_consolidate` / `memory_snapshot_create`（卫生与归档）。`project` 固定 `kyuyo-backend`。
- 备选会话源（agentmemory 不可用时降级）：`mcp__ccd_session_mgmt__list_sessions`、`search_session_transcripts`。
- 双运行时 skill 目录：Codex `~/.codex/skills/`、Claude `~/.claude/skills/`（见步骤 7）。

## 工作流

### 1. 圈定时间窗 + 收集一周骨架
- 先读 `/Users/user/symphony/workflows/kyuyo-backend/retro_history.md`（仅本步读取），了解上次复盘改了什么、上轮票号样本，避免重复推导、对照漂移。
- `memory_sessions` 取最近 7 天（或用户指定窗口）会话与 observation 计数，作为本周"做了什么"的骨架；票号从 session 摘要与 facet 标签 `ticket:<票号>` 聚合。
- agentmemory 不可用时降级 `list_sessions(limit=40)` 过滤 cwd=kyuyo-backend；两个源都不可用则跳过该步（自动模式常见，属正常降级）。

### 2. 挖掘信号（先读现有沉淀，再补差）
- **先读全量现状**：通读三个治理文件 + 逐个读 memory 卡正文 + `MEMORY.md`。已沉淀的不要重复挖。
- **agentmemory 主渠道**：
  - `memory_reflect` / `memory_patterns`：让服务端先提炼一周反复出现的模式与洞察，替代人肉全文检索。
  - `memory_lesson_recall`（project=kyuyo-backend，宽 query 分几轮）：拉出本周新增与被强化的 lesson，作为"候选规则"清单。
  - `memory_audit`：扫操作轨迹，识别反复失败重试、反复查同一问题的信号（说明上下文缺失）。
  - 针对具体疑点再 `memory_recall(关键词/票号)` 补上下文。
- **存量考古（补充渠道，只对旧资产）**：`ai-workspace/docs/tickets/*/index.html` 等历史票 HTML 与 `docs/other/*` 仍可 grep `<code>`/`<strong>`/`<h3>` 聚合高频领域术语；新票过程记忆已不写 HTML，此渠道只做存量挖掘，产出写入业务层前必须对照实际代码（kyuyo-backend / onehr-core）验证并标注"以代码为准"。
- **抽取原料**：用户偏好/纠正（带**为什么**）、反复失败模式、新领域事实、反复问的同类问题（上下文缺失信号）。

### 3. 分类每条发现（五桶分流，关键判断）
对每条发现先判"流程 / 业务 / 代码 / 经验 / 召回"，再落桶：
- → **`AGENT_WORKFLOW.md`（流程层）**：适用于每个 ticket 的跨切面工作流、交付口径、检索/测试/review/上线纪律、默认检查项。规则要能在不读记忆的情况下独立执行。**违反即事故的硬约束只能放治理文件，不能只留在 lesson。**
- → **`KYUYO_DOMAIN.md`（业务/系统层）**：模块架构与边界、版本语义、履历化规则、模块↔代码位置、Cosmos 持久化约定、具体业务流程/字段口径。**每周扩充重点。**
- → **`CODING_RULES.md`**：一切跟代码打交道的规则。凡"写代码、写跑测试、做 review"的规则都进这里。
- → **agentmemory lesson**：尚不足以成文、需要更多样本验证的倾向性经验——`memory_lesson_save` 留在候选池继续攒置信度，下周再裁决。
- → **memory 卡**：仅限对 Claude 行为的约束类反馈（`feedback`，带 Why+How）、`user` 长期偏好、凭证位置类 `reference` 指针。项目过程与领域经验不落这里。
- 通用默认检查项（每票都查的坑）→ AGENT_WORKFLOW.md 的 Default Checks（去掉具体票号）。票号样本只进 `retro_history.md`。

### 4. lesson 生命周期裁决（agentmemory 特有环节）
- **升格**：高置信度、被多次强化、跨票复现的 lesson → 改写成治理文件条目（按三桶归位），升格后原 lesson 可删或改写为一句指针。
- **淘汰**：置信度衰减到低位、被证伪、或已被治理文件覆盖的 lesson → 删除。
- **保留观察**：样本不足的留池继续攒，不急着成文。
- 升格/淘汰的每条决定写进报告与 retro_history。

### 5. 记忆写入（每次 retro 必做，不是可选项）

**每次 retro 都必须往 agentmemory 写入新知识**——只重构治理文件、只裁决存量 lesson 而一条新记忆都不写，说明这周读到的东西被当场扔了。写入纪律以 `/Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md` 为准（开工前读一遍），要点：

- **颗粒度 = 一个事实一条**，不是一周一条总结。读一次，挖 N 条。
- **双载体分流**：结构事实 → `memory_save(type=architecture)`；业务规则 → `memory_save(type=fact)`；陷阱/漏改/操作前提 → `memory_lesson_save`（confidence 0.6-0.7）。
- **ASCII 锚点**：`concepts`/`tags` 必须含类名/方法名/枚举名，相关条复用同一批类名以便连边。
- **红线**：`find` 能重算的、不能自立成"改动前要知道的一条事实"的，不写。
- **不臆造**：与代码冲突以代码为准，不确定标注"未确认"。

本步的写入原料来自步骤 2 挖出、但**不该进治理文件**的那部分：
- 治理文件太具体、又确实值得跨会话检索的**领域事实**（某字段口径、某计算边界、某平行结构）→ `memory_save`。
- 样本不足以成文的**倾向性经验**→ `memory_lesson_save` 留池，下周由步骤 4 裁决。
- **本周新读过代码的域**，若 `DOMAINS.md` 里还没勾掉，顺手把读到的挖成原子记忆并更新 `DOMAINS.md` 进度。

**验收**：写完跑 2-3 个 `memory_smart_search` + 1 个 `memory_lesson_recall(project="kyuyo-backend")` 确认能命中；查不到多半是 ASCII 锚点不足，回去补。写入条数与 anchor id 进报告。

> 若同期跑了 `weekly-ticket-retro`，票流侧的记忆写入已由它完成，本步只需覆盖会话/治理侧的增量，并在报告里引用它的 anchor id，不要重复写。

### 6. 合并 / 去重 / 删除（"合并旧的点"）
- 新发现先找已有同主题条目/卡片：**更新它，而不是新建重复**。
- 同一事实在治理文件、lesson、memory 卡多处出现时只留一处全文，其余瘦身为指针（`[[name]]` / 文件名互链）。
- 删除已被证伪、已过时、或已被更精炼条目取代的 memory 卡（连同 `MEMORY.md` 索引行）。
- 治理文件内重复表述合并为一条。

### 7. 补结构性缺口（"补充新的点" + 感知一致性）
- **双运行时 skill 一致性**：用户同时用 Codex 与 Claude Code。项目 skill 唯一源在仓库 `/Users/user/symphony/workflows/kyuyo-backend/skills/<name>/`，`~/.codex/skills/<name>` 与 `~/.claude/skills/<name>` 都应是指向它的软链接。对账时若发现某侧缺失，用 `ln -s` 补齐，禁止 `cp -R` 复制。**既定例外**（用户 2026-07-08 拍板保留，不要替换）：Codex 侧 `doc`/`pdf`/`pptx` 保留真实目录副本——对账时只需 `diff -rq` 核对与仓库源是否漂移，漂移了报告给用户裁决，不擅自动。见 `[[dual_runtime_skill_parity]]`。
- **失效引用**：治理文件 / memory 卡里引用的文件、类、skill、路径，验证仍存在；失效的就修或删。
- **新增可复用流程**：本周若出现"值得每次照做"的新流程，沉淀为治理文件条目或新 skill。

### 8. 记忆卫生（agentmemory 每周维护）
- `memory_diagnose`：清理卡死的 action、孤儿状态（票已合并但 action 未置 done 的，先补状态）。
- 对已完结但漏归档的票补跑 `memory_crystallize`（日常漏掉的兜底）。
- `memory_consolidate`：跑一遍分层整理管线（working → episodic → semantic → procedural）。
- 收尾 `memory_snapshot_create` 打周快照留痕。
- 删除 agentmemory 数据（governance_delete 级别）前必须在报告里列明并获用户确认，diagnose 的自动修复除外。

### 9. 应用变更
- 改 `AGENT_WORKFLOW.md`：保持小节骨架；只在对应小节内增/并/删，逻辑变更同步刷新相关条目（禁止局部改而总述未改）。流程层保持精简，业务规则不往这里堆。
- 改 `KYUYO_DOMAIN.md`：按其小节增量补充；每条要可被代码验证、标注"以代码为准"。新增业务域时加新小节。
- 改 `CODING_RULES.md`：实现/命名/错误码/注释/日志/测试/Review/风格类纠正落这里。
- 改 memory 卡：每文件一条事实，frontmatter `metadata: type: user|feedback|project|reference`；feedback/project 正文跟 **Why** + **How to apply**；`[[name]]` 互链；增删同步维护 `MEMORY.md` 一行指针（`- [标题](file.md) — 钩子`）。
- 最后在 `retro_history.md` 顶部追加一条 `## <yyyy-MM-dd>` 记录（票号样本 / 改了哪些活文件 / lesson 升格淘汰 / 合并删除 / 卫生结果 / 待办）。这是唯一写 retro_history 的地方。

### 10. 自检 + 中文报告
- 通读改后的治理文件与 `MEMORY.md`：无自相矛盾、跨文件指针有效、memory 索引与卡片一一对应、无失效引用；业务规则未误堆进流程层；**活文件均不引用 `retro_history.md`**。
- 输出中文报告，固定结构：
  1. **本周做了什么**（按票号/主题聚合 + 反复出现的问题）。
  2. **流程层（AGENT_WORKFLOW.md）变更**：增/并/删了哪些条目、为什么。
  3. **业务层（KYUYO_DOMAIN.md）扩充**：本周新增/细化了哪些模块、代码位置、业务规则——单列。
  4. **CODING_RULES / memory 卡变更 + 合并的旧点**。
  5. **lesson 生命周期**：升格了哪些、淘汰了哪些、留池观察哪些。
  6. **本次记忆写入**：新写入的 memory / lesson 条数 + anchor id + 验收 query 命中情况；同期跑过 `weekly-ticket-retro` 时引用其 anchor。
  7. **记忆卫生结果**：diagnose 修复项、补 crystallize 的票、consolidate/snapshot 执行情况。
  8. **修复的感知缺口**：失效引用、双运行时不一致等。
  9. **retro_history 追加记录** + **下周默认检查项**。

## 安全红线

- 不要无证据地删"难得沉淀的硬规则"——只有证伪、过期、或被更优条目取代才删，并在报告里说明理由。
- 不做语义级整篇重写治理文件；做"增量并条 + 刷新过期 + 补缺口"。涉及会改变现有纪律语义的大改，先在报告里列出、让用户拍板，不要静默重写。
- agentmemory 的破坏性清理（成批删除 memory/observation）必须先列清单待用户确认；lesson 单条淘汰按步骤 4 裁决即可。
- 不把完整转录、完整 CSV、完整测试资源带进上下文；检索只取片段。
- 凭证、API key 等敏感值留在原配置文件里引用，不复制进 memory/治理文件正文。
