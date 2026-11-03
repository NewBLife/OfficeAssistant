# Desktop Office Assistant Stage B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 Mac 应用中接入面对面/线上会议收音、音频导入、中日字幕和商务翻译，支持 OpenAI、DeepSeek、硅基流、微软 Azure Speech 与阿里云通义听悟。用户已有的前三家账号按复用处理。

**Architecture:** 保留阶段 A 的待办服务；新增独立会议存储、统一音频帧、按能力划分的语音与翻译协议，以及管理录音/网络/字幕生命周期的会话控制器。识别与翻译分别选择服务商，字幕通过稳定片段标识更新，音频与网络任务不阻塞主线程。

**Tech Stack:** SwiftUI、Core Data、AVFoundation/AVAudioEngine、ScreenCaptureKit、CoreAudio、Security、URLSession WebSocket/HTTP/SSE、Swift Testing；macOS 14+。新增一项服务商官方依赖：Microsoft Speech SDK 1.52.0，仅使用 macOS 产品；其余模块不安装外部依赖。

**Spec:** [已确认的整体设计](../specs/2026-11-02-office-assistant-design.md)，以及本计划“服务商与凭证决策”。阶段 C 的纪要、AI 行动项提取和导出不包含在 B 中。

## Global Constraints

- 中文界面；实时翻译以字幕输出，包含日语到中文和中文到商务日语。
- 支持面对面沟通和电脑线上会议两种收音场景。
- 初始部署目标为 macOS 14 及以上；最低版本支持需要实际编译与相应环境验证，不能仅凭当前机器宣称已验证。
- 历史记录保存在本机。不是完全离线产品。凭证放系统钥匙串，不进入数据库、日志或导出文件。
- 暂停或停止后立即停止相应音频上传。重启后显示中断会议，不自动开始录音。
- 断网时保留已完成内容，使用最多 60 秒的有界本地音频缓冲；达到上限自动暂停采集并明确提示。
- 原文区分临时片段与已定稿片段；译文显示处理中、已完成或需重试。
- 不承诺零延迟。正常网络下，明确句段结束后译文出现的 P95 不超过 5 秒是测试目标；未达到时报告实测值。
- 不展示不存在的置信度分数；音源标签不是人员身份，不猜测发言者。
- 没有凭证时只能标记云端功能待联调，不能把模拟结果当作真实识别或翻译。
- 当前工作目录没有 Git 仓库；不为本阶段主动初始化、推送或发布。用户已选择 Native 执行，并保留完成后的独立审查。

## 服务商与凭证决策

用户已说明三家 API 密钥均已有，按复用现有账号处理，不新建密钥，不要求在聊天中提供。实现完成后，由用户在应用的安全输入框分别录入并点击保存；本阶段不会自动读取其他应用的密钥、写入 env 文件或替用户创建账号。

| 服务商 | 语音识别接入 | 文字翻译接入 | 初始模型设置 |
|---|---|---|---|
| OpenAI | 实时 WebSocket；已录音用文件接口 | Chat Completions SSE | 实时 `gpt-live-transcribe`，文件 `gpt-transcribe`，翻译 `gpt-4.1-mini` |
| DeepSeek | 当前不列为语音识别选项 | Chat Completions SSE，关闭思考模式 | `deepseek-flash` |
| 硅基流 | 文件接口，直播时切短片段连续上传 | Chat Completions SSE | 识别 `FunAudioLLM/SenseVoiceSmall`，翻译 `deepseek-ai/DeepSeek-V4-Flash` |
| 微软 Azure Speech | 官方 SDK 连续识别（本阶段仅实时入口） | 不纳入 B 的文字翻译选择 | 使用 Speech 服务内置识别模型，按所配资源区域连接 |
| 阿里云通义听悟 | 建立实时任务后 WebSocket 推流（本阶段仅实时入口） | B 先沿用独立文字翻译链路 | `CreateTask` 实时任务；日语/中文或显式多语言配置 |

新增两家的凭证与原三家分开：Azure Speech 需要 Speech 资源密钥和资源区域；通义听悟使用 AccessKey ID、AccessKey Secret、项目 AppKey，可选 STS SecurityToken。现有 OpenAI/DeepSeek/硅基流密钥不能作为这两家的凭证。由用户在应用里录入，不要求在聊天里提供，不自动开通服务、创建云资源或扩展账号权限。

以上为经官方资料确认的初始配置，不保证各账号具有模型访问权限；设置允许编辑模型 ID，并支持主动刷新该账号模型列表。模型不存在或无权限时明确报错，不静默换模型、账号或服务商。

推荐初始组合：OpenAI 识别 + DeepSeek 翻译。用户可以选择 OpenAI 全流程，或四家识别中的任一家搭配原三家翻译。文件导入的识别选项保持 OpenAI/硅基流；Azure/听悟本阶段针对用户此次要求新增实时入口，不使用未实现的离线流程或自动上传到 OSS。硅基流直播显示“分段识别”，不会冒充原生音频流式接口。原文音频只发给选中的识别服务；原文和有限上下文只发给选中的翻译服务。运行中更换服务或语言需先停止当前会话。

官方依据：[OpenAI 流式转写](https://developers.openai.com/api/docs/guides/realtime-transcription)、[文件转写](https://developers.openai.com/api/docs/guides/speech-to-text)、[翻译文字模型](https://developers.openai.com/api/docs/models/gpt-4.1-mini)；[DeepSeek 模型输入类型](https://api-docs.deepseek.com/api/list-models/)、[当前模型](https://api-docs.deepseek.com/quick_start/pricing/)、[关闭思考模式](https://api-docs.deepseek.com/guides/thinking_mode/)；[硅基流音频接口](https://docs.siliconflow.cn/docs/api/audio-transcriptions-post)、[文字接口](https://docs.siliconflow.cn/docs/api/chat-completions-post)、[模型列表](https://docs.siliconflow.cn/docs/api/models-get)。SenseVoice 项目列有日语能力，实际托管效果仍需样本检验：[项目资料](https://github.com/QwenAudio/SenseVoice)。

## Review Focus

1. 暂停、停止或换会话后到达的旧回调：不继续上传、不串字幕、不覆盖已保存的新内容，Task 3/4/6。
2. 双音源乱序、重复事件与重试：片段顺序稳定，音源分开，重复完成事件不重复保存，Task 2/4/5。
3. 断网、鉴权/额度失败及处理速度慢于收音：缓冲严格有界，明确暂停/恢复，不无限重试或无限开任务，Task 4/6。
4. 空密钥、保存失败、重定向及服务端错误回显：保留原密钥，错误与日志不泄露凭证，Task 1/5。
5. 阶段 A 数据、音频设备消失、坏文件及长期中断：待办库保持可读，已有转写不丢失，恢复不自动采集，Task 2/3/6/7。

## 文件结构

```text
Sources/OfficeCore/AI/{ProviderConfiguration,ProviderCapabilities}.swift
Sources/OfficeCore/Meetings/{MeetingModels,TranscriptReducer,AudioSegmenter,AudioBacklog}.swift
Sources/OfficeDesktop/AI/{CredentialStore,KeychainCredentialStore,AISettingsStore,ProviderTransport,ProviderModelClient}.swift
Sources/OfficeDesktop/AI/Transcription/{SpeechRecognizer,OpenAIRealtimeRecognizer,FileSpeechRecognizer,AzureSpeechRecognizer,AzureSpeechBridge,TingwuSpeechRecognizer,TingwuTaskClient,AlibabaRequestSigner}.swift
Sources/OfficeDesktop/AI/Translation/{TextTranslator,ChatCompletionTranslator,SSEDecoder,TranslationPrompt}.swift
Sources/OfficeDesktop/Audio/{AudioCapture,MicrophoneCapture,SystemAudioCapture,AudioFileReader,PCMConverter}.swift
Sources/OfficeDesktop/Meetings/{MeetingRepository,CoreDataMeetingRepository,MeetingSessionController}.swift
Sources/OfficeDesktop/Views/Meetings/{MeetingWorkspaceView,MeetingSetupView,TranscriptView}.swift
Sources/OfficeDesktop/Views/AISettingsView.swift
Tests/OfficeCoreTests/{ProviderConfigurationTests,TranscriptReducerTests,AudioSegmenterTests,AudioBacklogTests}.swift
Tests/OfficeDesktopTests/{CredentialStoreTests,MeetingPersistenceTests,PCMConverterTests,AudioFileReaderTests,SpeechRecognizerTests,AzureSpeechRecognizerTests,TingwuRecognizerTests,AlibabaRequestSignerTests,TranslationTests,MeetingSessionTests}.swift
Tests/OfficeDesktopTests/Support/{FakeTransport,FakeCapture,FakeCredentials}.swift
```

新增官方 SDK 会修改 `Package.swift`，生成并保留 `Package.resolved`，构建脚本嵌入并签名官方 macOS framework。还会修改 `OfficeAppModel.swift`、`WorkspaceView.swift`、`SettingsView.swift`、`AppDelegate.swift`、`Support/Info.plist`、README 与 `docs/verification/stage-b.md`。不改待办库的数据模型。Core 的值类型继续只依赖 Foundation；平台媒体类型只留在 Desktop。

### Task 1: 服务商配置与安全凭证入口

**Files:** Create Core/AI 两文件、Desktop/AI 前五个文件、AISettingsView 及 CredentialStoreTests、ProviderConfigurationTests、FakeCredentials；Modify SettingsView。

**Interfaces:** `AIProvider: String, Codable, CaseIterable` 为 openai/deepseek/siliconflow/azureSpeech/aliyunTingwu；`SpeechMode` 为 realtime/segmented/file；`ProviderCapabilities.supports(provider: AIProvider, speechMode: SpeechMode) -> Bool`。`AIConfiguration: Codable, Equatable` 含识别服务、翻译服务、各服务模型 ID、默认语言方向及术语表，不含密钥。翻译服务选择限制为 openai/deepseek/siliconflow；azureSpeech/aliyunTingwu 只出现在实时识别选择中，speechMode=file 返回 false；文件导入界面需用户显式选择支持文件的服务，不静默换服务。默认识别 OpenAI、翻译 DeepSeek；硅基流识别禁用实时模式，自动采用已明确标注的 segmented 模式。

`@MainActor protocol CredentialStore`：`contains(_ provider: AIProvider) throws -> Bool`、`save(_ secret: Data, for provider: AIProvider) throws`、`read(_ provider: AIProvider) throws -> Data`。Keychain service 固定 `local.officeassistant.providers`，account 为 provider.rawValue；contains 只查属性，不读 secret。Settings 的 SecureField 不回填已有密钥，只显示“已保存”，保存成功后立即清空输入。暂不提供删除钥匙串条目的按钮。前三家 Data 保存 API key；AzureSpeechCredentials 与 TingwuCredentials 是只在钥匙串内编码的凭证包，包含前述各自字段，不能加入 AIConfiguration、会议快照或日志。凭证包保存采用单次 keychain 更新，避免密钥与区域/项目各存一半。

`AISettingsStore` 单独保存无秘密配置到 `office.ai.preferences.v1`，避免改变阶段 A 的 AppPreferences 解码。`protocol ProviderTransport` 的 URLSession 实现在同文件中命名为 URLSessionProviderTransport；方法为 `data(for: URLRequest) async throws -> (Data, HTTPURLResponse)`、`bytes(for: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)`、`webSocket(for: URLRequest) -> any WebSocketConnection`。WebSocketConnection 定义 `send(_ message: WebSocketMessage) async throws`、`receive() async throws -> WebSocketMessage`、`close() async`；WebSocketMessage 为 text(String)/binary(Data)。只接受各服务官方 HTTPS/WSS 主机；禁止跨主机重定向转发 Authorization。错误只显示服务、HTTP 状态和安全请求标识，不显示原始请求、密钥或不经处理的响应体。

`ProviderModelClient.models(provider: AIProvider, purpose: ModelPurpose) async throws -> [ProviderModel]` 查询对应官方 `/models`，ModelPurpose 为 speech/textTranslation，ProviderModel 含 id、displayName、已知能力集合。硅基流使用 sub_type=speech-to-text/chat；OpenAI 缺少可用能力元数据时列出 ID 并允许用户明确选择，不能把列表成功当成所有模型都能转写。Azure/听悟没有通用 `/models`，不调用这两个服务的模型列表；只显示内置识别服务、语言及其配置状态。真实鉴权只能由对应连接或用户主动启动的识别验证，不能把本地格式检查显示为“已连接”。所有连接/翻译测试都是用户显式触发。

- [ ] **Step 1:** 写失败测试，包含 `testDeepSeekExcludedFromSpeech`、`testIndependentProviderSelection`、`testConfigurationDoesNotEncodeSecrets`、`testBlankCredentialRejected`、`testFailedReplacementPreservesOldCredential`、`testCrossHostRedirectRejected`、`testAzureAndTingwuExcludedFromTextTranslation`、`testProviderSpecificCredentialFieldsRequired`、`testNoModelDiscoveryForAzureAndTingwu`。断言空白 key 保存调用数为 0；配置 JSON 不含测试用 secret；旧值只在成功保存后改变。
- [ ] **Step 2:** `bash scripts/test.sh --filter 'ProviderConfigurationTests|CredentialStoreTests'`，确认接口未实现导致失败。
- [ ] **Step 3:** 实现协议及设置。测试默认使用假凭证存储，不写用户钥匙串。真实保存只由用户点击“保存密钥”触发；配置与模型列表读取分开，点击“检查连接/刷新模型”才发送对应请求。
- [ ] **Step 4:** 同一命令 PASS；UI 检查五个独立服务配置页、识别/翻译分开选择、未配置时禁止开始并指出缺失服务。不截图或读取含有实际密钥的输入状态。

### Task 2: 会议数据与字幕合并

**Files:** Create MeetingModels、TranscriptReducer、MeetingRepository、CoreDataMeetingRepository 及对应两个测试文件。

**Interfaces:** `AudioSourceID: String, Codable` 为 microphone/system/file；`SegmentID: Codable, Hashable` 含 meetingID: UUID、source: AudioSourceID、sequence: Int。`MeetingSession` 含 id、title、startedAt、endedAt、state、语言方向、识别/翻译配置快照、参与者备注、retainAudio；状态为 ready/recording/paused/finishing/completed/interrupted/failed。`TranscriptSegment` 含 id、sourceStartSeconds、sourceEndSeconds、providerItemID、revision、partialText、finalText、translatedText、translationState，识别/翻译耗时（可空）。

`TranscriptReducer.apply(_ event: TranscriptEvent, to segments: [TranscriptSegment]) throws -> [TranscriptSegment]` 只接受匹配 meeting/source 的事件，最终原文优先于临时文本；重复完成事件幂等，按本地 sequence/时间及音源排序。临时文字只留内存，最终原文在请求翻译之前保存；后续修改增加 revision，旧 revision 译文不能回写。

Core 中的 TranscriptEvent 使用 `.partial(id: SegmentID, revision: Int, providerItemID: String?, text: String)`、`.final(id: SegmentID, revision: Int, providerItemID: String?, text: String)`、`.translated(id: SegmentID, revision: Int, text: String, finished: Bool)`、`.failed(id: SegmentID, revision: Int, stage: ProcessingStage, message: String)`；ProcessingStage 为 transcription/translation。错误是已处理的安全文字。控制器先按当前 meetingID/epoch 过滤，reducer 再按标识及 revision 幂等合并。

`@MainActor protocol MeetingRepository`：`list() throws -> [MeetingSession]`、`save(_ meeting: MeetingSession) throws`、`segments(meetingID: UUID) throws -> [TranscriptSegment]`、`upsert(_ segment: TranscriptSegment) throws`。独立 Core Data 数据库位于 Application Support/OfficeAssistant/meetings.store，程序化 MeetingRecord/SegmentRecord，版本化 payload；不向 tasks.store 增加实体。恢复时将上次活跃会议标为 interrupted。

- [ ] **Step 1:** `testFinalBeatsLatePartial` 断言原文定稿后迟到 partial 不修改原文；`testDuplicateCompletionIsIdempotent` 断言数量仍为 1；`testSourcesNeverShareSegmentIdentity`、`testOutOfOrderEventsSortBySequence`、`testOldRevisionTranslationIgnored`；持久化测试保存后重开核对全部字段，并核对既有阶段 A 库仍可读取。
- [ ] **Step 2:** `bash scripts/test.sh --filter 'TranscriptReducerTests|MeetingPersistenceTests'`，确认失败。
- [ ] **Step 3:** 实现模型、reducer 和事务存储；损坏/未知版本不覆写原库，不用空数组冒充成功读取。
- [ ] **Step 4:** 同一命令 PASS，另验证恢复 interrupted 后未调用任何 capture.start。

### Task 3: 两种收音场景和音频导入

**Files:** Create Audio 五个文件、AudioSegmenter；Create AudioSegmenterTests、PCMConverterTests、AudioFileReaderTests 和 FakeCapture。

**Interfaces:** `PCMFrame` 定义在 Core/Meetings/MeetingModels.swift，为 Sendable 值类型，含 source、sequence、startSeconds、sampleRate=24000、channels=1、samples: Data（PCM Int16 little-endian）。`AudioUtterance` 同样属于 Core，含 id: SegmentID、revision: Int、startSeconds、endSeconds、pcm: Data，durationSeconds 由样本数/24000 计算；`UtteranceBoundary` 含 segmentID、revision、startSeconds、endSeconds。`protocol AudioCapture`：`start() async throws -> AsyncThrowingStream<PCMFrame, Error>`、`stop() async`；MicrophoneCapture 使用 AVAudioEngine 和选中的 CoreAudio 输入设备，SystemAudioCapture 使用选定 SCContentFilter，输出只注册 audio，capturesAudio=true、excludesCurrentProcessAudio=true。输入格式变化时重建转换器；音源断开产生明确事件并暂停，不继续使用旧指针。

`PCMConverter.convert(_ buffer: AVAudioPCMBuffer, source: AudioSourceID, sequence: Int, startSeconds: Double) throws -> PCMFrame` 使用 AVAudioConverter 转为标准帧；系统音源的 CMSampleBuffer 在平台适配器中先复制为 AVAudioPCMBuffer，不能跨回调保留失效的裸指针。`AudioFileReader.frames(url: URL, startFrame: Int64 = 0) -> AsyncThrowingStream<PCMFrame, Error>` 用 AVAudioFile 分块解码，不一次加载整份文件；支持系统可解码的 wav/m4a/mp3/aiff，其他格式经解码检查后提示。原文件不修改；取消导入保留最后定稿片段，重试从最后已确认帧偏移继续，重新选择原文件时核对文件大小及首部摘要。

`AudioSegmenter.append(_ frame: PCMFrame) throws -> [AudioUtterance]` / `finish() -> AudioUtterance?`：客户端按 20ms 窗口计算 RMS，初始阈值 -45dBFS；保留 200ms 预卷，600ms 连续静音结束语句，20 秒强制分段，100ms 尾部重叠并记录重叠范围。小于 200ms 的纯噪声片段不送转写。OpenAI 使用边输入边发送，结束检测只负责 commit；硅基流将已成句片段编码 WAV 上传。阈值为工程初始值，需在真实音频上调优，不能宣称为通用准确率保证。

- [ ] **Step 1:** 写 `testStereoResamplePreservesDuration`、`testSilenceDoesNotCreateUtterance`、`testForcedSplitAtTwentySeconds`、`testInvalidFileFailsBeforeYield`、`testReaderResumesAtRequestedFrame`；时长误差断言不超过一个转换帧，单片段不超过 20 秒加预卷/重叠。使用本地合成 PCM/WAV，设备断开和暂停回调在 Task 6 验证。
- [ ] **Step 2:** 运行 `bash scripts/test.sh --filter 'AudioSegmenterTests|PCMConverterTests|AudioFileReaderTests'`，确认新规则失败；具体硬件检查留在 Step 4，不用假采集结果替代。
- [ ] **Step 3:** 实现采集、转换、分段及文件迭代。麦克风/系统权限只在用户开始相应采集时请求；Info.plist 增加中文麦克风用途，系统音频按 ScreenCaptureKit 的版本/权限机制执行。选择来源时显示具体应用或显示器；会话期间禁止切换设备、服务商或方向。
- [ ] **Step 4:** 自动测试 PASS、`bash scripts/build-app.sh` 成功；实机分别检查默认麦克风/设备选择、系统应用音源和权限拒绝。没有实际音源或权限时记录未验证，而不是上传用户正在使用的任意应用音频。

### Task 4A: OpenAI 与硅基流语音适配及有界缓冲

**Files:** Create SpeechRecognizer 三文件、AudioBacklog、SpeechRecognizerTests、AudioBacklogTests、FakeTransport。

**Interfaces:** `protocol SpeechRecognizer`：`events: AsyncThrowingStream<TranscriptEvent, Error>`、`start(context: RecognitionContext) async throws`、`append(_ frame: PCMFrame) async throws`、`commit(_ utterance: UtteranceBoundary) async throws`、`cancel() async`。每个源有独立识别实例和 session epoch；events 必须携带 SegmentID/revision，不能以跨源全局变量保存当前 item。

RecognitionContext 含 meetingID、source、provider、mode、modelID、languages: [String]、glossary: [GlossaryEntry]。GlossaryEntry 是 Core 的 Codable 值，含 source、translation；密钥不放入 context，由注入的 CredentialStore 在连接/请求时读取，转换为 Authorization 后只存在请求内存。

OpenAI 用 `wss://api.openai.com/v1/realtime?intent=transcription`，session.update 中 type=transcription、audio/pcm 24000、gpt-live-transcribe、languages=[ja,zh]、turn_detection=null、delay=low。每 40ms 聚合一帧发送 input_audio_buffer.append，收到客户端结束检测后 commit；按 committed item ID 和 previous_item_id 绑定本地段序，不按完成事件到达顺序显示。保留 partial delta 与 final 事件语义。已录音文件改用 `/v1/audio/transcriptions` 与 gpt-transcribe。

硅基流用 `https://api.siliconflow.cn/v1/audio/transcriptions` multipart：file 为 WAV 二进制、model=FunAudioLLM/SenseVoiceSmall；按返回 text 完成对应段，不给它发送未文档化的 WebSocket/stream 参数。长文件采用不超过 20 秒分段，每请求正文硬上限 20MB，避免超过两家当前文件接口限制。

`AudioBacklog.enqueue(_ utterance: AudioUtterance) throws`、`dequeue() -> AudioUtterance?`、`durationSeconds: Double`，所有音源累计待处理音频不超过 60 秒，达到上限产生 bufferFull 事件并请求暂停。每源最多 1 个转写请求/实时发送循环；同一文件顺序导入，背压时不继续解码。

- [ ] **Step 1:** 用协议 fixture 编写 `testOpenAIConfigurationAndPCM`、`testCommittedItemIDsDetermineOrder`、`testDuplicateRealtimeEventDoesNotDuplicateSegment`、`testSiliconFlowMultipartUsesOnlySelectedKey`、`testBacklogNeverExceedsSixtySecondsAcrossSources`。断言两源各 31 秒不能都入队；HTTP 401/403/额度错误只发可操作错误，不自动重试。
- [ ] **Step 2:** `bash scripts/test.sh --filter 'SpeechRecognizerTests|AudioBacklogTests'`，确认失败。
- [ ] **Step 3:** 实现本节两家适配与有界队列。网络/5xx 只保留队列并进入待恢复；429 按服务 Retry-After（最多 30 秒）等待一次，继续失败暂停并提示。取消时关闭连接并拒绝旧 epoch 继续上传；不自动发送到另一家。
- [ ] **Step 4:** 同一命令 PASS；凭证由用户在应用中录入后，使用不含私人信息的短中日语样本分别验证两家的真实转写，记录模型、错误类型及实际片段耗时。

### Task 4B: 微软 Azure Speech 连续识别

**Files:** Modify Package.swift、scripts/build-app.sh；Create AzureSpeechRecognizer、AzureSpeechBridge、AzureSpeechRecognizerTests 和 Support/ThirdPartyNotices.md。

**Dependency:** 使用官方 `https://github.com/microsoft/speech-sdk-spm`，版本锁定 1.52.0，产品 `MicrosoftCognitiveServicesSpeech-macOS`。不使用 main 分支跟随更新，不引入 iOS 或 embedded 产品。版本、下载地址及 checksum 由官方该版本的 Package.swift 提供：[官方清单](https://github.com/microsoft/speech-sdk-spm/blob/1.52.0/Package.swift)。首次解析需要联网下载 SDK；不修改用户全局 Swift 工具配置。

**Interfaces:** `protocol AzureSpeechBridge`：`start(credentials: AzureSpeechCredentials, locales: [String]) async throws -> AsyncThrowingStream<AzureRecognitionEvent, Error>`、`writePCM16(_ data: Data) async throws`、`stop() async`。AzureRecognitionEvent 包含 partial/final/canceled/sessionStopped，以及 resultID、offsetSeconds、durationSeconds、text。真实 bridge 使用官方 SDK 的 push audio input stream，不让 SDK 另行打开默认麦克风；每个音源独立识别器。适配层将标准 24kHz 帧转换为 16kHz、16bit、mono 后送入；SDK 的 recognizing/recognized 回调映射统一字幕事件，按结果 ID 与 offset 去重排序。

日语方向使用 ja-JP，中文方向使用 zh-CN；显式中日混合模式使用 SDK 的候选语言识别配置并单独实测，不宣称能准确处理句内所有切换。区域由用户已有资源决定，不能自动改成其他区域。权限、配额和区域不匹配错误归类后显示可操作信息，SDK 的原始诊断字符串不能直接写入日志。

- [ ] **Step 1:** 写 `testPushStreamUsesSelectedSource`、`testPCMIsResampledToSixteenK`、`testRecognizingAndRecognizedShareSegment`、`testDuplicateResultIDIsIdempotent`、`testStopClosesInputAndRejectsLateCallbacks`、`testAzureRegionRequired`、`testAzureAndTingwuRealtimeOnlyCapabilities`。通过 fake bridge 断言不访问系统默认麦克风，停止后的 write 次数不再增加。
- [ ] **Step 2:** `bash scripts/test.sh --filter AzureSpeechRecognizerTests`，确认失败；依赖下载失败先解决实际网络/安装错误，不移除识别功能或用模拟服务交付。
- [ ] **Step 3:** 实现桥接和适配，SDK 对象在串行执行上下文管理，跨线程回调先复制为值类型，再交给会话控制器。SDK 的 stop 与通用 epoch 屏障共同保证暂停后不继续传音频。实时输入结束时等待 SDK 最终状态或明确超时，不能将 SDK 网络断开当作成功完成；本阶段不将 Azure 暴露为文件导入服务。
- [ ] **Step 4:** 测试 PASS；release 打包复制 macOS framework 到 Contents/Frameworks，配置 `@executable_path/../Frameworks` 运行时搜索路径，先签名复制后的框架，再签名应用。用 otool 和 codesign 核对依赖可解析、架构包含当前 arm64 以及应用包完整性；保留 SDK 许可证说明。使用用户录入的真实 Speech Key/Region 后再做日语样本联调。

官方依据：[资源区域和密钥匹配](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/regions)、[连续识别 API](https://learn.microsoft.com/en-us/objectivec/cognitive-services/speech/spxspeechrecognizer)。

### Task 4C: 阿里云通义听悟任务与实时推流

**Files:** Create TingwuSpeechRecognizer、TingwuTaskClient、AlibabaRequestSigner、TingwuRecognizerTests、AlibabaRequestSignerTests；Modify MeetingModels 保存安全的 provider task ID 与待关闭状态。

**Interfaces:** `TingwuTaskClient.start(context: RecognitionContext) async throws -> TingwuTaskHandle`、`stop(_ task: TingwuTaskHandle) async throws`。TingwuTaskHandle 在内存中含 taskID 和服务返回的 MeetingJoinUrl，数据库只能保存 taskID/source/provider 与 needsRemoteStop，不能保存含鉴权参数的推流 URL。`AlibabaRequestSigner.sign(_ request: URLRequest, credentials: TingwuCredentials, date: Date, nonce: String) throws -> URLRequest` 使用 CryptoKit 的 SHA256/HMAC，按官方 ACS3-HMAC-SHA256 规则规范化 URI、排序百分号编码 query、签名 headers 与 body hash。测试使用官方公开示例，不使用真实密钥。

CreateTask 请求为 PUT `/openapi/tingwu/v2/tasks?type=realtime&operation=start`，API version 2023-09-30，接入点固定官方北京区 `tingwu.cn-beijing.aliyuncs.com`；body 提供 AppKey、Input.Format=pcm、Input.SampleRate=16000、SourceLanguage=ja/cn，混合模式按官方 multilingual + LanguageHints=[ja,cn]。不启用 OSS 录音写入、外部回调、会议摘要或服务端自动 Todo。使用返回的 WSS 地址连接，仅允许官方听悟域名和受 TLS 验证的服务地址，拒绝跨主机/非官方地址，整个推流 URL 均作为秘密处理，不记日志。

TingwuSpeechRecognizer 仍实现统一 SpeechRecognizer。每音源一条听悟任务，24kHz 标准帧在发送前转为 16kHz PCM。按官方实时推流协议发送启动/停止命令及音频，TranscriptionResultChanged 映射 partial、SentenceEnd 映射 final，任务 ID + 源 ID + index 绑定片段；不照搬 OpenAI 事件或客户端 commit。start 过程中若 WebSocket 建连失败，也必须关闭已经创建的云端任务。

停止时先阻断新 PCM 并关闭推流，再调用 CreateTask operation=stop 结束对应云端任务；仅断开 WebSocket 不能当作远端任务已关闭。暂停时同样停止本次任务，恢复时显式创建新任务并延续本地序号。断网导致关闭失败时持久化 needsRemoteStop，显示“云端任务待关闭”；重连/重启只重试关闭这些明确已有任务，不自动录音或创建新任务。重复 stop、云端已终止状态按幂等成功处理。

- [ ] **Step 1:** 写 `testACS3MatchesOfficialExample`、`testCanonicalQueryEncodingAndOrder`、`testSTSHeaderIsSigned`、`testTingwuUsesSixteenKJapanese`、`testPartialAndSentenceEndMapToSameSegment`、`testTaskIDsDoNotLeakBetweenSources`、`testJoinFailureStopsCreatedTask`、`testStopClosesRemoteTask`、`testOfflineStopPersistsCleanupWithoutRestartingAudio`。凭证、签名 Authorization 和完整 MeetingJoinUrl 都不得出现在安全错误及持久化 JSON 中。
- [ ] **Step 2:** `bash scripts/test.sh --filter 'TingwuRecognizerTests|AlibabaRequestSignerTests'`，确认失败。
- [ ] **Step 3:** 实现签名、任务控制、实时协议及清理状态。凭证过期、AppKey 不匹配和权限失败不自动重试；网络关闭重试遵守现有有界策略。首次不代用户创建 AccessKey、授权 RAM、开通商用服务或配置 OSS。
- [ ] **Step 4:** 测试 PASS；用户录入已开通听悟服务的凭证后，验证创建→推流→字幕→结束任务全过程，再核对应用中的任务清理状态。只有云端确认关闭后才能记录为完整联调成功。

官方依据：[听悟接入凭证](https://help.aliyun.com/zh/tingwu/getting-started-1)、[CreateTask](https://help.aliyun.com/en/tingwu/api-tingwu-2023-09-30-createtask)、[推流协议](https://help.aliyun.com/zh/tingwu/real-time-stream-push)、[阿里云 V3 签名](https://help.aliyun.com/zh/sdk/product-overview/v3-request-structure-and-signature)。

### Task 5: 三家流式文字翻译与商务用语

**Files:** Create Translation 四文件及 TranslationTests。

**Interfaces:** `TranslationRequest` 含 segmentID、revision、sourceText、direction（jaToZh/zhToJa）、context（最多前 6 个定稿段且累计 3000 字符）、glossary。`protocol TextTranslator`：`translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error>`、`cancelAll() async`。event 为 delta/finished/failed，均携带 segmentID/revision。

ChatCompletionTranslator 使用相同解码层但 provider-specific 请求：OpenAI `/v1/chat/completions`；DeepSeek `https://api.deepseek.com/chat/completions`，thinking.type=disabled；硅基流 `/v1/chat/completions`，enable_thinking=false（对应支持此参数的已选模型）。所有请求 stream=true，只有 content delta 进入译文，不展示 reasoning_content。`SSEDecoder.feed(_ bytes: Data) throws -> [SSEMessage]` 缓冲完整 UTF-8 行，SSEMessage 含 event: String?、data: String，支持跨网络帧分割、多行 data、CRLF、空行、[DONE]；必须收到正常 finish_reason 或终止事件，否则将中断译文标为需重试。

提示限定只翻译，商务日语使用合适敬语，保留金额/日期/数量和承诺力度；原文作为被翻译内容处理，不能让原文中的指令改变任务。术语最多 100 条、单字段 128 字符、总计 4096 字符；OpenAI ASR keywords 额外过滤不允许的换行与尖括号。可编辑原文并重新翻译，增加 revision。每源翻译顺序处理，两源总并发不超过 2；未处理请求仍受音频会话背压控制。

- [ ] **Step 1:** 写 `testSSESplitInsideUnicodeAndAcrossDataLines`（HTTP bytes 先正确做增量 UTF-8 解码）、`testReasoningIsNotTranslation`、`testDisconnectDoesNotMarkPartialComplete`、`testLateRevisionIgnored`、`testJapaneseBusinessPromptPreservesNumbers`、`testContextAndGlossaryAreBounded`、`testSelectedProviderOnlyReceivesItsCredential`、`testServerErrorCannotEchoSecret`。
- [ ] **Step 2:** `bash scripts/test.sh --filter TranslationTests`，确认失败。
- [ ] **Step 3:** 实现 SSE 增量解析、请求构造、提示与错误归类，输出分段回填，不重排。模型不可用时保留原文并标记翻译失败；用户可修正设置后单独重试该段。
- [ ] **Step 4:** 同一命令 PASS；用同一中日商务文本分别联调三家翻译，核对数字、日期、币种与否定表述，不用单个样本宣称整体准确率。

### Task 6: 会话控制与会议工作区

**Files:** Create MeetingSessionController、Meetings 三视图、MeetingSessionTests；Modify OfficeAppModel、WorkspaceView、SettingsView、AppDelegate。

**Interfaces:** `@MainActor @Observable MeetingSessionController` 暴露 meeting、segments、state、captureLevels、errorMessage、bufferedSeconds；方法为 `start(_ setup: MeetingSetup) async throws`、`pause() async`、`resume(processBufferedAudio: Bool) async throws`、`stop() async`、`importAudio(url: URL, setup: MeetingSetup) async throws`、`retryTranslation(segmentID: SegmentID) async throws`、`processUnfinishedAudio() async throws`。注入 capture/recognizer/translator/repository，便于确定性测试；只能有一个活跃会议。

MeetingSetup 含 title、participantsNote、scene（faceToFace/online）、microphoneDeviceID: String?、captureMicrophone: Bool、systemSource（无/所选应用/所选显示器的稳定标识）、direction、configuration: AIConfiguration、glossary、retainAudio: Bool=false。线上来源失效需重新选择，不能自动扩大为所有系统音频。

开始前检查所选服务凭证、模型、语音能力及权限。按原文定稿→本地保存成功→翻译的顺序推进，存储失败立即暂停；译文每 100ms 合并 UI 更新，定稿后持久化。暂停/停止立刻停止采集和新的音频发送，并取消对应请求；保留已定稿内容和有界未完成片段。结束时不静默上传最后片段，需要用户显式点击“处理未完成片段”；已经发送而返回迟到的结果通过 epoch/revision 判定是否接收，不修改其他会议。

断网只缓冲到 60 秒上限，显示“网络中断/已暂停”；恢复由用户点击并选择是否处理暂存音频。应用退出、系统睡眠或输入设备断开均停止采集，持久化 interrupted，不自动恢复；关闭主窗口继续保留会话并有菜单栏录音指示和“停止录音”入口。用户未选择保留音频时，只保留临时有界缓冲，结束并明确放弃/处理后清理；选择保留时仅保存应用自己的会议音频。

会议页包含会议列表、新建/导入、标题、参与者备注、面对面/线上场景、音源与语言设置、服务组合、录音计时、两源电平、暂停/继续/停止、原文/译文并列、局部失败重试及术语设置。只读浏览历史不请求权限或联网。设置“检查连接”只向对应服务发送模型查询及明确标注的短测试文本，不上传会议历史。界面不显示密钥、内部事件名或虚假置信度。

- [ ] **Step 1:** FakeCapture/Transport 写 `testPauseIsUploadBarrier`、`testStopIsUploadBarrier`、`testOldSessionCannotWriteNewSession`、`testDiskFailurePreventsTranslation`、`testBufferFullPausesCapture`、`testResumeRequiresExplicitBufferChoice`、`testSleepInterruptsWithoutAutoRestart`、`testCloseWindowDoesNotStopActiveCapture`、`testQuitStopsCapture`、`testImportCancellationPreservesFinalSegments`、`testDeviceLossPausesSession`、`testInvalidFileDoesNotEraseTranscript`；所有测试不用真实麦克风和用户密钥。
- [ ] **Step 2:** `bash scripts/test.sh --filter MeetingSessionTests`，确认失败。
- [ ] **Step 3:** 实现状态机及会议界面，AppModel 持有单一 controller，菜单栏录音状态来自该 controller；原待办导航/通知服务保持原接口。
- [ ] **Step 4:** 同一命令 PASS，打包后实机检查每种可用入口及暂停/停止。需要用户实际讲话、选择会议软件音源或录入真实密钥的部分由用户在界面完成，不从聊天索取密钥，不自动录制无关软件。

### Task 7: 回归、真实联调与交付

**Files:** Modify Support/Info.plist（版本 0.2.0）、README.md；Create docs/verification/stage-b.md；按发现的问题修改所属模块及对应回归测试。

- [ ] **Step 1:** `bash scripts/test.sh`，阶段 A 的全部 38 项原有测试继续通过，并核对所有 B 阶段新增用例确实执行。
- [ ] **Step 2:** `bash scripts/build-app.sh`、`plutil -lint dist/OfficeAssistant.app/Contents/Info.plist`、`codesign --verify --deep --strict dist/OfficeAssistant.app`；必须构建成功且检查退出码为 0。
- [ ] **Step 3:** 使用本地合成的非私人中日语音样本做真实 API 联调；对四家识别及三家翻译分别记录通过/失败/未执行。用户拥有密钥但尚未在应用中录入时标记“待配置联调”，不得改用环境中无关凭证或将 mock 标为通过。
- [ ] **Step 4:** 在至少一种用户选定的会议软件和真实麦克风上验证双方收音、耳机模式、暂停停止及权限拒绝。录下至少 20 个代表性句段的结束→识别/翻译完成耗时，分别记录 OpenAI、Azure、听悟流式与硅基流分段路径，报告 P50/P95 与未达目标情况。工具无法可靠观察或用户未提供音源时如实记录缺口。
- [ ] **Step 5:** Native 实施后安排独立代码审查，修复数据丢失、凭证暴露、未授权持续采集及错误状态等实际问题，只为新问题补测，不无理由重复全套检查。
- [ ] **Step 6:** 更新使用说明、密钥本地录入步骤、数据/音频保留方式、五家配置与各自能力边界、实测延迟与未验证项，交付更新后的 `.app`。阶段 C 的纪要/自动 Todo 保持明确未实现状态。

## 自审与执行交接

整体设计的阶段 B 要求对应：五家服务与凭证→Task 1；本地历史/稳定字幕→Task 2；面对面/线上收音和音频导入→Task 3；流式或分段转写/断网背压→Task 4A–4C；中日商务翻译→Task 5；暂停停止/恢复/完整界面→Task 6；权限、真实联调、延迟与原有待办回归→Task 7。Review Focus 五项都有对应测试或实机检查。

文档中的模型与接口依据为 2026-11-03 可访问官方资料，真实账号能力需实际验证。用户明确已有三家密钥只代表复用选择，不代表密钥已经存在于本机应用。任何真实凭证录入都由用户在安全界面完成。

继续沿用 Native，不再重复询问执行方式。用户已回复“ok”确认本修订计划，按 Native 方式实施。


范围修订（2026-11-03）：按用户明确要求新增 Azure Speech 与通义听悟识别。新增两家的服务未被当作已配置或已开通，凭证通过应用录入即可，不阻塞无凭证的模块实现与自动测试。本修订计划已获用户确认；沿用 Native。


## 执行状态（2026-11-03）

Task 1–6 的配置、存储、采集、四家识别、三家翻译和会话界面代码已实现。物理文件按职责合并部分协议/值类型，未机械拆成每个拟定文件名。原计划中的各项先失败步骤保留为原始计划，不能据此声称每个拟定测试名都单独执行；实际回归以测试源文件及 verification/stage-b.md 为准。

已有阶段 A 的 38 项测试与阶段 B 回归共同执行，加入用户批准的仅转写模式后，最新 86 项测试通过。Native 独立审查已执行，发现的问题已修复并补回归。新增了文件大小/首尾摘要与检查点恢复入口、429 最多一次重试、短噪声过滤及分段接口 100ms 重叠；OpenAI 实时链路不重复推送重叠 PCM。

Task 7 已在用户配置 OpenAI 后验证单个合成日语文件转写、gpt-5.4-mini 日译中，以及仅转写模式的实际导入。当前版本 0.2.1；仅转写的小改动设计另获用户明确批准。其他服务、实际设备/会议软件及 P50/P95 仍待验证。界面检查已修复文件导入选择器冲突、历史整行点击与校对窗口初始化；具体证据及限制见验证记录。
