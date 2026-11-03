# Desktop Office Assistant Stage A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付可在当前 Mac 启动的中文待办应用，具有持久化、完成标记、重复任务、每日汇总、到期提醒及菜单栏入口。

**Architecture:** Swift Package 分离 Foundation 任务规则、Mac 桌面服务及 SwiftUI 可执行入口。Core Data 是数据来源，UserNotifications 负责系统调度，纯函数产生提醒计划；界面和通知动作使用同一个任务服务。阶段 B/C 后续通过正式任务创建入口接入，不在本阶段实现音频或 AI，也不提供模拟翻译结果。

**Tech Stack:** Swift 6 工具链，Swift tools version 5.9 / Swift 5 语言模式，macOS 14+，SwiftUI、Core Data、UserNotifications、ServiceManagement，Swift Testing；无第三方依赖。

**Spec:** [已确认的整体设计](../specs/2026-11-02-office-assistant-design.md)。本计划只覆盖“交付拆分与验收”的阶段 A；阶段 B/C 分别另写实施计划。

## Global Constraints

- 中文界面；每天 09:00 汇总；用户当前时区默认 Asia/Shanghai。
- 初始部署目标为 macOS 14 及以上；最低版本支持需要实际编译与相应环境验证，不能仅凭当前机器宣称已验证。
- SwiftUI 构建 Mac 原生界面，Core Data 本地持久化，UserNotifications 调度通知。
- 时间不明的任务可保存且标记待补充，不凭空生成精确提醒。
- 个人身份名称在设置中维护；负责人未知显示未指定，不能将未指明的任务自动归到自己。
- 支持一次性、每天、工作日、每周重复；完成一个重复任务只完成本次实例。
- 到点通知可完成或稍后 10 分钟提醒；完成、删除或更改截止时间时取消旧通知。
- 逾期任务留在今日视图；启动、恢复运行时补充显示遗漏提醒，不集中弹出所有历史通知。
- 关闭窗口后保留菜单栏入口；真正退出后停止采集和在线处理。
- 交付源代码、可本地启动的 .app、操作说明及验证记录。没有执行或受系统权限影响的验证如实标记。
- 工作根目录是 `/Users/newb/Documents/works/ecommerce`，所有下列路径相对此目录。当前没有 Git 仓库，不主动初始化；如执行期间已有仓库，每个任务通过后仅提交该任务的明确文件，禁止包含用户其他修改。

## Review Focus

1. 周末、月末、夏令时与修改时区：重复任务保留原所属时区，按当地日历计算，见 Task 1。
2. 重复点击完成、通知动作重放及撤销：不得生成重复后续实例，也不得无提示删除已编辑实例，见 Task 1/2。
3. 空标题、模糊中文时间与午夜输入：拒绝空白标题，保留不确定原文，不捏造截止时间，见 Task 1/4。
4. 存储损坏、未知数据版本或保存失败：保留原数据并显示错误，不以空数据覆盖，见 Task 2。
5. 权限拒绝、编辑过程中调度重入与睡眠恢复：列表仍可使用，只有最新任务状态能决定提醒，见 Task 3/5。

## File Structure

```text
Package.swift
Sources/OfficeCore/TaskItem.swift                 # 可编码值类型、状态、重复规则
Sources/OfficeCore/TaskRules.swift                # 日历、完成、下一实例及今日视图规则
Sources/OfficeCore/QuickEntryParser.swift         # 确定性中文时间建议；非 AI 提取
Sources/OfficeCore/ReminderPlanner.swift          # 有界提醒计划、稳定请求 ID
Sources/OfficeCore/AppPreferences.swift          # 可编码设置值类型
Sources/OfficeDesktop/Persistence/TaskRecord.swift
Sources/OfficeDesktop/Persistence/TaskRepository.swift
Sources/OfficeDesktop/Persistence/CoreDataTaskRepository.swift
Sources/OfficeDesktop/Tasks/TaskStore.swift       # 唯一任务修改入口
Sources/OfficeDesktop/Settings/AppPreferences.swift
Sources/OfficeDesktop/Reminders/NotificationClient.swift
Sources/OfficeDesktop/Reminders/ReminderCoordinator.swift
Sources/OfficeDesktop/Views/WorkspaceView.swift
Sources/OfficeDesktop/Views/TaskListView.swift
Sources/OfficeDesktop/Views/TaskEditorView.swift
Sources/OfficeDesktop/Views/SettingsView.swift
Sources/OfficeAssistant/OfficeAssistantApp.swift
Sources/OfficeAssistant/AppDelegate.swift
Support/Info.plist
scripts/build-app.sh
Tests/OfficeCoreTests/{TaskRulesTests,QuickEntryParserTests,ReminderPlannerTests}.swift
Tests/OfficeDesktopTests/{PersistenceTests,TaskStoreTests,ReminderCoordinatorTests}.swift
README.md
docs/verification/stage-a.md
```

构建产物放 `dist/OfficeAssistant.app`；Swift 缓存统一使用项目内 `.build`，不要求写系统工具目录。核心值类型不依赖 SwiftUI、Core Data 或通知框架。

### Task 1: 可验证的任务模型和重复规则

**Files:** Create `Package.swift`、`Sources/OfficeCore/{TaskItem,TaskRules}.swift`、`Tests/OfficeCoreTests/TaskRulesTests.swift`。先仅声明 OfficeCore 和其测试 target，后续任务逐步加入 target，避免引用空目录。

**Interfaces:**
- `TaskStatus: String, Codable`：pending、inProgress、completed；`RepeatRule: String, Codable`：none、daily、weekdays、weekly。
- `TaskItem: Identifiable, Codable, Equatable`：`id: UUID`、`title: String`、`notes: String`、`owner: String?`、`status: TaskStatus`、`createdAt: Date`、`completedAt: Date?`、`dueAt: Date?`、`dueText: String?`、`timeZoneID: String`、`repeatRule: RepeatRule`、`seriesID: UUID`、`nextOccurrenceID: UUID?`、`snoozedUntil: Date?`。新建单次任务也有自己的 seriesID。
- `TaskRules.validate(_ item: TaskItem) throws`、`nextDueDate(after due: Date, rule: RepeatRule, timeZoneID: String, now: Date) throws -> Date?`、`complete(_ item: TaskItem, at now: Date) throws -> CompletionResult`、`isTodayOrOverdue(_ item: TaskItem, now: Date, displayTimeZoneID: String) -> Bool`。
- `CompletionResult` 包含 `completed: TaskItem`、`next: TaskItem?`。再次完成已完成项是无变化结果；下一实例日期严格晚于 now，跳过已错过的周期；每周沿用原截止日期的星期几。所有 UI 列表包含无日期任务的入口，不能因为无提醒时间而隐藏。

- [ ] **Step 1:** 建立包与失败测试：`testWeekdaysFridayToMonday` 断言上海 2026-11-06 17:00 完成后下一截止为 2026-11-09 17:00；`testDailyAcrossMonthEnd` 断言 11-30 下一天为 12-01 同时刻；`testDailyAcrossDST` 使用 America/New_York 2026-10-31 09:00，断言下一实例为当地 11-01 09:00；`testRepeatedCompletionIsNoOp` 断言第二次 next 为 nil；`testBlankTitleRejected`、`testMissingDueWithRepeatRejected` 和 `testUnknownTimeZoneRejected` 均断言抛出验证错误。
- [ ] **Step 2:** 运行 `bash scripts/test.sh --filter TaskRulesTests`，确认失败来自尚未实现的接口，不是环境故障。
- [ ] **Step 3:** 实现上述值类型和规则，使用 Gregorian Calendar 及任务时区计算日期，不以固定 86400 秒计算日历天；空标题 trim 后拒绝，完成时清空本次稍后提醒。
- [ ] **Step 4:** 重跑同一命令，应全部 PASS；另断言修改显示时区不更改任务的绝对 dueAt 和所属时区。

### Task 2: 本地持久化与统一任务服务

**Files:** Modify `Package.swift`，新增 OfficeDesktop library 和 OfficeDesktopTests；Create `Sources/OfficeCore/AppPreferences.swift`、Persistence 三个文件、`Tasks/TaskStore.swift`、`Settings/AppPreferences.swift` 及 `PersistenceTests.swift`、`TaskStoreTests.swift`。

**Interfaces:**
- `@MainActor protocol TaskRepository`：`load() throws -> [TaskItem]`、`save(_ items: [TaskItem]) throws`。save 在一个 context save 中提交整次任务变更，失败 rollback。Core Data 中 TaskRecord 保存唯一 UUID、`schemaVersion: Int` 和 Codable payload，版本初始为 1；不支持的版本显式报错。
- `@MainActor @Observable final class TaskStore`：`items: [TaskItem]`、`errorMessage: String?`；`reload() throws`、`upsert(_ item: TaskItem) throws`、`delete(id: UUID) throws`、`complete(id: UUID, at: Date) throws`、`reopen(id: UUID) throws`、`snooze(id: UUID, until: Date) throws`。先持久化成功，再替换内存快照；构造器接收 repository。
- Core 的 `AppPreferences: Codable, Equatable`：`displayName: String`、`timeZoneID: String = "Asia/Shanghai"`、`dailySummaryEnabled: Bool = true`、`summaryHour: Int = 9`、`summaryMinute: Int = 0`；桌面 Settings/AppPreferences.swift 定义 `@MainActor @Observable final class PreferencesStore`，提供 `value: AppPreferences` 与 `save(_:) throws`，通过 UserDefaults 单独保存，读取错误可见且不覆盖原值。
- 重复完成使用 Task 1 的 nextOccurrenceID 防重。撤销完成：后续实例完全未改动时，在同次保存中删除该实例；已编辑、进行中或已完成时抛出可识别错误，提示先处理下一实例，不静默改变系列。

- [ ] **Step 1:** 写失败测试：`testRoundTripAfterReopen` 在临时磁盘库保存后重建 repository 并断言 item 全字段相等；`testCorruptPayloadPreserved`/`testUnknownSchemaPreserved` 断言 load 抛错且原 record 仍在；`testFailedSaveLeavesSnapshotUnchanged` 使用故意抛错的 repository；`testDuplicateCompletionCreatesOneNextOccurrence`、`testReopenUnmodifiedNext`、`testReopenEditedNextRejected` 验证上述系列规则。
- [ ] **Step 2:** 运行 `bash scripts/test.sh --filter OfficeDesktopTests`，确认新用例失败。
- [ ] **Step 3:** 实现 Core Data 模型、repository、TaskStore 和设置；生产库位于 Application Support/OfficeAssistant，测试只能使用临时目录或内存容器；错误状态下不得主动写入空库。
- [ ] **Step 4:** 重跑 OfficeDesktopTests，全部 PASS；更新设置后重新创建设置服务，断言 09:00 默认及用户修改值可恢复。

### Task 3: 到期、每日和稍后提醒

**Files:** Create `Sources/OfficeCore/ReminderPlanner.swift`、Reminders 两个文件及 `ReminderPlannerTests.swift`、`ReminderCoordinatorTests.swift`。

**Interfaces:**
- Core：`ReminderTrigger` 为 `.once(Date)` 或 `.daily(hour: Int, minute: Int, timeZoneID: String)`；`ReminderRequest` 包含 id、taskID（可空）、title、body、trigger；`ReminderPlan` 包含 requests 和 overdueTaskIDs。
- 消费 Task 2 定义的 OfficeCore.AppPreferences，不从 Core 引用 Desktop。
- `ReminderPlanner.plan(tasks: [TaskItem], preferences: AppPreferences, now: Date) -> ReminderPlan`：最多 48 条最近未来的任务通知，加至多 1 条每日通知；无截止或已完成任务不调度。snoozedUntil 存在时优先使用；过期时间只进入遗漏列表。任务 ID 为 `office.task.<UUID>`，每日 ID 为 `office.summary`。
- 每日标题“今日待办”，正文“查看今天的待办与逾期事项”，点击打开今日视图；不把昨天计算的数量当成今天的数量。
- `@MainActor protocol NotificationClient`：`authorization() async -> NotificationAuthorization`、`requestAuthorization() async throws -> Bool`、`pendingIDs() async -> Set<String>`、`remove(ids: [String])`、`add(_ request: ReminderRequest) async throws`；authorization 值为 notDetermined、denied、authorized。
- `@MainActor final class ReminderCoordinator`：`reconcile(tasks: [TaskItem], preferences: AppPreferences, now: Date) async throws`，串行处理并只提交最新 generation，取消旧的本应用通知，保留非本应用请求；不在每次校准时自动申请权限。

- [ ] **Step 1:** 失败测试：`testCompletedAndUndatedTasksNotScheduled`、`testPastDueListedButNotBurstScheduled`、`testDailySummaryDefaultsToNineShanghai`、`testNearestFortyEightPlusOneSummary`、`testSnoozeTenMinutes`（now + 600 秒）、`testEditCancelsOldRequest`、`testDeniedDoesNotMutateTasks`、`testLatestReconcileWins`（可控制的 fake client 挂起前次 add，再修改任务为完成，最终 pending 中没有该任务）。
- [ ] **Step 2:** 运行 `bash scripts/test.sh --filter Reminder`，确认上述用例失败。
- [ ] **Step 3:** 实现 planner、UNUserNotificationCenter 适配器、协调器。操作类别为完成、10 分钟后提醒；动作解析 UUID 后调用 TaskStore，再校准。任务已删除或完成时忽略迟到动作。
- [ ] **Step 4:** 同一命令全部 PASS；增加 `testReplayedSnoozeOnCompletedTaskIgnored` 验证迟到通知不能复活完成任务。

### Task 4: 中文桌面待办工作流

**Files:** Modify `Package.swift` 增加 OfficeAssistant executable target；Create Core parser、四个 Views 文件、`OfficeAssistantApp.swift`、`QuickEntryParserTests.swift`。

**Interfaces:**
- `QuickEntryParser.parse(_ text: String, reference: Date, timeZoneID: String) -> QuickEntrySuggestion`；返回 `title: String`、`dueAt: Date?`、`dueText: String?`、`needsClarification: Bool`。支持明确的“今天/明天/后天 + 上午/下午 + H点/HH:mm”及“本周/下周 + 周一至周日 + 明确时分”；小时和分钟验证合法范围。“明天下午”“周五”“尽快”和无法识别的日期保留原表达，dueAt 为 nil。单独“周五”不推定哪一周。所有建议必须经编辑表单确认。
- `WorkspaceView(store: TaskStore, preferencesStore: PreferencesStore)` 负责导航和错误展示，子视图不直接操作数据库；PreferencesStore 为桌面设置文件中的 @MainActor @Observable 包装，提供 `value: AppPreferences` 与 `save(_:) throws`。
- TaskEditor 显示标题、备注、负责人、状态、明确截止时间开关、时区及重复规则；提供“我”快捷填充但不自动把空负责人设为我。无精确截止时间不得启用重复规则。
- 今日视图显示当前时区的到期及逾期未完成项，另设“未安排时间”区域；全部视图含搜索与状态筛选，已完成视图支持撤销。修改截止时间时明确保留/切换任务所属时区。
- 会议记录页显示“会议与实时翻译将在后续阶段加入”，无不可工作的开始录音按钮。

- [ ] **Step 1:** 写失败测试：`testTomorrowThreePM` 以上海 2026-11-02 22:00 为 reference，输入“明天下午三点交周报”，断言 dueAt 为上海 2026-11-03 15:00；`testAfterMidnightUsesReferenceDay`；`testAmbiguousAfternoonNotInvented` 断言 dueAt 为 nil 且 needsClarification；`testInvalidClockNotNormalized` 对“明天25:90”；`testOriginalTextSurvivesUnknownDate`。中文数字至少支持一至二十三的小时，以及半；其他无法解析文本保留。
- [ ] **Step 2:** 运行 `bash scripts/test.sh --filter QuickEntryParserTests`，确认失败。
- [ ] **Step 3:** 实现 parser 和界面。界面采用清晰的系统原生列表、工具栏和编辑表单，支持键盘新增与搜索，状态除颜色外提供文字；不引入纯装饰依赖。
- [ ] **Step 4:** parser 测试 PASS，运行 `swift build --scratch-path .build` 应成功；实际打开应用后手动验证新增、修改、完成、撤销、删除、搜索和设置，记录结果，不为简单视图写镜像测试。

### Task 5: 菜单栏、生命周期与可打开的应用包

**Files:** Create `AppDelegate.swift`、`Support/Info.plist`、`scripts/build-app.sh`、`README.md`、`docs/verification/stage-a.md`；Modify `OfficeAssistantApp.swift` 接通应用服务与 MenuBarExtra。

**Interfaces:**
- AppDelegate 实现 UNUserNotificationCenterDelegate；应用启动、唤醒、任务/设置变化及通知动作后调用 ReminderCoordinator。通知前台展示不依赖主窗口可见。所有后台任务由同一个应用服务持有，退出时取消。
- MenuBarExtra 提供打开待办、新增待办、显示今日数量、退出。使用 openWindow 打开固定 ID `workspace`；避免多次创建独立 store。主窗口可以关闭，保留菜单栏；Dock 默认可见。
- 登录时启动用 SMAppService.mainApp，在设置中由用户显式开启；注册失败或需要系统批准时显示真实状态。
- `build-app.sh` 从自身位置定位项目，使用 `swift build --scratch-path .build -c release` 和 `--show-bin-path` 找到二进制，组装 `dist/OfficeAssistant.app/Contents/{MacOS,Resources}`。Info.plist 固定 bundle ID `local.officeassistant.desktop`、名称“办公助手”、版本 0.1.0、最低系统 14.0；本机 ad-hoc 签名，不复制到 /Applications，不要求发布证书。

- [ ] **Step 1:** 运行已有 `bash scripts/test.sh` 建立回归基线；只在失败来自本任务修改时补对应服务测试，不给打包脚本写镜像单元测试。
- [ ] **Step 2:** 接通生命周期及菜单栏，打包脚本可重复执行，只替换本项目 dist 内同名应用。通知动作在 cold launch 时也先初始化存储，再读取任务、操作及校准。
- [ ] **Step 3:** 运行 `bash scripts/test.sh`、`bash scripts/build-app.sh`、`plutil -lint dist/OfficeAssistant.app/Contents/Info.plist`、`codesign --verify --deep --strict dist/OfficeAssistant.app`；测试 PASS，lint/签名退出码为 0。编译失败先解决，不以截图代替构建验证。
- [ ] **Step 4:** 用 `open dist/OfficeAssistant.app` 启动，并通过可用电脑控制工具检查真实窗口：创建一个数分钟内到期的任务，授权后验证通知及稍后/完成；关闭窗口后从菜单栏恢复；退出重开验证持久化；明确禁用通知后验证列表仍可操作；唤醒后逾期进入列表且无通知风暴。操作设置只针对本应用，不修改系统全局通知偏好。
- [ ] **Step 5:** README 写明启动、数据位置、提醒权限、登录启动、重复规则、当前只有阶段 A 以及 B/C 功能范围。验证记录逐项填真实通过/失败/未执行及原因，包含当前系统版本，不宣称 macOS 14 已实机验证。向用户交付 .app 绝对路径及已知限制。

## Self-review and Handoff

覆盖对应：阶段 A 的任务模型及日历规则→Task 1；本地保存和修改→Task 2；通知生命周期→Task 3；输入及中文界面→Task 4；菜单栏、启动、打包和使用验证→Task 5。五项 Review Focus 均有对应自动或系统验证。AppPreferences 值类型在 Core，桌面 AppPreferences.swift 仅定义 PreferencesStore，避免循环依赖。

阶段 A 不实现语音、翻译、纪要或 AI 待办抽取；这不改变整体确认范围。阶段 B 前按 API 凭证技能完成接入设置并另外审阅该阶段实施计划。

执行方式待用户选择：Native（当前助手逐项实施，完成后独立审查）或 Subagent-driven（按任务分别实施及审查）。推荐 Native：5 项任务共享紧密的数据和生命周期接口，本机验证集中执行更直接。实施前须由用户审阅本计划并选择方式；不得将此前对设计的“ok”当成对尚未存在的本计划的批准。

更新：用户已选择 1（Native），上述审阅与执行方式前置要求已满足。


## 执行记录（2026-11-03）

用户选择 Native；由当前助手实施，并由独立助手只读审查。当前 Command Line Tools 不含 XCTest 和 SwiftDataMacros，改用本机已有 Swift Testing 与 Core Data；没有安装外部依赖，数据位置和功能范围保持本设计要求。`scripts/test.sh` 配置本地工具链的 Testing 框架及运行库。

提醒协议另提供 `deliveredIDs() async -> Set<String>`，调度采用差量更新，保存编辑时合并最新 snooze；新增过期截止修改、调度重入错误及已送达通知保留测试。菜单栏与通知入口用模型持有的打开窗口回调。具体检查结果见 `docs/verification/stage-a.md`。

执行状态：Task 1–5 的实现和自动检查已完成，release 应用及说明已交付。实机检查已验证启动、中文输入、新增、完成、撤销和重启保存。真实通知横幅、无窗口快捷键及登录启动受当前工具/系统环境限制，未记作通过；详见验证记录。不把阶段 B/C 记作完成。
