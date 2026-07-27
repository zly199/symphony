# retro_history — 复盘审计日志（仅 weekly-retro skill 读取）

**本文件只在 `weekly-retro` skill 运行时读取，平时做任务不引用、`AGENTS.md` 与其他规则文件也不引用本文件。** 复盘的"直接结果"应直接更新活文件（`AGENTS.md` 流程规则 / `ai-workspace/governance/KYUYO_DOMAIN.md` 业务知识 / `ai-workspace/governance/CODING_RULES.md` 代码·测试·review 规则 / memory），本文件只留**关键变更记录**，让"哪次复盘改了什么、为什么"有迹可循，并供下次复盘对照避免重复推导。

格式：每次复盘追加一条 `## <yyyy-MM-dd>` 记录，含「滚动票号样本 / 改了哪些活文件 / 合并删除 / 待办」。最新在上。

---

## 2026-07-16

**本轮首次采用「先 weekly-ticket-retro 后 weekly-retro」双 skill 编排**（本次会话新建 `weekly-ticket-retro`，并给 `weekly-retro` 增设"记忆写入"必做步骤）。

**滚动票号样本（2026-07-09 ~ 2026-07-16，Backlog 窗口内 108 张，A 类深挖 10 张）**：`KYUYO_NEW-4611`/`4608` 手続帳票の事業所名不正（取错 `dto.enterprisePlace` + `findV2` 返回 List 直拼）、`KYUYO_NEW-4607` 住民税 CSV 二段各自重扫致设定侧写入非法行、`KYUYO_NEW-4622` enum NPE、`KYUYO_NEW-4617` `toMap` 重复键、`KYUYO_NEW-4609` 帐票线程池超时按 CPU 核数误算、`KYUYO_NEW-4600` 循环检查漏传未保存的 `paymentDetailSetting`、`KYUYO_NEW-4613` 仕向口座默认值（1.0/1.5 限定 + 9999/9999 魔法码）、`KYUYO_NEW-4615` 履历管理 OFF 静默漏人却标完了（调查中未修）、`KYUYO_NEW-4547` 表示项目扩展点四点套。`KYUYO_NEW-4589` 判定无沉淀（仅改测试）。

**活文件变更**：
- `KYUYO_DOMAIN.md` §4 新增「社会保険手続（procedure：定時決定/随時改定）」代码位置地图——本周 7 张票集中于此却是地图空白；§7 新增两条陷阱：手続帳票の事業所名双来源（4611/4608）、履历管理 OFF 时従業員反映静默漏人且仍标完了（4615，标注未修正）。
- `CODING_RULES.md` §1 新增「本番データ前提の防御三点」（enum Yoda 比较 / `toMap` merge function / 并行超时按实际并行度）——由 4622·4617·4609 同周三连发收敛，属"每次写代码都适用"的硬规则，故升格出 lesson 池。
- `/Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md`：修正被证伪的说法——`memory_save` 的 `project` 参数实测不生效（见下）。

**lesson 生命周期**：本轮新增 9 条（ticket-retro 8 + agentmemory project 缺陷 1），升格 1 组（防御三点 → CODING_RULES §1，原 3 条 lesson 保留作 recall 入口，未删），淘汰 0，留池观察 8。

**记忆写入**：memory 8 条（anchor `mem_mrn9cklu_306f4130b21c`）+ lesson 9 条（anchor `lsn_9cf2b1729185724e`）。验收 4 个 query 全部命中。

**记忆卫生**：`memory_diagnose` 报 **fail 1 项——185/185 memory 无 project scope**（`memory_save` 的 project 参数不落库，`memory_heal` dryRun fixed:0 修不了，需 HTTP `POST /agentmemory/migrate {"step":"infer-memory-projects"}`，已升级给用户）；孤儿 action `KYUYO_NEW-4597` 已置 done；`memory_consolidate(semantic)` 出 10 条 newFacts（无参全量跑会超时，改按 tier 跑）；`memory_snapshot_create` 未执行——环境未开启（`SNAPSHOT_ENABLED=true` 未设），非本轮引入。

**发现的规则违反（需用户知悉）**：`CODING_RULES.md` §1 早已写明"取全量必须 `findBatch`、禁用 `find`"（并有 memory 卡 `cosmos_use_findbatch_not_find` 佐证、用户曾定性为"非常严重"），但本周 `KYUYO_NEW-4613` 的 `PaymentEventApi`/`BonusEventApi` 仍用了 `PaymentAccountAllocationRuleService.singleton.find(host)` 取全量仕向口座振分ルール（`Condition.limit` 默认 100，超 100 条静默截断）。规则、卡片、正文三处俱全却仍被违反——说明缺口不在沉淀而在"写代码时未查"。本轮据此**未**对该卡做指针化瘦身。

**待办/观察**：① memory project scope 的 migrate 端点需用户决定是否执行。② 4613 的 `find` 用法待用户裁决是否改 `findBatch`。③ 上轮记录的"retro_history 连续 4 次断档"现象本轮未复现（07-06 与本轮均正常追加）。④ 热点域 `procedure` 建议列入下次 `DOMAIN_INGEST_PROMPT` 域摄取候选（本周 7 张票，仅 §4 有地图、尚无原子化摄取）。

---

## 2026-07-06

**滚动票号样本（最近一周，2026-06-29 ~ 2026-07-03）**：`KYUYO_NEW-4548` 確定済み給与/賞与 CSV 従業員情報固化于确定时点（组织变更不应反映到已确定结果）、`KYUYO_NEW-4469` 通勤手当整体迁移到 v2（计算引擎下沉 common + v2 service/controller/CSV 四步 + openapi modules/v2 相对引用深一层踩坑）、`KYUYO_NEW-4522` 算定基礎届雇用区分/給与形態双来源展示陷阱（JobInformation vs MonthlyPayroll.salaryType）、两起事故级幻觉复盘（`44dbc76b`/`04:58` session，虚构用户轮次要求删 DTO）。

**发现的流程异常（非本轮引入，需用户知悉）**：`list_sessions` 显示 2026-06-08/06-15/06-22/06-29 存在 4 次「Kyuyo weekly retro」会话，但 `retro_history.md` 最后一条记录停在 2026-06-05——中间 4 次复盘均未追加审计记录（对应活文件本身在此期间确实被持续更新，说明复盘/日常任务里的「事故直接改活文件」路径在正常工作，只是 weekly-retro 收尾的记录步骤连续 4 次被跳过，原因不明，本轮不作猜测）。本轮已正常追加，后续若再出现空档需要用户关注。

**活文件变更**：
- `KYUYO_DOMAIN.md` §1 补充"v1 功能整体迁移到 v2 的标准步骤"（四步法，来自 4469）；§4 模块地图新增"通勤手当（Commute Allowance）"代码位置；§7 新增两条业务陷阱——通勤手当无履历时间切面（与 v2 給与计算 baseDate 语义脱节）、確定済み給与/賞与 CSV 従業員情報固化规则（PayrollBase 快照 + 字段级回退）。
- `CODING_RULES.md` §1 新增 openapi `modules/v2/*.api.yml` 相对引用深度规则（`../../` 而非 `../`），把原本只在 memory 里的 4469 踩坑规则升格为正文。
- memory：`openapi_modules_v2_relative_refs.md` 瘦身为指针卡（正文已入 CODING_RULES.md）；修正 3 张 memory 卡里的过期路径引用（`feedback_compact_arg_wrapping.md`/`feedback_delete_dead_defensive_code.md` 的 `docs/agents/CODING_RULES.md` → `ai-workspace/governance/CODING_RULES.md`；`feedback_sysanalysis_diagrams_complete.md` 的 `docs/tickets`/`docs/systemAnalyse` → `ai-workspace/docs/...`，`AGENTS.md §0` → `AGENTS_PROJECT.md` Documentation Rules）；同步刷新 `MEMORY.md` 对应索引行。
- 双运行时缺口修复：`~/.codex/skills/` 缺失项目 skill `excel-to-html`（`~/.claude/skills/` 与 `/Users/user/symphony/workflows/kyuyo-backend/skills/` 都有），已 `cp -R` 补齐；核对后 `/Users/user/symphony/workflows/kyuyo-backend/skills/`（12 个项目 skill）与 `ai-workspace/registry/skills.json` 完全一致，Codex/Claude 两侧个人目录现已对齐（`weekly-retro` 按既定例外仍只在 Claude 侧）。

**合并/删除**：无删除条目；本轮均为"过期路径纠正"与"正文升格后瘦身指针卡"，无内容被证伪。

**待办/观察**：① retro_history 追加步骤连续断档 4 次的现象已记录在上面，暂无法确定根因，下次复盘若仍断档需要向用户升级。② `KYUYO_NEW-4469` 通勤手当履历切面缺口是产品侧待确认事项（不是代码 bug），后续涉及通勤手当历史变更/未来预约的票要先跟业务对齐口径，见 `KYUYO_DOMAIN.md` §7。

---

## 2026-06-05

**滚动票号样本（最近约两周）**：`KYUYO_NEW-4160/4163/4288/4315/4317/4390` 履历化·基准日·给与2.0 设定保存、`KYUYO_NEW-4313/4318` 导入/数据反转修复、`KYUYO_NEW-4286/4299/4304/4405` hotfix·再执行·一括削除、`KYUYO_NEW-4235/4262` 性能与历史数据生成、`KYUYO_NEW-3536` 标准赏与额 backfill（分页 cursor 漏修事故）、`SC_DEVOPS-8936` CI 依赖缓存治理。

**活文件变更**：
- 建立知识分层：根 `AGENTS.md`（流程/工作法）+ `ai-workspace/governance/KYUYO_DOMAIN.md`（业务/系统）+ `ai-workspace/governance/CODING_RULES.md`（代码相关全部规则）+ 本审计日志；agent 配套文件统一收进 `ai-workspace/governance/`。
- `KYUYO_DOMAIN.md` 从 docs 吸纳并代码验证：core Public client（Member/SheetContent）、労働日・休日 独自休日 替换+继承双语义陷阱、系统架构与全局约定（多租户/分层/DTO/校验/MDC，来自 README）、数据迁移模块（来自 Migration_zh）、补 `kyuyo-base-adapter` 模块。
- `AGENTS.md` 瘦身为纯流程（§0–§5：工作流/默认检查项/检索/交付/分析输出/完成标准）：把"一切跟代码打交道的规则"（实现原则、命名、错误码、注释、日志、测试编写+编译执行验证、Review）全部下沉到新建的 `CODING_RULES.md`（由 `CODING_STYLE.md` 改名扩容，10 节）。判据：要不要碰代码/测试/review→进 CODING_RULES，否则留 AGENTS。补双运行时 skill 必备、测试方法名英文。
- 文件归位：agent 配套文件从仓库根移进 `ai-workspace/governance/`（随 docs/ 本地排除）；`RETRO.md` 改名 `retro_history.md` 并改造为"仅 weekly-retro 读写、活文件不引用"的审计日志；复盘结果直接进活文件。
- 感知缺口修复：`system-analysis-review` skill 补齐到 Claude 侧（原仅 Codex）。
- **系分出图 / mermaid 渲染修复（KYUYO_NEW-4390 为例）**：4390.html 自带内联 mermaid 脚本与全局 docs.js 双初始化→整图空白，且节点标签含 `()/+※:` 未加引号→解析失败，且只画 1 张图不符系分要求。已：删内联脚本（统一 docs.js）、标签加引号、补 sequenceDiagram(系统协作)+stateDiagram(確定時履歴)。规则固化进 AGENTS.md §0（mermaid 渲染统一规则 + 系分必须成套出图、分析过程不能漏）与 `system-analysis-review` 标准（新增"省图/不可渲染=打回"审计信号，两运行时已同步）。系分指导原则源自 `ai-workspace/docs/systemAnalyse/系分入门…pptx`，已蒸馏在 `pptx-system-analysis-standards.md`。

**合并/删除**：memory 领域地图卡瘦身为指向 `KYUYO_DOMAIN.md` 的指针；分页 cursor 知识收口到 KYUYO_DOMAIN §5 + AGENTS 检查项 + 2 张 memory 互链；CODING_STYLE 内容并入 CODING_RULES 后删除旧文件。

**待办/观察**：① 自动模式下 `search_session_transcripts` 不可用，weekly-retro 自动跑时降级到 docs HTML + session 标题 + memory。② 其余历史 ticket HTML 若也只有单图/缺图，后续按系分标准逐步补齐（本轮只修了被点名的 4390）。
