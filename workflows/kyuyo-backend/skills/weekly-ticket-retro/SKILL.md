---
name: weekly-ticket-retro
description: "Use when the user asks for a weekly ticket retro / 票复盘 / 周票总结 on kyuyo-backend — pull the past week's Backlog tickets (KYUYO_NEW), analyze each substantive one against the actual code, and ingest the durable knowledge into agentmemory as atomic memories + lessons. This is the ticket-side counterpart of weekly-retro (which does governance files, lesson lifecycle and memory hygiene): weekly-ticket-retro mines the ticket stream itself for domain facts, recurring defect patterns and traps, then writes them into agentmemory. Trigger on 'ticket retro', '这周的票复盘', 'backlog 周复盘', 'summarize this week's tickets and remember them'."
---

# Weekly Ticket Retro — 从一周的票里挖知识写进记忆

**目标**：把最近一周 Backlog 上真正推进过的票，逐张分析成"下次开票时用得上的知识"，写进 agentmemory。
不是做工作量汇报，是做**知识沉淀**——票是原料，产出是可检索的原子记忆与 lesson。

输出与交付一律用中文（见 `[[feedback_reply_in_chinese]]`）。

## 与 weekly-retro 的分工

| | weekly-retro | weekly-ticket-retro（本 skill） |
|---|---|---|
| 原料 | agentmemory 会话/lesson/audit + 治理文件 | **Backlog 票流**（+ 票对应的代码/MR） |
| 产出 | 治理文件重构、lesson 升格淘汰、记忆卫生 | **agentmemory 原子记忆 + lesson** |
| 视角 | "我这个 agent 哪里反复犯错" | "这个系统这周暴露了什么业务事实与坑" |

两者可同一天连着跑：**先 ticket-retro（产出新 lesson/记忆），再 weekly-retro（裁决升格与卫生）**。这个顺序不要反——反了这周新挖的 lesson 会等一周才被裁决。

## 记忆写入纪律（本 skill 的核心，必读）

**完整纪律见 `/Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md`——开工前读一遍，本节只写票场景的差异。**

从那份文档继承的硬约束：

- **颗粒度 = 一个事实一条。** 一张票压成 1 条"这票干了啥"的摘要 = 把读到的东西当场扔掉。读一次，挖 N 条。
- **双载体分流**：结构事实/业务规则 → `memory_save`（`type=architecture` / `type=fact`）；陷阱/漏改/操作前提 → `memory_lesson_save`（confidence 0.6-0.7）。
- **ASCII 锚点**：`concepts`/`tags` 必须含类名/方法名/枚举名等 ASCII，相关条**故意复用同一批类名**以便连边。
- **红线测试**：`find`/扫一眼能重算的不写；不能自立成"改动前要知道的一条事实"的不单独成条。
- **不臆造**：票描述与代码冲突以代码为准；不确定就标注"未确认"。

**票场景特有的差异（与域摄取不同的地方）**：

1. **票是情景，知识是语义——要做提纯。** 票里 90% 是一次性的（谁报的、哪个客户、什么时候发布），只有沉下来的那部分才写记忆：这个字段的业务口径、这类计算的边界、这个改动为什么会漏另一侧。
2. **`memory_save` 正文不写票号，但 `concepts` 里带一个 `KYUYO_NEW-XXXX` 作为溯源锚点**——这样既能反查出处，正文又是与票解耦的通用事实。**lesson 正文和 tags 都不带票号**（lesson 是跨票复用的倾向性经验，绑票号会让它显得只适用于那一次）。
3. **bug 票最值钱**：一张 bug 票 = 一个"系统的真实行为与预期不符"的样本。要挖的是**根因层的事实**（"这里 A 与 B 的口径本来就不一致"），不是"改了某一行"。
4. **同类票聚合成一条**：一周里 3 张票都是"某帐票的事业所名取错"，不要写 3 条，写 1 条根因记忆 + 1 条 lesson。

## 票的分层（100 张票不可能每张都深挖）

一周 KYUYO_NEW 的更新量在 100 张量级，**必须先分层再投入**：

- **A 类·深分析（逐张做，一般 5-15 张）**：`【backend】` 且是 bug 修正 / 調査 / 改善タスク，且本周状态推进到 Resolved/Closed 或有实质讨论。这些是知识密度最高的。
- **B 类·轻扫（只看标题+状态，聚合）**：`【frontend】`、新規開発中的大机能票（还没定型，等做完再挖）、仍是 Open 没动过的。产出最多一句"本周在推进 X"，不写记忆。
- **C 类·跳过**：`【test】`、发布/リリース票、テスト票、纯任务分配票。**不写记忆**，只在报告里数个数。

分层判据先跑一遍再动手，别边拉边挖。

## 工作流

### 1. 圈定窗口 + 拉票
```bash
cd /Users/user/symphony/workflows/kyuyo-backend/skills/backlog-api
python3 scripts/backlog_api.py issues --project-key KYUYO_NEW \
  --updated-since <7天前 yyyy-MM-dd> --sort updated --order desc --count 100 --brief
```
- 默认窗口 = 最近 7 天按 `updated` 过滤；用户指定窗口就用用户的。
- **必须带 `--brief`**，raw payload 会灌爆上下文。
- 命中满 100 条时用 `--offset` 翻页确认是否被截断，并在报告里说明。

### 2. 分层
按上一节把票分成 A/B/C 三类，先输出一份"A 类清单（票号+一句话）"再往下做。A 类超过 15 张就按"知识密度"取前 15，其余降 B 并在报告里说明。

### 3. 逐张分析 A 类票（读一次，挖 N 条）
每张票：
1. `python3 scripts/backlog_api.py issue --issue-key KYUYO_NEW-XXXX` 看详情；讨论关键的再 `comments --issue-key ...`（不加 `--full`）。
2. **必须落到代码**：用票里的类名/画面名/字段名 grep 出实现位置，确认"票说的事在代码里长什么样"。只读票不读代码 = 只能写出复述型记忆，没有价值。
   - 已合并的票可 `git log --oneline --all --grep=KYUYO_NEW-XXXX` 找到 commit，`git show --stat` 看改了哪些类——**看 stat 与关键 hunk，别整 diff 灌上下文**。
3. 边读边问：这张票暴露了**什么本来就存在、下次还会用到**的事实？按双载体当场写入，别攒到最后。
4. 挖不出可沉淀知识的票（纯环境问题、误报、数据订正）——**明确不写**，报告里记一句"无沉淀"。这不是失败，是正确判断。

### 4. 横向找模式（票流特有价值）
逐张做完后回看整周：
- 反复出现的缺陷类型（同一域反复出 bug / 同一类口径反复搞错）→ 写 lesson。
- 反复被碰的类/域 → 说明是热点，值得列入下次域摄取候选，记进报告。
- 与 `ai-workspace/governance/KYUYO_DOMAIN.md` 冲突的事实 → 报告里点名（治理文件的修改交给 weekly-retro，本 skill 不改治理文件）。

### 5. 验收
- 3-4 个"下周可能真的会问"的问题跑 `memory_smart_search`，确认命中本次新写的条目。
- 至少 1 个陷阱类问题跑 `memory_lesson_recall(project="kyuyo-backend")`，确认命中新 lesson。
- 查不到就回去修 `concepts`/`tags`（多半是 ASCII 锚点不足），不要放着不管。

### 6. 中文报告
1. **窗口与票量**：时间窗、总数、A/B/C 各多少、是否被 100 上限截断。
2. **A 类逐张**：票号 + 一句话结论 + 本票写了几条 memory / 几条 lesson（或"无沉淀"及理由）。
3. **横向模式**：本周反复出现的缺陷类型、热点域。
4. **记忆写入汇总**：memory 条数 + lesson 条数 + anchor id（供 weekly-retro 对照）。
5. **验收结果**：哪几个 query 命中了什么。
6. **移交 weekly-retro 的待办**：与治理文件冲突的点、建议升格的 lesson、建议做域摄取的热点域。

## 边界

- **本 skill 不改治理文件、不改 memory 卡**——那是 weekly-retro 的职责。冲突与升格建议只写进报告移交。
- Backlog 只做读操作（`projects`/`issues`/`issue`/`comments`）。**不改票状态、不发评论**，需要写操作时先问用户。
- 不把票的完整 JSON、完整 diff、完整转录带进上下文；只取片段。
- 客户名、domain 名、个人信息等不写进记忆正文——业务口径要，具体客户数据不要。
