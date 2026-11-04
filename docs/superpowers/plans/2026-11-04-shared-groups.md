# Two-Level Shared Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为会议、纪要和待办提供最多两层的本机共用分组管理。

**Architecture:** OfficeCore 管理分组树规则，独立 GroupStore 原子保存目录，待办与会议分别保存可选 groupID。SwiftUI 复用现有待办与会议工作区；纪要沿用会议归属。无效的历史归属解析为未分组，删除目录无需跨数据库改写。

**Tech Stack:** Swift、SwiftUI、Foundation、现有 Core Data、Swift Testing。

**Spec:** `docs/superpowers/specs/2026-11-04-shared-groups-design.md`（已通过）。

## Global Constraints

- 共用一套最多两层的分组；会议和待办各归属零个或一个分组，一级、二级分组均可直接存放内容。
- 名称最长 80 个字符，拒绝控制字符；“全部内容”“未分组”为保留名称。
- 同一父级下重名忽略首尾空白及大小写；不同父级允许同名。
- 数据目录为 `~/Library/Application Support/OfficeAssistant/`；分组存于 `groups.json`。
- 保留现有会议、音频、纪要、待办、完成状态、提醒及相互来源关系。
- 支持平台沿用 Apple Silicon、macOS 14+；不新增第三方依赖，不修改凭证和网络配置。
- 不含第三层分组、多分组归属、标签、云同步、团队权限或自动 AI 分类。
- 原有删除会议及导出音频改动已暂存；提交时只暂存本任务文件或对应变更块，不能把此前已暂存的工作意外包含在分组提交中。

## Review Focus

1. 分组被删除但编辑表单仍开着：保存时将旧归属解析为 nil，不能恢复已删除分组。测试归属：任务 2、4。
2. 分组目录损坏但用户操作提醒或完成任务：保留原 groupID 和原文件，原有功能可用，不误归类为未分组。测试归属：任务 2、4。
3. 已创建行动项被用户移组后重试加入：沿用任务与新分组，不重复创建或移回。测试归属：任务 3。
4. 重复待办下一实例被移动后撤销上次完成：沿用已有“下一实例已修改”保护，不误删修改过的实例。测试归属：任务 2。
5. 跨分组来源跳转且另一会议正在录音：导航过滤不能隐藏目标或中止正在录音的会议。测试归属：任务 4。

---

### Task 1: 分组规则、持久化及兼容模型

**Files:** Create `Sources/OfficeCore/Groups/WorkGroup.swift`, `Sources/OfficeCore/Groups/GroupRules.swift`, `Sources/OfficeDesktop/Groups/GroupStore.swift`; modify `Sources/OfficeCore/TaskItem.swift`, `Sources/OfficeCore/Meetings/MeetingModels.swift`; test `Tests/OfficeCoreTests/GroupRulesTests.swift`, `Tests/OfficeDesktopTests/GroupStoreTests.swift`.

**Interfaces:**
- `WorkGroup: Identifiable, Codable, Equatable, Sendable`，`init(id: UUID = UUID(), name: String, parentID: UUID? = nil)`。
- `GroupScope: Hashable, Sendable`：`.all`, `.ungrouped`, `.group(UUID)`。
- `GroupRules.validate(_ groups: [WorkGroup]) throws`, `effectiveGroupID(_ id: UUID?, groups: [WorkGroup]) -> UUID?`, `matches(_ id: UUID?, scope: GroupScope, groups: [WorkGroup]) -> Bool`, `path(_ id: UUID?, groups: [WorkGroup]) -> String`。
- `GroupStore` 为 MainActor Observable，提供只读 `groups: [WorkGroup]`, `isLoaded: Bool`, `errorMessage: String?`；`init(url: URL? = nil, write: ((Data, URL) throws -> Void)? = nil)`、`reload() throws`、`create(name: String, parentID: UUID? = nil) throws -> UUID`、`rename(id: UUID, name: String) throws`、`move(id: UUID, parentID: UUID?) throws`、`delete(id: UUID) throws`、`normalized(_ id: UUID?) throws -> UUID?`。
- `TaskItem.groupID: UUID?`、`MeetingSession.groupID: UUID?`，可选字段默认 nil；原初始化调用保持源码兼容。

- [ ] **Step 1: Write failing rules and file tests.** 使用固定 UUID 建立一级 A、二级 A1、另一级 B；断言 A 范围匹配 A/A1、不匹配 B；未分组匹配 nil 和失效 ID；路径为 `A → A1`；空名、81 字符、控制字符、保留名、同级 `A`/` a `、重复 ID、缺父级、循环、自父级、第三层均抛错。创建后重开目录应完全一致，删除 A 后 A/A1 均不存在而 B 保留。将旧 TaskItem/MeetingSession 的编码 JSON 移除 groupID 再解码，断言 groupID 为 nil。

```swift
#expect(GroupRules.matches(child.id, scope: .group(parent.id), groups: groups))
#expect(GroupRules.effectiveGroupID(UUID(), groups: groups) == nil)
#expect(throws: (any Error).self) { try GroupRules.validate(invalidTree) }
```

- [ ] **Step 2: Run** `bash scripts/test.sh --filter 'GroupRulesTests|GroupStoreTests'`，预期新符号缺失导致失败。
- [ ] **Step 3: Implement the interfaces above.** GroupStore 保存版本 1 的 `{version, groups}` 信封，默认 writer 使用 Data.write `.atomic`。创建/改名先裁剪首尾空白；任何修改先校验整树，落盘后再发布内存。缺文件为加载成功的空目录；损坏、未知版本、读取失败阻止写入并保留原字节。写失败注入测试要求内存和旧文件不变。父组删除在同一快照移除子组；移动时重新校验整树。
- [ ] **Step 4: Run the Step 2 command**，预期全通过；增加损坏与未知版本原字节不变、writer 抛错、修复文件后 reload 恢复写入断言。
- [ ] **Step 5: Commit only this task's changes**：`feat: persist validated two-level groups`。

### Task 2: 待办、重复规则及会议归属保存

**Files:** Modify `Sources/OfficeDesktop/Tasks/TaskStore.swift`, `Sources/OfficeDesktop/Meetings/MeetingSessionController.swift`, `Sources/OfficeCore/TaskRules.swift`, `Sources/OfficeDesktop/OfficeAppModel.swift`; test `Tests/OfficeDesktopTests/GroupAssignmentTests.swift`, `Tests/OfficeCoreTests/TaskRulesTests.swift`.

**Interfaces:**
- 消费任务 1 的 GroupStore 与 groupID。TaskStore、MeetingSessionController 初始化新增默认 nil 的 `groups: GroupStore?` 参数，保留既有测试构造调用。
- `TaskStore.moveToGroup(id: UUID, groupID: UUID?) throws`，允许已完成事项；`MeetingSessionController.moveToGroup(id: UUID, groupID: UUID?) throws`，当前会议活跃时拒绝移动。
- `MeetingSetup.groupID: UUID?`；prepare 在创建会话时写入有效归属。
- `OfficeAppModel.groups: GroupStore` 与所有业务服务共用同一实例。任务/会议普通保存：目录可读时规范化归属；目录不可读时保留原字段，显式分组移动则抛错。

- [ ] **Step 1: Write failing integration tests.** 新待办与会议归属重开数据库后保留；已完成待办移动不改变 status/completedAt/提醒；删除目录分组后保存旧编辑副本归属为 nil；目录损坏时完成或稍后提醒仍保留原 groupID；会议移动不改变字幕、配置、音频、状态与纪要 fingerprint；正在记录/导入/收尾时移动当前会议抛错。

```swift
try store.moveToGroup(id: completed.id, groupID: child.id)
#expect(store.items.first?.status == .completed)
let result = try TaskRules.complete(repeating, at: now)
#expect(result.next?.groupID == repeating.groupID)
```

- [ ] **Step 2: Run** `bash scripts/test.sh --filter 'GroupAssignmentTests|TaskRulesTests'`，预期新增归属操作未实现失败。
- [ ] **Step 3: Implement the interfaces above.** TaskRules 新重复实例复制 groupID。独立移动仅改 groupID，不能借用禁止编辑已完成任务的 upsert。会议移动从仓库获取最新内容，保存成功后才同步当前会话及历史。无分组目录注入的旧调用保留原 groupID。
- [ ] **Step 4: Run the Step 2 command**，预期通过；补充下一重复实例移动后 reopen 必须抛错、下次实例未改时正常撤销；已删除组的当前筛选由界面重置，不删除任何业务记录。
- [ ] **Step 5: Commit only this task's changes**：`feat: manage task and meeting group assignments`。

### Task 3: 会议行动项继承与重试

**Files:** Modify `Sources/OfficeDesktop/Meetings/MeetingTaskLinkService.swift`; test `Tests/OfficeDesktopTests/GroupInheritanceTests.swift`，复用现有 StageCFailureTests 的仓库失败桩。

**Interfaces:**
- `GroupAssignment: Equatable`：`.inherit`, `.explicit(UUID?)`，放入 `Sources/OfficeDesktop/Groups/GroupAssignment.swift`。
- `MeetingTaskLinkService` 初始化新增可选 `groups: GroupStore? = nil`；`accept(_:editedTask:allowDuplicate:groupAssignment:) throws -> UUID` 新参数默认 `.inherit`，原调用仍可编译。
- `defaultGroupID(meetingID: UUID) throws -> UUID?` 提供校对与会议新建待办表单默认值。

- [ ] **Step 1: Write failing tests.** 来源会议为 A1，默认创建后待办属于 A1；`.explicit(B)` 属 B；`.explicit(nil)` 未分组；关联已有待办保留 B；来源分组已删除时默认 nil；批量调用默认继承；候选状态保存失败但任务成功后，将任务移动到 B，再重试 accept，仍只有同一任务且保留 B。

```swift
let id = try links.accept(candidate, editedTask: draft)
try tasks.moveToGroup(id: id, groupID: other.id)
let retried = try links.accept(candidate, editedTask: draft)
#expect(retried == id)
#expect(tasks.items.first { $0.id == id }?.groupID == other.id)
```

- [ ] **Step 2: Run** `bash scripts/test.sh --filter 'GroupInheritanceTests|StageCFailureTests'`，预期继承断言失败。
- [ ] **Step 3: Implement the interfaces above.** 已加入任务的幂等查询仍为第一步，仅新建任务解析继承或显式归属；associate 不修改分组。目录不可读时禁止选择分组，保留来源会议原始归属供恢复后解析，不能把目录故障当成分组已删除。
- [ ] **Step 4: Run the Step 2 command**，预期全部通过，原有候选防重复和来源校验维持。
- [ ] **Step 5: Commit only this task's changes**：`feat: inherit meeting groups for new action tasks`。

### Task 4: 两层侧栏、筛选工作区及编辑入口

**Files:** Create `Sources/OfficeDesktop/Views/Groups/GroupSidebarView.swift`, `GroupEditorView.swift`, `GroupPicker.swift`, `GroupWorkspaceView.swift`; create `Sources/OfficeCore/Groups/GroupContentFilter.swift`; modify `Sources/OfficeDesktop/Views/WorkspaceView.swift`, `TaskEditorView.swift`, `TaskListView.swift`, `Meetings/MeetingWorkspaceView.swift`, `Meetings/MeetingSetupView.swift`, `Meetings/MeetingMinutesView.swift`, `Meetings/MeetingActionsView.swift`；modify `Sources/OfficeDesktop/OfficeAppModel.swift` 传入新服务参数；test `Tests/OfficeCoreTests/GroupContentFilterTests.swift`, `Tests/OfficeDesktopTests/MeetingNavigationTests.swift`。

**Interfaces:**
- `GroupContentFilter.tasks(_: [TaskItem], scope: GroupScope, groups: [WorkGroup], search: String, status: TaskStatus?) -> [TaskItem]`、`meetings(_: [MeetingSession], scope: GroupScope, groups: [WorkGroup], search: String) -> [MeetingSession]`；状态 nil 为全部。
- `GroupPicker(groups: GroupStore, selection: Binding<UUID?>)`，路径标签按父/子排序，包含未分组。
- `GroupSidebarView(groups: GroupStore, selection: Binding<GroupScope>, activate: () -> Void)`；分组工作区 `GroupWorkspaceView(model: OfficeAppModel, scope: GroupScope, openTask: @escaping (TaskItem) -> Void, openMeeting: @escaping (UUID, EvidenceReference?) -> Void)`。
- `GroupEditorView(groups: GroupStore, editingID: UUID?, parentID: UUID?)` 处理新增/重命名/移动，删除由侧栏独立确认。
- 原有 TaskEditorView/TaskListView/MeetingWorkspaceView/MeetingSetupView/MeetingMinutesView/MeetingActionsView 增加默认 nil 的 `groups: GroupStore?`。MeetingWorkspaceView 额外接收 `scope: GroupScope = .all` 与默认归属，scope 不改变控制器实际会话；GroupWorkspaceView 的会议页复用该视图。TaskEditorView 接收的初始 TaskItem 已带当前默认 groupID。

- [ ] **Step 1: Write failing filter and navigation tests.** 父组含直属与子组、子组只含自身、未分组包含已失效 ID；搜索和状态共同生效且行数与统计一致。跨组来源跳转继续通过 MeetingNavigationPolicy；活跃会议冲突保持原行为。分组切换不清空暂存或替换活跃会话。
- [ ] **Step 2: Run** `bash scripts/test.sh --filter 'GroupContentFilterTests|MeetingNavigationTests'`，预期分组筛选符号未实现失败。
- [ ] **Step 3: Implement filter and view interfaces.** 保留旧导航，新增 groups 工作区路由，组选择与旧栏目选择互斥。侧栏 DisclosureGroup 展示两层；菜单和表单调用 GroupStore，禁止第三层目标。删除确认列出子组数量并明确记录保留；当前组删除后回未分组。GroupStore 加载失败显示重试并禁止分组筛选与修改，旧栏目继续可用。
- [ ] **Step 4: Connect creation and movement.** 从具体组创建默认归属；全部/未分组/旧入口默认 nil。候选编辑提供继承默认值与显式覆盖，批量加入走默认继承，会议直接新建待办也继承。已完成待办菜单仍提供移动。会议操作按活跃状态禁用。来源跳转切换到原有全量会议栏目并定位证据，避开当前过滤。
- [ ] **Step 5: Run Step 2 tests and `bash scripts/test.sh`**，预期全部通过。用临时目录、内存仓库和无网络假服务创建预览测试场景，核对窄窗口、中文长名称、两层展开、空组、父组统计、目录加载失败、表单打开后删除组及搜索无结果；记录截图与结果到 `docs/verification/shared-groups.md`，不操作用户真实数据。
- [ ] **Step 6: Commit only this task's changes**：`feat: add shared group navigation and editors`。

### Task 5: 完整回归、文档与安装包

**Files:** Modify `README.md`；create/update `docs/verification/shared-groups.md`；update ignored `dist/OfficeAssistant.app`, `dist/OfficeAssistant-0.3.0-arm64.dmg`, `.dmg.sha256`。

**Interfaces:** 消费任务 1–4 的完整应用，不新增业务 API；交付保留现有命名的 Apple Silicon 应用和 DMG。

- [ ] **Step 1: Run** `bash scripts/test.sh`（仅任务 4 后有改动或检查未解决时重跑），所有 Swift Testing 用例通过，无分组导致的原有会议删除、音频导出、重复待办及纪要重试回归。
- [ ] **Step 2: Update README and verification record.** 说明两层分组、父组汇总、会议纪要归属、待办继承、移动限制、删除保留内容、目录损坏恢复与 groups.json 备份；区分自动测试、界面核对及未验证环境。
- [ ] **Step 3: Run** `bash scripts/build-app.sh`，确认发布构建完成、应用签名有效。使用 TemporaryDirectory 与 ditto 建立只含最新 app 和 Applications 链接的镜像源，hdiutil 生成 UDZO DMG。
- [ ] **Step 4: Verify artifact.** hdiutil verify 成功；只读挂载检查 codesign `--verify --deep --strict`，镜像内主程序与 dist app 字节一致，Applications 链接目标为 `/Applications`；卸载后更新 SHA-256 文件。
- [ ] **Step 5: Commit only documentation and remaining feature changes**：`docs: document shared groups verification`。最终提供 DMG 链接、入口与验证结论；提醒退出旧应用后更新，保留用户现有数据。

## 执行衔接

本计划是同一分组功能的连续五项任务，依赖统一模型与服务接口，建议在当前会话原生执行；最终独立审阅需使用可用审阅代理并遵守模型与委派限制。另一可选方法是分任务实现与独立审阅。用户审阅计划并选择方法后执行。

本环境当前未发现 `superpowers:executing-plans` 或 `superpowers:subagent-driven-development` 的 SKILL.md。开始实现前必须先解决所选方法的技能可用性；若用户明确授权按本计划直接实现，其指令优先于技能的执行工具要求。
