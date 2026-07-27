# 域理解摄取 — 进度清单

作业方式见 [DOMAIN_INGEST_PROMPT.md](DOMAIN_INGEST_PROMPT.md)。一个 session 做 1-2 个域，做完回来勾。

- 合计 **45 个业务域**（v1 43 个 + v2 27 个，去重后 45；其中 25 个在 v1/v2 同名并存）
- 数字 = 该域 java 文件数（`v1 + v2`），不含测试
- 「覆盖」= `KYUYO_DOMAIN.md` §4 是否已有描述。已覆盖的不是不做，是**补它没有的深度**，优先级下调。
- ✓ 列图例：`☑`=已按原子颗粒度做完（结构层+业务规则层+lesson 三样齐）；`◑`=只做了粗粒度 1 条，**待原子化补做**；`☐`=未做。
- **产出标准 = 双载体、按颗粒度判据收敛**（结构+业务规则走 memory 一条一事实，陷阱/漏改走 lesson），不是一条总览，也不预设条数。详见 DOMAIN_INGEST_PROMPT.md「两个载体分流」「颗粒度判据」，样板 `yearAdjustment`（21 memory + 6 lesson）。

---

## P0 — 大域，且 KYUYO_DOMAIN 基本没覆盖

| ✓ | 域 | v1 | v2 | 合计 | 覆盖 | memory id |
|---|---|---|---|---|---|---|
| ☑ | `yearAdjustment`（年末調整） | 49 | — | 49 | 无 | **21 memory + 6 lesson**，anchor `mem_mrn7jzvs_6d68bc875961` / `lsn_206358bb96ccc076`（标准样板，规则层已回补） |
| ☑ | `cal`（給与計算） | 32 | 14 | 46 | 部分 | **14 memory + 6 lesson**，anchor `mem_mrn8xnau_0edb8644aa81` / `lsn_03ef5f33081aab37` |
| ☑ | `basicSetting`（基本設定） | 26 | 19 | 45 | 无 | **20 memory + 6 lesson**，anchor `mem_mro8ftb1_efea90043edb` / `lsn_1369124db1145e90`（实测文件数 v1 82 + v2 77 + common 11，本表 26/19 偏小；v1/v2 大面积同名并存） |
| ☑ | `report`（帳票） | 26 | — | 26 | 无 | **24 memory + 7 lesson**，anchor `mem_mro8flwb_7174ef9f2d57` / `lsn_a3f0a3314e1540ba`（旧粗粒度条 `mem_mrn81wjq_b022bb3bbdac` 已被取代；实测 controller/service/dto/report + util 约 45 文件，本表 26 偏小）|

## P1 — 中大域

| ✓ | 域 | v1 | v2 | 合计 | 覆盖 | memory id |
|---|---|---|---|---|---|---|
| ☑ | `info`（従業員情報） | 16 | 12 | 28 | 部分 | **17 memory + 6 lesson**，anchor `mem_mrojtnrp_aeb86df6b6ac` / `lsn_debbf31ed296310d`（实测 dto/bean 层规模远大于表内 28，v1+v2+common 约 120+ 文件；跨到 dataSheet/deduction/paymentEvent/yearAdjustment/masterTable/transfer 多条边） |
| ☑ | `insurance`（社会保険） | 13 | 10 | 23 | 部分 | **9 memory + 4 lesson**，anchor `mem_mrojspo7_6fe3e75cacc2` / `lsn_64523a0ed4a9a3d1` |
| ☑ | `notificationOfChange`（給与所得者異動届出書） | 16 | — | 16 | 无 | **22 memory + 7 lesson**，anchor `mem_mrub6k0s_f5d2e6f35c82` / `lsn_aae82894488d051e`（实测 v1 31 文件 + common 1、v2 は 0；FileBuilder×4 / Editor 2 系統、住民税 ResidentTaxPayment への書き戻し経路あり） |
| ☑ | `paymentEvent`（支給イベント） | 12 | 4 | 16 | 无 | **20 memory + 8 lesson**，anchor `mem_mrub7apo_5f756a332813` / `lsn_87b88a46fdb75817`（旧粗粒度条 `mem_mrn8153h_361833f5b939` 已被取代；实测 v1 38 + v2 10 + common 2 文件，含 lastMonthComp 子域）|
| ☑ | `commuting`（通勤手当） | 10 | 4 | 14 | **详细** | **18 memory + 7 lesson**，anchor `mem_ms2i7rrk_2682128c5a67` / `lsn_348bae3b935775c5`（实测 common 19 + v1 11 + v2 6 = 36 文件，本表 10/4 未计 common；計算引擎在 common 单份共享，Service/Api 层 v1/v2 逐行双写；履历切面缺口已复核仍存在） |
| ☐ | `dataSheet` | 8 | 6 | 14 | 部分 | |
| ◑ | `procedure`（定時決定/随時改定） | 12 | — | 12 | 无 | 仅粗粒度 1 条 `mem_mrn81j7h_27f942101024`，**待原子化补做** |
| ☑ | `kyuyo`（給与形態別計算機） | 6 | 6 | 12 | 无 | **11 memory + 5 lesson**，anchor `mem_mrylxe6n_68dfbcf8a3c3` / `lsn_5028c250c626c07a`（域=SalaryHelper 給与形態別計算機体系，service/kyuyo 6 + util/kyuyo/Salary*Helper 6；util/kyuyo/calculator 属已做的 `cal` 域，不重复） |
| ☑ | `payment`（支給項目） | 5 | 5 | 10 | 部分 | **24 memory + 8 lesson**，anchor `mem_ms2iayyj_a5a819340e2c` / `lsn_374c7273908441cf`（实测 v1 17 + v2 12 + common 13 文件，本表 5/5 严重偏小；不含 info 域已摂取的 `notInfoBean/paymentInfo`）|

## P2 — 中小域

| ✓ | 域 | v1 | v2 | 合计 | memory id |
|---|---|---|---|---|---|
| ☐ | `process` | 5 | 4 | 9 | |
| ☐ | `task` | 6 | 2 | 8 | |
| ☐ | `gradeInterval`（等級） | 4 | 4 | 8 | |
| ☐ | `deduction`（控除） | 1 | 6 | 7 | |
| ☐ | `payroll` | 4 | 3 | 7 | |
| ☐ | `paymentDeductionSetting` | 3 | 4 | 7 | |
| ☐ | `transfer`（振込） | 6 | — | 6 | |
| ☐ | `masterTable` | 3 | 3 | 6 | |
| ☐ | `attendanceLink`（勤怠連携） | 2 | 3 | 5 | |
| ☐ | `permission`（権限） | 5 | — | 5 | |
| ☐ | `base` | 3 | 2 | 5 | |
| ☐ | `bonusCal`（賞与計算） | 2 | 2 | 4 | |
| ☐ | `attendance`（勤怠） | 3 | 1 | 4 | |
| ☐ | `param` | 2 | 2 | 4 | |
| ☐ | `attachment` | 2 | 1 | 3 | |
| ☐ | `reportForm` | 3 | — | 3 | |
| ☐ | `snapshot` | — | 2 | 2 | |
| ☐ | `member` | 1 | 1 | 2 | |
| ☐ | `memberSetting` | 1 | 1 | 2 | |
| ☐ | `importError` | 1 | 1 | 2 | |
| ☐ | `migration`（データ移行） | 2 | — | 2 | |
| ☐ | `group` | 2 | — | 2 | |

## P3 — 单类域，建议合并成 1-2 个 session 打包做

`compare` 1 / `csv` 1 / `deleteCheck` 1 / `inputFieldSetting` 1 / `listener` 1 / `menu` 1 /
`production` 1 / `taxReduction` 1 / `template` 1

> 这些单独存一条 memory 不划算，建议合并成一条「kyuyo-v1 边缘小域集合」，
> 重点写**它们为什么存在、谁在调用、能不能删**——单类域最有价值的信息往往是"这是不是死代码"。

---

## 已完成

| 域 | 条数 | anchor memory id | 备注 |
|---|---|---|---|
| `yearAdjustment`（年末調整） | 21 memory + 6 lesson | `mem_mrn7jzvs_6d68bc875961` / `lsn_206358bb96ccc076` | 2026-07-16。**双载体完整样板**：结构层 13 memory（1轮目）+ 业务规则层 8 memory（2轮目回补：canSetTarget 对象设定门 / familyCheck 4件枠+3段排序 / getExcludedClassificationIds 2025年度分歧 / setHomeLoanInfoHand 15年レンジ+再計算副作用 / setMemo 备考栏 / CsvExRule 静默改值 / 扶養人数2025分歧 / statusCheck 部分跳过）。lesson 6 条：reflect 混同 `lsn_074cf03fb6a3c5e2`、2025年度分歧 `lsn_206358bb96ccc076`、checkBeforeReflect 疑似 bug `lsn_215308434624b19a`、戻り値反転 `lsn_67d9994eb46cc184`、CSV 静默改值 `lsn_67360169affb6e44`、扶養4件枠连动 `lsn_fa551f91236e6b69` |
| `cal`（給与計算） | 14 memory + 6 lesson | `mem_mrn8xnau_0edb8644aa81` / `lsn_03ef5f33081aab37` | 2026-07-16。跨 v1/v2 一起做。结构层：v1↔v2 边界、新旧双计算引擎、v1 任务流水线、processor 双注册表、锁/Mission/期限三段、calculator 整包复制实测 diff、util/calculation 死枝、路由重组、4 个 CosmosBean + 集計結果同名双容器。规则层：checkFormula 模拟执行式校验、initCalItemsList 5 分岐、checkFormulaBeforeCal 三种マスタ存活检查、KyuyoEvaluator 全角运算符+IF/ROUND、MemberStateGenerator 給与/賞与非对称、GenerateTotalTask 分页与 MAX_MEMBER_NUM 兜底、SalaryCalCtx v1/v2 实质分歧。lesson 6 条：状態門非対称 `lsn_03ef5f33081aab37`、Mission 12h 门 `lsn_011b4e01466310cd`、二軸複製漏改 `lsn_3fbd000de0b04247`、死枝勿触 `lsn_a9ea140ec4c26ba3`、例外握潰 `lsn_94dc8c5d6257b6d9`、遡及未実装 `lsn_fe8fd3d55b7ea7df` |
| `calPattern`（給与計算パターン） | 1 | `mem_mrn6gl3m_063ca1f56bb8` | 2026-07-16。**旧式单条**，深度可参考但颗粒度已过时，别照它一域一条 |
| `report`（帳票） | 24 memory + 7 lesson | `mem_mro8flwb_7174ef9f2d57` / `lsn_a3f0a3314e1540ba` | 2026-07-17。v1-only（v2 仅 1 文件 ReportViewSetting 复制体）。结构层：两套互不相干的 PDF 框架（一覧表系 BaseReportConvertHtmlToPdfService + ReportMetadata 三层声明式元数据 vs 明細系 DetailsBaseConvertHtmlToPdfService 命令式 DOM）、帳票→実装対応表、跨域边 ReportPaymentEventQueryService→getEventServiceByType、payrollItems/payrollItemsNew 双格式、一括 PDF 累加式生成、住民税 FB 的 PDF 继承 vs CSV boolean 双机制、賞与支払届 e-Gov CSV。规则层：レポート設定 5 条预置 + version 幂等门（force 被忽略）、明細不落库实时组装、权限只 2 个 InfoTarget 且由 MonthlyPaymentSlip 分裂（DELETE→UPDATE）、getOwnerOrg 用 endDay、ReportNameGenerateUtil 命名规则、源泉徴収票対象者判定（最終支給日の年 + confirm=true）、納期の特例 1-6/7-12、賃金台帳 getGroupViewItem 双分支 + CSV 转置表 + 性別 now 基準日、氏名全角回退カナ、BonusPayReportMemo 3 值。lesson 7 条：version 漏升 `lsn_a3f0a3314e1540ba`、v1/v2 双 ReportViewSetting `lsn_a3604c7a00894433`、rename 致权限 id 漂移 `lsn_1d4e5df4ee6f7105`、fields 投影漏 payrollItemsNew `lsn_8b3719720d136702`、基準日各不相同 `lsn_801b437b0e603c9a`、賃金台帳三反直觉点 `lsn_8a4e8c3e482ecff8`、e-Gov CSV 漏 WordConversion `lsn_d38eafc1d34416fe` |
| `procedure`（定時決定/随時改定） | 1 | 见上表 ◑ | 2026-07-16 粗粒度试做，**待原子化补做** |
| `paymentEvent`（支給イベント） | 20 memory + 8 lesson | `mem_mrub7apo_5f756a332813` / `lsn_87b88a46fdb75817` | 2026-07-21。跨 v1/v2 一起做，含 lastMonthComp 子域。结构层：給与/賞与共用四层泛型骨架（BasePaymentEvent→PaymentEvent/BonusEvent、BasePaymentEventService<T,S>、BasePaymentEventApi 四泛型）、PaymentEvent id=eventDate_groupId + preMonthId 显式链、EventStateMachine 双闸（遷移矩阵 + 動作×状態矩阵 10 EventAction）、確定処理 12 步流水线（锁→8并列 confirmPayroll2→進捗→キャッシュ無効化→ADD_MEMBER_SNAPSHOT/翌月生成→年調CSV→COMPLETED）、EventMemberInfo 固化 vs 実時計算双路径、v1↔v2（v2 无路由、確定/取消为空壳的读侧复制体）、lastMonthComp 4 CosmosBean + PastMonthPeCompHelper、v2 専用の保険スナップショット builder 2 个、HTTP 面 14+9 端点、4Display/Member4Event/Proccess 薄 DTO。规则层：日期校验 6 条分两处（checkData 自身 / checkDataWithOthers 邻接）、対象者判定 filterIdsByEventDate + getRetireEndDate 依 isShowRetireeInFinalMonth 分支、自動生成三入口 + COMPLETED ガード、allowingPartialFields 7 字段白名单 + 定額減税 payDay 特例 + getOpenDay 默认 payDay-1、確定取消 6 处连带清理 + CalculationCancelSetting 开关、repaireEventStatusNeedLock 双归宿、振込先未設定者判定（1口座かつ3処全TRANSFER空）、batchManualBack 的 ATTENDANCE 清空特例 + 两套并行实现、前月比較実行規則（相手 COMPLETED・同group1年以内・進捗100で purge）、三种日期基准、dailyCheck 只报告不修复。lesson 8 条：v2 空壳复制体 `lsn_87b88a46fdb75817`、allowingPartialFields 静默失败 `lsn_8adbcfc73f4f67be`、状態は必ず状態機経由 `lsn_dbac7d171a8ef004`、取消の連帯クリーンアップ `lsn_96331ebd82e8a9f5`、対象者の二経路 `lsn_3fc7a2ed584a2ce2`、日付チェック 2 箇所 `lsn_26076f343ff6e086`、baseDate に payDay を使うな `lsn_499af55f5385e218`、グループ COMPLETED ガード + preMonthId `lsn_b91d1b0daaaa214a` |
| `insurance`（社会保険） | 9 memory + 4 lesson | `mem_mrojspo7_6fe3e75cacc2` / `lsn_64523a0ed4a9a3d1` | 2026-07-17。跨 v1/v2/common 一起做，KYUYO_DOMAIN §4/§7 已有的 procedure 従業員反映内容不重复摄取。结构层：controller/API 层只在 v1（v2 只镜像 dto+service，无路由）；`InsuranceAggregationSettingApi` 抽象基类（5 子类 getService() 全返回 null，不走标准 CRUD 生命周期）；`PremiumRate`/`PremiumRateItem` 两层平行继承；`GovDataStorage` 懒加载单例硬编码逐年 gov xlsx + 日期区间；drools 三段式（facts→processor→results，v1/v2 镜像）；与 procedure/info 域 dataSheet 层（`HealthRetireInsInfomation`/`LaborHireInsInfomation`）的边界。规则层：協会管掌 vs 組合管掌费率来源分歧+折半计算、appliedStartMonth 去重校验+负数校验。lesson 4 条：insurance 域"V1/V2"三义性混淆 `lsn_64523a0ed4a9a3d1`、getService()==null 陷阱 `lsn_449f090deb2850d0`、新年度料率上线三步骤 `lsn_efef6922dba70be2`、協会/組合管掌分支不对称 `lsn_ea172a6dff06fac3` |
| `kyuyo`（給与形態別計算機） | 11 memory + 5 lesson | `mem_mrylxe6n_68dfbcf8a3c3` / `lsn_5028c250c626c07a` | 2026-07-24。跨 v1/v2 一起做。域=給与形態別「計算機(Salary Helper)」体系（service/kyuyo 6 + util/kyuyo/Salary*Helper 6；util/kyuyo/calculator/processor 属已做的 `cal` 域，未重复）。结构层：双平行继承树（策略侧 SalaryHelper→SalaryPayrollHelper/SalaryBonusHelper→月/日/時、緩存侧 SalaryHelperCacheService←CacheableService 4 子类）、SalaryHelperService 組立工廠（賞与不带勤怠）、KyuyoCacheKey DB 比对失效 12h（与 KyuyoCacheService 共用 KyuyoCacheKeyService）、消费者定位（MemberNewExecutor/PayrollService/PayslipService/MasterTableCalService）、v1↔v2 双泛型+勤怠上提基类分歧。规则层：策略子类唯一差异=形態別 CalculationMethod 筛 CUSTOM_FORMULA、SalaryBonusHelper deductionItemIdMap 賞与社保預定義注册表（標準賞与額 processor）、calPayment 三分支+isEdit 手入力保护、給与休職三态分岐、calValueMap 前缀约定（m./job./source）、makePaymentDeductionSettingInfo 支給控除従業員設定连携。lesson 5：計算入口吞异常返回旧值 `lsn_5028c250c626c07a`、v1/v2 镜像非整包复制 `lsn_7c3da314f800a3fb`、isEdit 手入力保护 `lsn_6c1d04127478ad1b`、改マスタ需 bump KyuyoCacheKey 否则 12h stale `lsn_868ef6086413c278`、賞与旁路非同构 `lsn_5c0f8e7d8d1014a2` |
| `payment`（支給項目設定） | 24 memory + 8 lesson | `mem_ms2iayyj_a5a819340e2c` / `lsn_374c7273908441cf` | 2026-07-27。跨 v1/v2/common 一起做（实测 v1 17 + v2 12 + common 13 文件）。结构层：4タイプ×3層平行骨架（CommonPaymentItem/CommonPaymentItemService、上位は deduction と共用の AbstractCalculableItem(Service)）、**v1/v2 は partition が別**（English.plural(クラス名)、@CosmosBean 値は日本語説明で同一なので当てにならない）、HTTP 面の作り直し（v1 4Api×27 ルート+FirstLevelPermission vs v2 単一 PaymentItemApi 4 ルート {type} 分発・権限判定なし）、v2 分発点 getPaymentItemService と兄弟 CalPatternServiceHelper/DeductionServiceHelper、計算方法 enum の収斂（v1 4 enum→v2 単一 5 値・FAMILY 追加）、日割り/減額 5 子モデル（4386、**消費者ゼロ**）、従業員情報フォーム連携（isNeedTransfer/syncItemToForm/getPaymentFormId、v1 賞与のみ formId=""）、upsertAfter 副作用バス 5 本+deleteAfter 3 本（全部握潰）、循環依存 PayrollItemGraphBuilder（v1 のみ）、CalculableData→cal/kyuyo 境界、paymentDeductionSetting 境界、パッケージ 3 系統の切り分け。规则层：初期データ（月給27件/賞与1件・id OR name 冪等・v1 のみ needTotalCalItem パッチ）、PaymentDetailSetting 10-11 フラグ、通勤ペア 8 方向 commutingMap+4409 保護、バリデーション 5 点（名称ユニーク/範囲 999,999,999/自己参照/楽観ロック）、削除ブロック 3 段優先、allowingPartialFields 8 サービス全バラ、v1 一括保存 checkAndSortList、みなし3項目の業務情報シート強制上書き、通勤/役員報酬の課税フラグ強制上書き、PaymentItem4Display の deletable/warnMsg、無効化ゲート v1/v2 口径差、sortByPaymentItemSetting。lesson 8 条：v1/v2 別データ別実装 `lsn_374c7273908441cf`、updateCustomerFormulaChange 疑似 bug `lsn_965133825be377a8`、後処理握潰 `lsn_c5fc3be42ff76d71`、allowingPartialFields 静默失败 `lsn_0e6e53f3f0fd33e8`、通勤/役員報酬の特例 `lsn_4c4a15eff94b3b21`、日割り設定は未実装 `lsn_b171f6ba10fbb75a`、deletable と findDeleteBlock の口径不一致 `lsn_02204ab02ea52aa2`、KyuyoCacheKey bump 漏れ `lsn_4d58200df1477961` |
| `info`（従業員情報） | 17 memory + 6 lesson | `mem_mrojtnrp_aeb86df6b6ac` / `lsn_debbf31ed296310d` | 2026-07-17。跨 v1/v2/common 一起做。结构层：InfoSheet(KYUYO_InfoSheets)+InfoBean 双层持久化模型；`DATA_SHEET_MAP` 分发点（6 formId 桥接 dataSheet 域 vs 其余直存）；`notInfoBean/paymentInfo` 平行桥接子系统（BankAccountInfo/PaymentInfo 走 `SheetDataConvert`，不经 DATA_SHEET_MAP）；`BankAccountInfoSnapshot` 確定時点固化（跨 transfer 域）；`PreMonthComparable`/`InfoFormPreMonthComparable` 前月比較反射机制（跨 yearAdjustment/masterTable 域）；`InfoSheetHistoryService` + 2 个 History Converter 的表单拆分机制；`InfoSheetHistorySorter` 固定排序表；`getSalaryType` 驱动支给项目三选一；MemberInfo/MemberAllInfo(SnapShot) 继承链；InfoSheet4Display 展示态；v1/v2 差异（InfoFormCategory/AbsenceInformationSheetService/SocialInsurancePaymentService 仅v1，MyNumberMemberDto 仅v2）；TaxDeductionInformation upsert 隐式触发控除域重算（跨 deduction 域）；AfterMemberChange 挂载点；SocialInsurancePayment 两端死代码；ResidentTaxPaymentCsvService 住民税CSV导入(eLTAX)。lesson 6 条：履历拆分只读/可写不对称 `lsn_debbf31ed296310d`、DATA_SHEET_MAP 分流误判 `lsn_cdbae4b15c000651`、TaxDeductionInformation 隐式副作用漏调 `lsn_8132ef25065a3472`、SalaryType 穷举 switch 无 default `lsn_ed010a894f093531`、SocialInsurancePayment 死代码勿复用 `lsn_0c1b7d57b1f5ffb2`、InfoFormCategory 仅v1初期化 `lsn_03cdb4d06433914a` |

---

## 完工后

全部做完（或 P0+P1 做完）后，跑一轮验收：拿 10 个真实业务问题查 `memory_smart_search`，
统计命中率。若命中率不理想，问题在**写法**（内容太泛/太像文件树），不在数量——回头改写法，别加量。

**lessons 已验证可用（2026-07-16 更新）**：`memory_lesson_save`/`memory_lesson_recall` roundtrip 通过，`project` 过滤生效、CJK+ASCII 混合查询命中（早先"recall 全 0"结论已失效）。
→ 现行规范：域摄取用**双载体**——结构+业务规则走 `memory`，陷阱/漏改走 `lesson`（见 DOMAIN_INGEST_PROMPT.md「两个载体分流」）。crystals/insights 不在域摄取范围。
进度请分别记 memory 条数与 lesson 条数。
