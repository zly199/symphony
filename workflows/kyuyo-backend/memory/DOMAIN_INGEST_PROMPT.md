# 域理解摄取 — 单域作业 prompt

> 用法：新开一个 session，把本文件**整篇**贴进去，末尾指定要做的域名。
> 例：`按此作业。本次域：yearAdjustment`

---

## 你的任务

把 kyuyo-backend 的**一个业务域**拆成**一批原子记忆 + 一批 lesson** 写入 agentmemory，供未来所有会话检索。
这是"项目理解"的语义记忆，不是某张票的情景记忆。

**核心纪律：颗粒度 = 一个事实一条，不是一个域一条。**
一个域动辄几万行代码；压成 1 条"域架构"总览等于把 95% 读到的知识当场扔掉——你花的 token 换来的是一次性摘要，不是沉淀。**读一次代码不可省，但要把它挖成 N 条，而不是一句话。**

---

## 两个载体，按知识类型分流（重要）

同一个域的知识分布在**两个子系统**里，各写各的，别混：

| 知识类型 | 载体 | 工具 | 语气 |
|---|---|---|---|
| **结构事实**：继承树/泛型约束/平行结构/分发点/框架/跨域边/v1↔v2 关系/数据集约树 | **memory** `type=architecture` | `memory_save` | 陈述"是什么" |
| **行为/业务规则**：不显然的计算规则、特例（如某年度专属分支）、排序规则、校验语义、状态门 | **memory** `type=fact` | `memory_save` | 陈述"规则是什么" |
| **陷阱/漏改/操作前提**："改 X 要连带动 Y，别只改一侧"、"别用近似值替代 baseDate"、"这个字段确定后固化不随现值变" | **lesson** | `memory_lesson_save` | 祈使"改前先确认…" |

**为什么陷阱走 lesson 不走 memory**：lesson 带 confidence + 衰减 + 命中强化，能在"正要改这块"时被 `lesson_recall` 顶到眼前并随复用增强；结构/规则是稳定地图不该衰减，留在 memory。实测（2026-07-16）lesson 的 `project` 过滤生效、CJK+ASCII 混合查询能命中。

**不在本摄取范围**：`crystals`（`memory_crystallize` 压缩的是**已完成动作链**，属每张票的干活流，域摄取没有动作链可压，别硬造）；`insights`（consolidation 自动从 memories/lessons/crystals 合成，不手写）。

---

## 颗粒度判据（不设条数目标，靠两道测试收敛）

**不要预设"一个域该有几条"。** 条数是涌现的：CRUD 重的域可能 8 条，规则/计算重的域（cal）可能 30-40 条。对每个候选事实问两道题：

1. **红线**：`find`/扫一眼能否重算？能 → 不写（如"XxxService extends CRUD 做 XX 的 CRUD"）。
2. **自立性**：它能否作为"改动前要知道的一条事实"单独成立？能 → 独立一条；否则并进相关机制条。

**拆分收敛启发式**：只要拆出来的两半**各自仍是"不可推导且自立"**，就继续拆；一旦再拆会掉进下面任一反模式，就停。

**反模式（越界就退回）**：
- ❌ **样板一类一条**：给纯 CRUD/boilerplate 类各存一条 → `find` 就有，反而在 smart_search 里把承重条挤下去，稀释检索。
- ❌ **碎片化机制**：把一个机制（如"过不足額反映"）按参与类拆成 5 条，导致**没有一条能单独讲清它**。机制要的是"怎么运作"，拆碎了不可用。

> 「原子」≠「最小」。单位是**一个不可推导、且能单独成立的事实**，它可以横跨 3 个类。

### 逐单元清单（一个域读完后逐项判断，有就各存一条）

| 单元 | 归哪个载体 | 例（yearAdjustment） |
|---|---|---|
| 数据主体继承/集约树 | memory architecture | Procedure→Member→8 结果 CosmosBean |
| 每个抽象基类 / 平行结构 | memory architecture | report 三层框架；給与/賞与 4 点套 |
| 每个分发点 | memory architecture | AppService 单件vs多件双引擎；fileBatchDownload switch(Type) |
| 每条跨域边 | memory architecture | 過不足額→給与賞与(getPayrollService)；AfterMemberChange 副作用 |
| **每条不显然的业务规则/特例/排序/校验** | **memory fact** | setMemo 第5人以降mynumber拼备考；setOriginalInfos 2025特定親族特例；homeLoan canDeduction+排序 |
| 每个状态机 / 关键枚举门 | memory architecture/fact | DeclarationStatus VERIFIED 门 |
| v1↔v2 关系 | memory architecture | 本体 v1-only、v2 仅 3 桥接文件 |
| **每个陷阱 / 漏改 / 操作前提** | **lesson** | 两个 reflect 别混；只改賞与漏給与；EnterprisePlace 未実装 |

> **行为/业务规则层最容易被压掉，也最值钱**——它是开票时最易做错的东西。别只写结构骨架，把不显然的规则一条条落下来。

### 让节点连成边：共享 ASCII 类名锚点

图的边来自**跨记忆的概念共现**。相关的原子记忆要**故意复用同一批类名**当 concepts（`YearAdjustmentMemberService`、`PayrollBase`、`EventStateMachine` 在多条里重复出现 → 抽取时织成子图，而非孤立节点）。lesson 用 `tags` 达到同样效果。

---

## 背景约束

### ASCII 锚点决定能不能被查到

`concepts`/`tags` 里**必须**有足量 ASCII：类名、包名、域名、枚举名、方法名。中文/日语负责表达理解但**不能只靠它们**。每个关键概念尽量给 ASCII 对应物。

> 早期实测服务端 BM25 对纯 CJK 分词失效；现已确认 npx 包内装有 `@node-rs/jieba`+`tiny-segmenter`，CJK 分词可能已生效，开工时用一个纯中文独有词 A/B 重测一次。无论如何 ASCII 锚点无害，保留。

### 检索与图的其它事实

- **验收指标：`memory_smart_search` + `memory_lesson_recall` 能命中 + 图密度上去了**。
- **`memory_recall` 查不到 memory，只查 observation。** 不要用它验收。
- **`memory_save` 的 `project` 参数实测无效**（2026-07-16：`memory_diagnose` 报 `185 of 185 latest memories have no project scope` 且 `memory_save` 返回值里根本没有 project 字段；`memory_heal` 修不了，要 HTTP `POST /agentmemory/migrate {"step":"infer-memory-projects"}`）。照传即可（无害），但**别指望 memory 能按 project 过滤**——这使 `concepts` 里的 ASCII 锚点成为 memory 侧唯一可靠的检索抓手，更要认真写。lesson 侧的 `project` 过滤确实生效，照常传。
- **不要用 score 判断好坏**（RRF 名次分），只看顺序。
- graph-extract 异步（几分钟一批，挂 Stop/SessionEnd）。存完 1-2 分钟查图没增密是正常的。
- 图节点数**不是刷出来的目标**（跑几百条 find 也能堆观察节点但无知识）；但**把几万行的域只存 1 条 / ~5 节点是更严重的欠采集**。节点数应**匹配真实捕获的知识量**。

---

## token 效率（这是"慢"的真正来源）

浪费不是"读代码"，是**"读完只存一句摘要"** 和 **"把文件体灌进上下文"**。

1. **绝不 `cat`/整文件 Read 进上下文**。会话上下文是累积复利：一份 34KB 文件读进来，之后每一轮都为它重复付费。
2. **结构侦察只用返回小输出的命令**（单域压到 1-2KB）：
   ```
   grep -rhE 'public (abstract )?(class|interface|enum) .*(extends|implements)' <域路径> | sed -E 's/\{.*//'
   grep -rhoE '@CosmosBean\("[^"]*"\)' <dto路径>
   grep -n '<域>' KyuyoRoutesV1.java | head
   for m in kyuyo-v1 kyuyo-v2 kyuyo-common; do printf "$m="; find $m -path "*<域>*" -name '*.java' -not -path '*/target/*'|grep -c .; done
   ```
   继承树+CosmosBean+文件数就够写"继承/平行/持久化/版本边界"好几条，**不用读函数体**。
3. **只在少数枢纽点读函数体**（区分同名机制、抽业务规则时）。拿不准两行 grep 确认，**绝不臆造**。
4. **读一次，挖 N 条**：每读到一个机制/规则立刻各存一条，别攒到最后写一大条。
5. 不要用子 agent farm（除非用户要求），不要为堆节点跑无意义 find。

---

## 作业单元

**一个业务域，跨 v1 / v2 / common 一起做**（v1↔v2 关系最值钱，分开做会丢）。
**一个 session 只做 1-2 个域**，做深、做全颗粒 > 做多。大域（yearAdjustment/cal/basicSetting）单独一个 session。

## 步骤

1. `git status` 确认干净；读 `AGENTS.md` 与 `ai-workspace/governance/KYUYO_DOMAIN.md`（§4 已覆盖的只补深度）。
2. 廉价结构侦察（上面命令），得继承树/平行/分发/路由/CosmosBean/v1↔v2 文件数。输出保持小。
3. 按「逐单元清单」逐项判断有没有这一项，用两道测试收敛颗粒。枢纽点才 Read 函数体、抽业务规则。
4. 分流写入：结构+规则 → `memory_save`（一条一事实）；陷阱/漏改 → `memory_lesson_save`（带 context + ASCII tags + confidence~0.6-0.7）。相关条复用共享锚点。
5. **验收**：
   - 3-4 个真实业务问题查 `memory_smart_search`，确认命中相应原子条。
   - 至少 1 个陷阱类问题查 `memory_lesson_recall(project="kyuyo-backend")`，确认命中 lesson。
   - 隔几分钟 `memory_graph_query("<域名>")`，确认节点/边随这批增密。
6. 在 `DOMAINS.md` 勾掉该域，记 **memory 条数 + lesson 条数 + anchor id**。

## 模板

**memory（原子事实）**
```
project: kyuyo-backend
type:    architecture | fact
concepts:<域名>,<本条主角类>,<相关类×1-3(别条也提到的,用于连边)>,<模式名ASCII>
files:   <本条真正相关的 1-4 个文件>
content: <一句点题:哪个机制/规则> + <2-5 句具体形状> + <改動予測 或 规则边界>。
```
一条 3-6 句。**宁可十几条各自锋利，不要一条什么都写。**

**lesson（陷阱/漏改）**
```
project:    kyuyo-backend
context:    改 <域> 的 <某类逻辑> 时
tags:       <域名>,<类名ASCII>,<陷阱关键词>
confidence: 0.6-0.7
content:    <祈使:改前先确认X;只改一侧会漏Y;别用Z替代>。
```

## 参考样板

`yearAdjustment`（49 类）：**双载体完整样板**，21 memory（结构层 13 条 anchor `mem_mrn7jzvs_6d68bc875961` + 业务规则层 8 条）+ 6 lesson（anchor `lsn_206358bb96ccc076`）。
> 该域分两轮做成：1轮目只出结构骨架，2轮目专门回补行为/业务规则层与 lesson 层。**教训：一轮里"读代码"和"挖规则"要同时做**——1轮目读过的枢纽类（MemberService/AlertInfoService）当时就该顺手把 canSetTarget、familyCheck 这类规则挖出来，攒到2轮目等于同一批文件读两遍。
> 规则层长什么样（可作为其它域的标尺）：対象設定の可否門(canSetTarget)、扶養家族の4件枠+3段ソート(familyCheck)、年度分岐(2025 の特定親族/様式改定、getExcludedClassificationIds)、レンジ検証+再計算副作用(setHomeLoanInfoHand)、備考欄の連番規則(setMemo)、CSV の黙値書換(CsvExRule 2実装)、部分スキップ門(statusCheck)。
```
memory_smart_search("yearAdjustment executeAnnualExcessReflect PayrollBase two reflect flows")
memory_lesson_recall("yearAdjustment reflect 漏改")
memory_graph_query("yearAdjustment")
```
`calPattern`（`mem_mrn6gl3m_063ca1f56bb8`）是**旧式单条样板**，颗粒度已过时，别再照它一域一条。

## 边界

- **不要关联票号。** 票暴露的**稳定陷阱**可以写成域的 lesson（不提票号）。
- 与 `KYUYO_DOMAIN.md` 冲突时以代码为准，并在回复里指出冲突。
- 不确定的地方**标注不确定**，不要编。写"未确认 XxxService 是否仍被调用"比编结论强。
