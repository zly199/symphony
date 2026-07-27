# 逐 session 作业队列 — 直接复制粘贴

从上往下做，一次一条，一条一个新 session。做完在 [DOMAINS.md](DOMAINS.md) 勾掉。
共 **36 条**（覆盖 44 个待做域；`calPattern` 已完成作为样板；末尾 9 个单类域打包成 1 条）。

括号里的数字 = 该域 java 文件数（v1+v2），用来估这个 session 要花多少力气。

---

## P0 — 先做这 4 条

```
1  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：yearAdjustment
2  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：cal
3  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：basicSetting
4  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：report
```
<sub>1=年末調整(49)　2=給与計算(46)　3=基本設定(45)　4=帳票(26)</sub>

> **做完这 4 条先停。** 隔几天真碰到相关任务时，看看这些记忆有没有帮上忙，再决定要不要往下铺。

## P1 — 9 条

```
5  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：info
6  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：insurance

7  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：notificationOfChange

8  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：paymentEvent

9  读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：procedure

10 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：dataSheet

11 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：kyuyo
12 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：payment
13 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：commuting


```
<sub>5=従業員情報(28)　6=社会保険(23)　7=変更届(16)　8=支給イベント(16)　9=定時決定/随時改定(12)　10=(14)　11=(12)　12=支給項目(10)　13=通勤手当(14，KYUYO_DOMAIN §4 已写得很细，只补深度)</sub>

## P2 — 22 条

```
14 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：process
15 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：task
16 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：gradeInterval
17 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：deduction
18 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：payroll
19 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：paymentDeductionSetting
20 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：transfer
21 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：masterTable
22 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：attendanceLink
23 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：permission
24 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：base
25 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：bonusCal
26 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：attendance
27 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：param
28 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：attachment
29 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：reportForm
30 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：snapshot
31 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：member
32 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：memberSetting
33 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：importError
34 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：migration
35 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。本次域：group
```
<sub>14=(9) 15=(8) 16=等級(8) 17=控除(7) 18=(7) 19=(7) 20=振込(6) 21=(6) 22=勤怠連携(5) 23=権限(5) 24=(5) 25=賞与計算(4) 26=勤怠(4) 27=(4) 28=(3) 29=(3) 30=(2) 31=(2) 32=(2) 33=(2) 34=データ移行(2) 35=(2)</sub>

> 31-35 都只有 2 个类，嫌零碎可以两三个塞进一个 session —— `DOMAIN_INGEST_PROMPT.md` 允许一个 session 做 1-2 个域。

## P3 — 最后 1 条（9 个单类域打包）

```
36 读 /Users/user/symphony/workflows/kyuyo-backend/memory/DOMAIN_INGEST_PROMPT.md，按其作业。
   本次为打包作业，域：compare, csv, deleteCheck, inputFieldSetting, listener, menu, production, taxReduction, template
   这 9 个都是 kyuyo-v1 下的单类域。合并写成一条「kyuyo-v1 边缘小域集合」memory，
   重点不是各自的结构（就一个类没什么结构），而是：它们为什么存在、谁在调用、哪些是死代码可以删。
```

---

## 提醒

- 每条都是**独立 session**，互不依赖，顺序可以打乱（P0 优先就行）。
- 每条做完，新 session 应该自己去 [DOMAINS.md](DOMAINS.md) 勾掉并填 memory id。如果它忘了，你提醒一句。
- 中途想验收：`memory_smart_search("<ASCII 域名/类名>")`，看能不能查到那条 memory。
  **一定要用 ASCII 关键词查**（如 `calPattern`、`AbstractCalPatternService`）——实测服务端 BM25 对中日文分词
  失效，纯中文/日语查询查不到东西。详见 DOMAIN_INGEST_PROMPT.md 开头。
- 返回结果的 score 是 RRF 名次分（跨查询恒为同一串数值），**不代表相关度，只看顺序**。
- Dashboard 的 GRAPH NODES 数字不是这件事的指标——它主要由会话活动驱动，跑几百条 `find` 就能翻倍。
