# Desktop Office Assistant Stage C Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将会议转写、可编辑会议纪要、行动项审阅、正式待办及纪要导出连成同一流程，支持会议与待办双向查看。

**Architecture:** 复用现有 MeetingSessionController、TaskStore、Core Data 和凭证/网络适配。纪要生成独立于实时翻译开关，会议记录保存纪要版本及候选，TaskItem 保存来源关系和加入凭据；任务库是完成状态的唯一来源。纪要生成、关联和导出分别由小型服务负责，不继续把所有职责加入录音控制器。

**Tech Stack:** SwiftUI、Foundation、Core Data、CryptoKit（仅 Desktop）、Security、URLSession、AppKit NSSavePanel、Swift Testing；macOS 14+，不新增依赖。

**Spec:** [用户已确认的整体设计](../specs/2026-11-02-office-assistant-design.md)，尤其“纪要与自动提取待办”和“阶段 C”。补充本轮用户明确提出的双向关联：支持关联已有待办，会议页显示任务实际状态，待办可回到来源会议。沿用已选 Native，不重新询问执行方式。

## Global Constraints

- 中文界面，默认中文纪要；导出中文或中日双语 Markdown / UTF-8 纯文本，文件位置由用户选择。
- 纪要只使用已保存的最终原文，不把临时字幕或译文当作事实依据。仅转写会议也可单独点击生成纪要，不要求启用翻译。
- 原文和有限的必要会议信息只发送给本次明确选中的纪要服务；不发送其他会议、整个待办库或账号秘密。
- 纪要服务支持 OpenAI / DeepSeek / 硅基流；默认使用当前保存的文字服务及模型。本机已验证的 OpenAI 文字模型为 gpt-5.4-mini，不能自动改模型或账号。
- 候选不是正式待办。加入前集中审阅，允许修改、忽略、批量确认或关联已有任务；缺失负责人/精确时间不能伪造。
- 不猜测发言者；问题、假设、否定和已完成事项不得直接创建新任务。所有 AI 结果均可核对原文。
- 纪要保留版本。重新生成不覆盖人工修改或改写已加入的任务；修改原文后标记旧结果需要重新核对。
- 旧 tasks.store / meetings.store 及 0.2.1 设置必须可读；新 TaskItem 字段使用可选数组，无损坏数据重置或自动清库。
- 原有完成/撤销、重复、提醒、仅转写和上传停止行为保持。来源关系不能被旧编辑表单意外覆盖。
- 关闭/切换会议不允许旧作业写入另一会议。取消、鉴权/权限错误、JSON 不完整及磁盘失败保留旧纪要与任务。
- 当前没有 Git 仓库，不初始化、提交、推送或发布。目标本地应用版本 0.3.0，构建号 4。

## Review Focus

1. 加入成功后会议库保存失败、重启、重复点击及重复生成：不重复创建，不覆盖用户改过的任务（Task 2/4）。
2. 作业期间切换会议、校对原文或手改纪要：旧结果不能写错会议，也不能静默替换新内容（Task 1/3）。
3. 否定/假设、未知负责人、导入录音日期未知，以及跨午夜的“明天”：保留不确定性，不凭当前电脑日期猜截止时间（Task 2/3）。
4. 旧任务编辑器、已完成或重复任务、手动解除关联：来源与加入凭据不丢失，完成状态不分叉（Task 2/4）。
5. 长转写、恶意指令、无效引用、Unicode/Markdown、导出取消及写盘失败：不丢尾部、不执行原文指令、不回显秘密、不产生半份导出（Task 3/5）。

## 文件与职责

```text
Sources/OfficeCore/Meetings/MeetingMinutes.swift          纪要、依据、候选与生成选项值类型
Sources/OfficeCore/Meetings/CandidateRules.swift          本地候选校验、合并与保守去重
Sources/OfficeCore/Meetings/MeetingDeadlineResolver.swift 相对时间及未知会议日期处理
Sources/OfficeCore/Meetings/MinutesExportRenderer.swift   纯文本/Markdown 序列化
Sources/OfficeCore/TaskItem.swift                        可选来源关系和加入凭据
Sources/OfficeCore/TaskRules.swift                       重复实例继承来源及凭据
Sources/OfficeDesktop/Meetings/MinutesRepository.swift   新记录前缀及 Core Data 读写
Sources/OfficeDesktop/Meetings/MinutesCoordinator.swift  生成作业、快照、版本及取消
Sources/OfficeDesktop/Meetings/MeetingTaskLinkService.swift 正式任务加入、已有任务关联
Sources/OfficeDesktop/AI/Minutes/MinutesGenerator.swift   三家服务的结构化请求与返回校验
Sources/OfficeDesktop/AI/Minutes/MinutesPrompt.swift      schema、提示与分块归并
Sources/OfficeDesktop/Meetings/MinutesFileExporter.swift 保存窗口及原子文件写入
Sources/OfficeDesktop/Views/Meetings/MeetingMinutesView.swift 纪要阅读、校对、版本和生成入口
Sources/OfficeDesktop/Views/Meetings/MeetingActionsView.swift 候选审阅与相关待办
```

修改现有 MeetingRepository、MeetingSessionController、MeetingWorkspaceView、TaskStore、TaskEditorView、TaskListView、WorkspaceView、OfficeAppModel、Info.plist、README；沿用 ProviderTransport/CredentialStore。测试按下列 task 新增，既有 86 项保留。

### Task 1: 纪要、候选和版本持久化

**Files:** Create MeetingMinutes.swift、MinutesRepository.swift、Tests/OfficeDesktopTests/MinutesPersistenceTests.swift；Modify MeetingRepository.swift。

**Interfaces:**
- `MinutesLanguage: chinese | chineseJapanese`；`MinutesOptions: Codable` 含 provider、model、language、timeZoneID、referenceDate: Date?，无密钥。导入音频的实际会议日期默认未知，用户可显式填写；现场录音使用 meeting.startedAt。
- `EvidenceReference` 含 segmentID、revision、quote、UTF-16 起点/长度；引用只指向同场会议的已定稿片段。
- `MinutesPoint` 含本地 UUID、textZH、textJA: String?、evidence；`MinutesDocument` 含 id、meetingID、revision、createdAt、sourceFingerprint、options、overviewZH、overviewJA: String?、topics、decisions、openQuestions、editedByUser。每个已保存版本使用新 UUID；协调器分配递增 revision，已有版本不能原地改写。
- `ActionCandidate` 含本地稳定 id、meetingID、titleZH/titleJA、owner: String?、dueText: String?、dueAt: Date?、timeZoneID、evidence、clarifications: [CandidateClarification]、reviewState、acceptedTaskID: UUID?。CandidateClarification 为 owner/deadline/commitment/meetingDate/possibleDuplicate/sourceChanged；reviewState 为 proposed/ignored/accepted，没有自动加入状态。
- `MinutesSnapshot` 含固定 meetingID/标题/备注/时间、最终片段及 revision，整体 fingerprint 由 Desktop 对规范 JSON 做 SHA-256。
- `MinutesJobRecord` 含 id、meetingID、options、sourceFingerprint、startedAt、status（running/completed/failed/cancelled/stale/interrupted）及安全错误。启动时将残留 running 标为 interrupted，不自动重新发送请求。
- `@MainActor protocol MinutesRepository`：`documents(meetingID:) throws -> [MinutesDocument]`、`candidates(meetingID:) throws -> [ActionCandidate]`、`save(document:candidates:) throws`、`saveCandidates(_:meetingID:) throws`、`jobs(meetingID: UUID?) throws -> [MinutesJobRecord]`（nil为全部）、`saveJob(_:) throws`。CoreDataMeetingRepository 同时实现该协议，使用独立前缀 `n.<meetingID>.<documentID>`、`a.<meetingID>.<candidateID>`、`j.<meetingID>.<jobID>`，一次 context.save 保存新版本及候选。

- [ ] **Step 1:** 写 `testMinutesRoundTripAfterReopen`（纪要/双语/引用/候选全部字段相等）、`testVersionSaveIsAtomic`（保存失败时旧纪要与候选不变）、`testUnknownMinutesSchemaDoesNotEraseMeetings`（未知版本拒绝读写，旧转写仍在）、`testCandidateRoundTripKeepsStableID`。
- [ ] **Step 2:** `bash scripts/test.sh --filter MinutesPersistenceTests`，确认新接口缺失导致失败。
- [ ] **Step 3:** 实现上述类型及仓储；将 MeetingRepository.swift 的泛型 put/records 改为模块内可用，仅供新仓储扩展复用，不改变数据库实体和已有记录前缀。
- [ ] **Step 4:** 同命令通过；用临时磁盘库保存后重开，旧 tasks/meeting/segment 记录也能读取。损坏数据不得用空数组冒充成功。

### Task 2: 双向关系、幂等加入与时间规则

**Files:** Create CandidateRules.swift、MeetingDeadlineResolver.swift、MeetingTaskLinkService.swift、Tests/OfficeCoreTests/CandidateRulesTests.swift、MeetingDeadlineTests.swift、Tests/OfficeDesktopTests/MeetingTaskLinkTests.swift；Modify TaskItem.swift、TaskRules.swift、TaskStore.swift。

**Interfaces:**
- `TaskMeetingLink` 含 meetingID、meetingTitleSnapshot、candidateID: UUID?、evidence；同场会议同 candidateID（手动为 nil）的关系只存一份。
- `MeetingActionReceipt` 含 meetingID、candidateID、joinedAt；`TaskItem.meetingLinks: [TaskMeetingLink]?` 和 `meetingActionReceipts: [MeetingActionReceipt]?` 新增为可选字段。解除来源关系不删除加入凭据。
- `TaskStore.linkMeeting(taskID:link:) throws`、`unlinkMeeting(taskID:meetingID:) throws` 读取当前快照后只改关系；已完成任务也可关联，不调用会拒绝已完成状态的通用 upsert。
- `TaskStore.acceptMeetingAction(_ draft: TaskItem, candidateID: UUID, link: TaskMeetingLink, at: Date) throws -> TaskItem`：先查全库 receipt，有则返回现任务、不改标题/时间/状态。新任务固定使用本地 candidateID 作为 TaskItem.id；若该 ID 已被不匹配的任务占用则报错，禁止覆盖。任务及 receipt 同一次 task commit。
- `TaskStore.associateMeetingAction(taskID: UUID, candidateID: UUID, link: TaskMeetingLink, at: Date) throws -> TaskItem` 同一次 commit 追加已有任务的来源和 receipt，保留其可编辑字段。`MeetingTaskLinkService.accept(_ candidate: ActionCandidate, editedTask: TaskItem) throws -> UUID` 先提交任务，再更新会议候选 acceptedTaskID；第二步失败后通过任务 receipt 恢复。`associate(candidate:existingTaskID:)` 使用上述专用方法关联已有任务，不创建副本。
- TaskStore.upsert 编辑已有任务时始终保留当前存储的关系/receipt，避免旧表单丢边；关系只能通过专用方法修改。重复任务下一实例继承关系/receipt，原有撤销规则继续验证实例是否被修改。
- `CandidateRules.reconcile(existing:proposed:linkedTasks:) -> [ActionCandidate]`：同依据和规范化标题精确匹配复用旧 id/审阅状态；已加入的候选保持原样。与已有候选或关联任务共享依据且规范化标题二元组相似度 >=0.7 的标为 possibleDuplicate，加入前必须选择“关联已有”或明确确认是独立事项；不自动覆盖或自动加入。
- `MeetingDeadlineResolver.resolve(_ text: String?, reference: Date?, evidenceOffset: Double, timeZoneID: String) -> DeadlineResolution`：以实际会议时间加发言偏移为参考；复用 QuickEntryParser，先将受支持的日语时间短语规范为中文（今日/明日/明後日、来週的星期、午前/午後、時/分）。无真实会议日期、只有日期/时段或无法解析时 dueAt=nil，保留原文并标记需确认；不默认生成 09:00 等精确时刻。

- [ ] **Step 1:** 写断言：`testLegacyTaskWithoutLinksDecodes`（旧 payload 可读）；`testLinkExistingCompletedTaskKeepsFields`；`testUnlinkKeepsReceipt`；`testStaleEditorCannotEraseLink`；`testRepeatInheritsMeetingSource`；`testReceiptPreventsDuplicateAfterMeetingSaveFailure`（模拟第二库失败后重试，任务数仍 1）；`testIDCollisionCannotOverwriteUnrelatedTask`；`testReextractPreservesAcceptedUserEditedTask`。
- [ ] **Step 2:** 时间测试固定时钟与时区：上海 2026-11-03 23:59 的“明天下午三点”=11月4日15:00；偏移120秒后同句=11月5日15:00；未知导入日期 dueAt=nil；“明天下午”/“来週金曜日まで”无精确时刻不设提醒；东京“明日の午後3時”得到该时区15:00。重复生成不能用重试发生日重算。
- [ ] **Step 3:** `bash scripts/test.sh --filter 'CandidateRulesTests|MeetingDeadlineTests|MeetingTaskLinkTests'` 确认失败，再实现接口。缺失 owner 不自动填自己的姓名；候选审阅可明确保留未指定和无到期提醒。
- [ ] **Step 4:** 同命令通过；关联状态从 TaskStore 实时读取，不能另存一份“会议完成状态”。任务已删除时显示已删除，不能仅因重新生成纪要就自动重建。

### Task 3: 有依据的纪要与候选生成

**Files:** Create MinutesGenerator.swift、MinutesPrompt.swift、MinutesCoordinator.swift、Tests/OfficeDesktopTests/MinutesGeneratorTests.swift、MinutesCoordinatorTests.swift；Modify OfficeAppModel.swift、MeetingSessionController.swift。

**Interfaces:**
- `@MainActor protocol MinutesGenerating { func generate(snapshot: MinutesSnapshot, options: MinutesOptions) async throws -> MinutesGenerationResult }`；结果为 document: MinutesDocument 及 candidates: [ActionCandidate]，不含正式 TaskItem。AI 不提供本地 UUID，全部由本地生成并 reconcile，保存前由协调器分配 revision。
- `MinutesCoordinator.generate(meetingID: UUID, options: MinutesOptions) async throws`、`cancel(meetingID: UUID)`、`saveEdit(_ document: MinutesDocument) throws`；saveEdit 从编辑草稿复制为新 UUID/递增 revision、editedByUser=true，不覆写旧版本。以 meetingID 绑定作业，一个应用只运行一个纪要作业；网络发送前持久化 running 作业，失败保存安全状态。AppModel 将同一 CoreDataMeetingRepository 实例传给录音控制器和纪要协调器。
- 录音/连接/收尾中不能生成最终纪要；停止或暂停后由用户点击。无最终原文拒绝生成；有暂存音频或转写缺口时明确说明本次只涵盖已保存内容。
- 首次选项默认当前文字服务和对应已保存模型，用户可独立选择 OpenAI/DeepSeek/硅基流。仅生成时读取所选服务密钥，不检查翻译开关。配置快照绑定作业；切换会议只影响浏览，不更改作业对象，取消后旧回调不能提交。
- OpenAI Chat Completions 使用 strict JSON schema、max_completion_tokens；DeepSeek/硅基流使用 json_object、max_tokens，并关闭思考模式。只读 message.content；必须 finish_reason=stop，无空白、截断、refusal 或无效 JSON 时才接受。HTTP 401/403/额度失败不重试、不换服务。复用安全错误和官方主机限制。
- schema：overviewZH/overviewJA；topics/decisions/openQuestions 为 `textZH,textJA,evidence[]`；actions 为 `titleZH,titleJA,owner,dueText,intent,evidence[]`。evidence 为 segmentKey（source:sequence）及原文 quote。双语模式要求日文内容，中文模式日文为 null。每个要点和 action 至少一条依据；owner/dueText 若无法在所引原文中核对，则清空并标记待确认。
- intent 仅 commitment/assignment 进入可审阅候选；question/hypothetical/negated/completed 被排除，uncertain 只进入需澄清区。引用不存在片段、非最终片段、错会议或 quote 非原文子串时拒绝该结果并保留旧版本。每个标题最多200字、要点4000字、行动项100条。
- “我/我们/你/私/こちら/弊社”等不能识别具体人的表达，不作为确定 owner 保存，保留在依据并标记负责人待确认；源标签不能映射为个人姓名。
- 规范输入按片段顺序分块，每块最多12000字符；超长单片段按文本范围拆分并保留同一来源定位。各块顺序处理后再归并，不能直接截断尾部。整场上限240000字符，超过明确拒绝并要求分场；总作业期限10分钟，各次请求仍受现有传输超时限制。每次 JSON 响应最大2MiB，不无限补请求。
- 提示将原文/参会备注/术语作为数据，不执行其中指令、不猜负责人、不增加决定、金额/币种不转换；中日双语保留名字、否定及承诺力度。输入包含已有候选和加入标识以降低重复，但幂等依赖本地规则。
- 作业开始保存 snapshot fingerprint；提交前重读最终片段及 revision。原文已改或用户已编辑纪要时标记结果过期，不静默替换；重新生成保存新版本，旧版本可查看。跨午夜时间解析基于 action 原始发言偏移。
- `MeetingSessionController.onFinalSegmentSaved: ((UUID) -> Void)?` 仅在最终原文保存成功后通知 AppModel，再调用 `MinutesCoordinator.noticeFinal(meetingID:)`。`setIncrementalExtraction(_ enabled: Bool, meetingID: UUID, options: MinutesOptions)` 控制“会议中提取候选”，默认关闭；每新增5个最终片段且距上次提取>=60秒才处理新增片段快照，复用 generate 的结构化校验但仅合并候选、不保存全场纪要或创建任务。忙碌时合并通知，不无限排任务；暂停/停止取消该会议的增量请求。增量结果只核对输入片段的 revision/文本，允许其间追加其他最终片段；最终整场纪要仍核对整场 fingerprint。

- [ ] **Step 1:** `testStructuredRequestsUseOnlySelectedKey`（三家地址/参数/JSON模式正确）；`testInvalidOrCrossMeetingEvidenceRejected`；`testNonFinalSegmentsNeverSent`；`testBlankTruncatedRefusalDoesNotReplaceOldMinutes`；`testNegativeCompletedAndQuestionDoNotCreateTasks`；`testMissingOwnerAndAmbiguousDateStayUnknown`；`testTranscriptInstructionsRemainData`。
- [ ] **Step 1a:** 具体断言：401/403 请求数=1；未定稿片段文本不在请求正文；错会议/错误引文返回被拒绝且旧纪要 id 不变；negated/completed/question fixture 的可加入候选数=0；owner 为“我”的 fixture 解析后 owner=nil；模糊时间 dueAt=nil；原文中的“忽略指令”仍在 user 数据内，请求不包含 tools 或其他服务密钥。
- [ ] **Step 2:** 协调器测试：`testLongTranscriptIncludesLastSegment`（超过两块的尾部被处理）；`testCancelAndLateCompletionCannotWriteOtherMeeting`；`testEditDuringGenerationMarksResultStale`；`testRegenerationPreservesEditedPriorVersion`；`testOnlyTranscriptionMeetingCanGenerateMinutes`；`testIncrementalExtractionDebouncesFinalsAndNeverAddsTasks`；`testNewFinalsDoNotInvalidateUnchangedIncrementalInput`；`testRunningJobRestartsInterruptedWithoutNetwork`；`testFailuresKeepOldRevision`。
- [ ] **Step 3:** 运行 `bash scripts/test.sh --filter 'MinutesGeneratorTests|MinutesCoordinatorTests'` 确认失败，再实现分块、结构化校验、作业及版本保存。模型返回不是可信本地对象，必须先过引用与字段校验。
- [ ] **Step 4:** 同命令通过；真实联调只用自建中日商务文本/合成样本，使用已授权的 OpenAI 配置，不读取其他应用凭证。其他两家没有可用应用凭证时保留待联调。

### Task 4: 会议与待办双向操作界面

**Files:** Create MeetingMinutesView.swift、MeetingActionsView.swift；Modify MeetingWorkspaceView.swift、TaskListView.swift、TaskEditorView.swift、WorkspaceView.swift、OfficeAppModel.swift；Create Tests/OfficeDesktopTests/MeetingNavigationTests.swift。

**Interfaces:**
- 会议详情增加“转写 / 会议纪要 / 相关待办”页签。纪要页提供生成、取消、编辑、历史版本和行动项审阅；没有最终原文或正在收音时禁用最终生成。
- 行动项卡片显示标题、负责人、原始时间、解析结果、需确认字段、依据音源/时间及原文引文；支持逐项修改、忽略、批量确认加入、关联已有任务。无明确时间可选择暂不提醒，不能因为缺失时间而默认造日期。
- “相关待办”从 TaskStore 按 meetingLinks 查询，显示实际待处理/进行中/已完成，复用现有完成/撤销操作。支持从该会议手动新建任务、关联已有任务（含已完成）和解除来源关系；解除不删除任务或加入凭据。
- `OfficeAppModel.openMeeting(id: UUID, evidence: EvidenceReference?) throws` 为来源跳转入口。TaskListView 增加来源标签按钮，已完成事项也能查看来源。TaskEditorView 展示来源及引文，不把它们混入普通备注字段；修改任务正文不会改写来源。
- 同一会议录音中可跳到本会议；若另一个会议正在记录，则提示先暂停/结束，不自动停止、不丢当前缓冲。来源会议不存在时显示标题快照及“来源会议不可用”，任务仍可编辑/完成。
- 新编辑器以独立 @State 初始化所选对象，避免首开空白；离开有未保存编辑的纪要前需保存/取消，生成新版本不覆盖编辑草稿。

- [ ] **Step 1:** 写 `testMeetingTaskStatusUsesTaskStore`（完成/撤销后相关待办状态分别=completed/pending）、`testSourceNavigationUsesMeetingIDAndSegment`（目标 UUID 和 evidence.id 均相等）、`testOtherActiveMeetingIsNotStoppedByNavigation`（原会议 state=recording，stop 调用数0）、`testMissingMeetingKeepsTaskUsable`（来源不可用但完成可保存）、`testManualAssociationIsIdempotent`（两次关联后关系数1、任务数不变）；验证已有 ReminderCoordinator 变更回调仍安排或取消通知。
- [ ] **Step 2:** `bash scripts/test.sh --filter 'MeetingNavigationTests|MeetingTaskLinkTests|ReminderCoordinatorTests'` 确认失败，再实现视图和导航回调。多来源任务按会议分组，不猜发言者。
- [ ] **Step 3:** 同命令通过；打包实机验证从纪要加入、从会议查看状态、从今日/已完成返回来源、关联已有、重复点击不重复、仅转写会议生成纪要和首次打开编辑器有内容。

### Task 5: 可离线导出的纪要与完整交付

**Files:** Create MinutesExportRenderer.swift、MinutesFileExporter.swift、Tests/OfficeCoreTests/MinutesExportTests.swift、Tests/OfficeDesktopTests/MinutesFileExportTests.swift；Modify MeetingMinutesView.swift、Support/Info.plist、README.md；Create docs/verification/stage-c.md。

**Interfaces:**
- `MinutesExportFormat: markdown | plainText`；`MinutesExportRenderer.render(document: MinutesDocument, candidates: [ActionCandidate], linkedTasks: [TaskItem], language: MinutesLanguage, format: MinutesExportFormat) throws -> String`。输入是点击导出时固定的本地版本和该会议相关任务快照，不读取凭证或调用 AI。
- 内容：标题/时间/参会备注、议题摘要、决定、未解决问题、行动项（负责人、截止时间/待确认、真实任务状态）、来源音源/时间及原文引文。默认不附整份转写，不导出配置或凭证。
- 中文/双语模式可选；没有双语内容时提示先生成双语版本，不能导出时静默发起翻译。Markdown 转义原文的 HTML/图片/链接标记，纯文本不残留格式标记，均保持 Unicode 和明确币种。
- `@MainActor protocol MinutesSaveDestinationChoosing` 定义 `choose(suggestedName: String, format: MinutesExportFormat) async throws -> URL?`，实机实现使用单一 NSSavePanel，测试注入假选择器，不弹实际窗口。`MinutesFileExporter.export(text: String, suggestedName: String, format: MinutesExportFormat) async throws -> URL?` 取得目的地后调用内部 `write(_ text: String, to: URL) throws`；取消返回nil。文件名过滤路径分隔符、控制字符并限制100字符；UTF-8原子写入，权限/磁盘失败明确报错并保留旧文件。新建/覆盖由保存窗口确认，不发送邮件或上传网盘。

- [ ] **Step 1:** Core 的 MinutesExportTests 覆盖 `testChineseAndBilingualExportContainSectionsAndEvidence`、`testOnlyMeetingLinkedTasksExported`、`testCompletedStatusComesFromTaskSnapshot`、`testUnknownOwnerAndDateAreNotInvented`、`testMarkdownImagesAndHTMLAreEscaped`。Desktop 的 MinutesFileExportTests 覆盖 `testUTF8JapaneseAndCurrencyRoundTrip`、`testCancelDoesNotWriteFile`、`testWriteFailurePreservesExistingFile`，在临时目录实际写入再重读。
- [ ] **Step 2:** `bash scripts/test.sh --filter 'MinutesExportTests|MinutesFileExportTests'` 确认失败，再实现渲染与保存。导出纯本地操作，不需要新的账号、Python 或文档依赖。
- [ ] **Step 3:** 全量 `bash scripts/test.sh`，保留既有86项；`bash scripts/build-app.sh`；`plutil -lint dist/OfficeAssistant.app/Contents/Info.plist`；`codesign --verify --deep --strict dist/OfficeAssistant.app`，均须退出码0。版本0.3.0/构建4。
- [ ] **Step 4:** 使用非私人中日样例验证：明确指派、否定、已完成、模糊时间、跨午夜、相同事项重复出现。实际 OpenAI 生成纪要→编辑→加入/关联待办→完成→回溯原文→导出并打开 .md/.txt，核对文件内容、双语、来源和状态。只标记真实执行过的服务/入口通过。
- [ ] **Step 5:** Native 完成后独立审查，修复实际的数据丢失、串会议、秘密回显、重复创建、静默覆盖等问题并补回归；更新操作说明与 stage-c.md，交付本地 .app。

## 官方依据与自审

接口依据（2026-11-03已读取）：[OpenAI 结构化输出](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=chat)、[DeepSeek JSON Output](https://api-docs.deepseek.com/guides/json_mode/)、[硅基流 Chat Completions](https://docs.siliconflow.cn/docs/api/chat-completions-post)。JSON格式约束不能证明事实正确，证据校验与人工审阅仍由本地流程负责。

自审映射：原文依据/版本→Task1/3；关联已有、双向来源、幂等与任务独立状态→Task2/4；明确/模糊时间及跨日→Task2；中文/双语纪要与导出→Task3/5；仅转写可单独生成纪要→Task3/4；原有提醒、重复任务、数据与上传生命周期回归→Task2/4/5。五条 Review Focus 均有具体测试。跨会议聚合报告、Word/PDF、对外自动发送和会议删除界面不在这份阶段C计划中；来源缺失的防守行为仍实现并测试。

## 执行交接

整体书面设计及本计划均已获用户“可以”确认，按 Native 实施，不重选执行方式，不重新询问密钥复用。

## 执行记录（2026-11-04）

- Task 1–3：类型、仓储、幂等关联、时间解析、结构化生成及协调器已实现。实际测试名称及验证范围见 `docs/verification/stage-c.md`，其中若干计划断言合并在同一测试内；不将未执行的逐条红阶段命令视为已运行。
- Task 4：界面与双向导航已实现。解锁后完成OpenAI仅转写样本导入、中文/双语生成、加入/关联已有完成任务、完成/撤销、独立修改任务、从已完成清单回溯并高亮原文的实机链路。
- Task 5：本地导出、UTF-8 原子写入、版本0.3.0/build4、说明与验证记录已实现。113项测试通过，实际保存并读取中文.md及双语.txt，核对实际任务状态、修改后标题、未确定日期及来源；人工版本在重新生成后仍可查看。最终打包、签名与服务验证边界见验证文档。
- 独立审查完成；修复完整生成残留取消候选、增量迟到片段遗漏、跨段候选未经全场核对即可批量加入、修改后双语标题误配四项 P2，复核无新增 P1/P2。
- 跨段取消的保守处理：多块/增量候选必须逐项阅读全场后确认，禁止批量加入，服务层也拒绝未确认标记；当前不声称完成全场语义归并。该限制在界面与 README 中明确。
