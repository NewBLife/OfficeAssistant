import Foundation
import Observation
import CryptoKit
import OfficeCore

public struct MeetingSetup {
    public var title: String
    public var participants = ""
    public var configuration: AIConfiguration
    public var captureMicrophone = true
    public var microphoneDeviceID: UInt32?
    public var systemSource: SystemAudioSource?
    public var groupID: UUID?
    public var retainAudio = false
    public init(title: String, configuration: AIConfiguration) { self.title = title; self.configuration = configuration }
}
@MainActor @Observable public final class MeetingSessionController {
    public private(set) var history: [MeetingSession] = []
    public private(set) var meeting: MeetingSession?
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var starting = false
    public private(set) var closing = false
    public private(set) var bufferedSeconds = 0.0
    public private(set) var levels: [AudioSourceID: Double] = [:]
    public var errorMessage: String?
    public var onChange: (() -> Void)?
    public var onFinalSegmentSaved: ((UUID) -> Void)?
    public var onRecordingStopped: ((UUID) -> Void)?
    public var isActive: Bool { starting || closing || meeting?.state == .recording || meeting?.state == .finishing }
    public var hasUnclosedRemoteTasks: Bool { history.contains { $0.remoteTasks.contains(where: \.needsStop) } || (meeting?.remoteTasks.contains(where: \.needsStop) ?? false) }
    public var canResume: Bool { !isActive && savedSetupMeetingID == meeting?.id && savedSetup != nil && (meeting?.state == .paused || meeting?.state == .interrupted) }
    public var canProcessBuffered: Bool { !isActive && !pending.isEmpty }
    @ObservationIgnored private let groups: GroupStore?
    @ObservationIgnored private let repository: any MeetingRepository
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let translator: ChatCompletionTranslator
    @ObservationIgnored private var captureFactory: ((MeetingSetup) -> [(AudioSourceID, any AudioCapture)])?
    @ObservationIgnored private var factory: ((RecognitionContext, Bool) -> any SpeechRecognizer)?
    @ObservationIgnored private var archives: [AudioSourceID: AudioArchive] = [:]
    @ObservationIgnored private var connectionTasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var captures: [any AudioCapture] = []
    @ObservationIgnored private var recognizers: [AudioSourceID: any SpeechRecognizer] = [:]
    @ObservationIgnored private var captureTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var translations: [SegmentID: Task<Void, Never>] = [:]
    private struct TranslationWork { var segment: TranscriptSegment; var configuration: AIConfiguration }
    @ObservationIgnored private var translationQueue: [TranslationWork] = []
    @ObservationIgnored private var translatingSources: Set<AudioSourceID> = []
    @ObservationIgnored private var segmenters: [AudioSourceID: AudioSegmenter] = [:]
    @ObservationIgnored private var pending: [SegmentID: AudioUtterance] = [:]
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var offline = false
    @ObservationIgnored private var savedSetup: MeetingSetup?
    @ObservationIgnored private var savedSetupMeetingID: UUID?
    @ObservationIgnored private var importURL: URL?
    @ObservationIgnored private var recognizedThrough: [AudioSourceID: Double] = [:]
    @ObservationIgnored private var lastPartialUpdate: [SegmentID: Date] = [:]
    public init(repository: any MeetingRepository, credentials: any CredentialStore, translator: ChatCompletionTranslator? = nil, groups: GroupStore? = nil,
                factory: ((RecognitionContext, Bool) -> any SpeechRecognizer)? = nil, captureFactory: ((MeetingSetup) -> [(AudioSourceID, any AudioCapture)])? = nil) {
        self.groups = groups; self.repository = repository; self.credentials = credentials; self.translator = translator ?? ChatCompletionTranslator(credentials: credentials); self.factory = factory; self.captureFactory = captureFactory
        do {
            history = try repository.list()
            for var item in history where item.state == .recording || item.state == .finishing || item.state == .ready {
                item.state = .interrupted; try repository.save(item)
            }
            history = try repository.list()
        } catch { errorMessage = "会议记录无法读取，原数据已保留。" }
    }
    public func reloadHistory() {
        do { history = try repository.list(); onChange?() } catch { errorMessage = "会议列表读取失败，原记录已保留。" }
    }
    public func open(_ item: MeetingSession) throws {
        guard !isActive, !canProcessBuffered || meeting?.id == item.id else { throw OfficeError.invalid("请先处理或放弃当前暂存音频，再打开其他会议。") }
        let loaded = try repository.segments(meetingID: item.id)
        if meeting?.id != item.id {
            cancelTranslations(); epoch = UUID(); savedSetup = nil; savedSetupMeetingID = nil; importURL = nil
            segmenters = [:]; pending = [:]; recognizedThrough = [:]; lastPartialUpdate = [:]; bufferedSeconds = 0; levels = [:]
        }
        meeting = item; segments = loaded; errorMessage = nil
    }
    public func moveToGroup(id: UUID, groupID: UUID?) throws {
        guard !(isActive && meeting?.id == id) else { throw OfficeError.invalid("请先暂停或停止记录，再移动会议分组。") }
        guard let groups else { throw OfficeError.invalid("分组服务不可用。") }
        let target = try groups.normalized(groupID)
        guard groupID == nil || target != nil else { throw OfficeError.invalid("目标分组已删除。") }
        guard var item = try repository.list().first(where: { $0.id == id }) else { throw OfficeError.invalid("会议已不存在。") }
        item.groupID = target; try repository.save(item)
        if meeting?.id == id { meeting = item }
        reloadHistory()
    }
    public func rename(_ id: UUID, title: String) throws {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw OfficeError.invalid("会议名称不能为空且不能超过200字。") }
        guard var item = try repository.list().first(where: { $0.id == id }) else { throw OfficeError.invalid("会议已不存在。") }
        item.title = value; try repository.save(item)
        if meeting?.id == id { meeting = item }
        reloadHistory()
    }
    public func delete(_ id: UUID, includingAudio: Bool = false) throws {
        guard !isActive else { throw OfficeError.invalid("请先暂停或停止记录，再删除会议。") }
        guard let item = try repository.list().first(where: { $0.id == id }) else { throw OfficeError.invalid("会议已删除或不可用。") }
        guard !item.remoteTasks.contains(where: \.needsStop) else { throw OfficeError.invalid("请先清理待关闭的听悟云端任务，再删除会议。") }
        try repository.delete(meetingID: id)
        if meeting?.id == id {
            cancelTranslations(); epoch = UUID(); discardBuffered()
            meeting = nil; segments = []; savedSetup = nil; savedSetupMeetingID = nil; importURL = nil
            recognizedThrough = [:]; lastPartialUpdate = [:]; levels = [:]; errorMessage = nil
        }
        reloadHistory()
        if includingAudio {
            do { try MeetingAudioFiles().remove(item.audioFiles) }
            catch { throw OfficeError.invalid("会议已删除，但部分本机录音未能删除，可通过本机录音文件夹手动清理。") }
        }
    }
    private func persist() throws {
        if var item = meeting {
            if let groups, groups.isLoaded { item.groupID = GroupRules.effectiveGroupID(item.groupID, groups: groups.groups) }
            try repository.save(item); meeting = item
        }; history = try repository.list(); onChange?()
    }
    private func preflight(_ configuration: AIConfiguration, file: Bool) throws {
        try configuration.validate()
        if file && !configuration.speechProvider.supportsFiles { throw OfficeError.invalid("音频文件请选择 OpenAI 或硅基流识别。") }
        _ = try credentials.read(configuration.speechProvider)
        if configuration.shouldTranslate { _ = try credentials.read(configuration.translationProvider) }
    }
    private func makeRecognizer(_ context: RecognitionContext, file: Bool) -> any SpeechRecognizer {
        if let factory { return factory(context, file) }
        if file || context.configuration.speechProvider == .siliconflow { return FileSpeechRecognizer(credentials: credentials) }
        switch context.configuration.speechProvider {
        case .azureSpeech: return AzureSpeechRecognizer(credentials: credentials, bridge: NativeAzureSpeechBridge())
        case .aliyunTingwu: return TingwuSpeechRecognizer(credentials: credentials)
        default: return OpenAIRealtimeRecognizer(credentials: credentials)
        }
    }
    private func prepare(_ setup: MeetingSetup, file: Bool) throws {
        guard !isActive, pending.isEmpty else { throw OfficeError.invalid("请先结束当前记录并处理暂存音频。") }
        try preflight(setup.configuration, file: file)
        guard !setup.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OfficeError.invalid("请填写会议标题。") }
        var item = MeetingSession(title: setup.title, configuration: setup.configuration)
        item.groupID = setup.groupID
        item.participantsNote = setup.participants; item.retainAudio = setup.retainAudio
        cancelTranslations(); importURL = nil; savedSetupMeetingID = item.id
        meeting = item; segments = []; savedSetup = setup; errorMessage = nil; offline = false; epoch = UUID(); segmenters = [:]; recognizedThrough = [:]
        try persist()
    }
    private func connect(source: AudioSourceID, file: Bool, offset: Double, token: UUID) async throws -> any SpeechRecognizer {
        guard let meeting else { throw CancellationError() }
        let next = (segments.filter { $0.id.source == source }.map(\.id.sequence).max() ?? -1) + 1
        let context = RecognitionContext(meetingID: meeting.id, source: source, configuration: meeting.configuration, nextSequence: next)
        let recognizer = makeRecognizer(context, file: file)
        recognizers[source] = recognizer
        segmenters[source] = AudioSegmenter(meetingID: meeting.id, source: source, nextSequence: next, overlapSeconds: (file || meeting.configuration.speechProvider == .siliconflow) ? 0.1 : 0)
        recognizer.onEvent = { [weak self] event in
            guard let self, self.epoch == token else { return }
            var value = event
            if context.configuration.speechProvider == .azureSpeech || context.configuration.speechProvider == .aliyunTingwu {
                value.startSeconds += offset; value.endSeconds += offset
            }
            self.accept(value, token: token)
        }
        recognizer.onFailure = { [weak self] error in
            guard let self, self.epoch == token else { return }
            self.errorMessage = ProviderNetwork.safeError(error); self.offline = true
            if source == .file || error is ProviderHTTPError || error is OfficeError {
                Task { await self.pause() }
            }
        }
        recognizer.onRemoteTask = { [weak self] remote in
            guard let self else { return }
            let target = self.meeting?.id == context.meetingID ? self.meeting : try self.repository.list().first { $0.id == context.meetingID }
            guard var record = target else { throw OfficeError.invalid("云端任务创建后无法找到本地会议记录。") }
            record.remoteTasks.removeAll { $0.taskID == remote.taskID }; record.remoteTasks.append(remote)
            try self.repository.save(record)
            if self.meeting?.id == record.id { self.meeting = record }
            self.reloadHistory()
        }
        let connectionID = UUID()
        let operation = Task { @MainActor in try await recognizer.start(context) }
        connectionTasks[connectionID] = operation
        defer { connectionTasks.removeValue(forKey: connectionID) }
        try await operation.value
        guard epoch == token else { await recognizer.cancel(); throw CancellationError() }
        return recognizer
    }
    public func start(_ setup: MeetingSetup) async throws {
        guard setup.captureMicrophone || setup.systemSource != nil else { throw OfficeError.invalid("请至少选择一个音源。") }
        try prepare(setup, file: false); starting = true; let token = epoch
        defer { if token == epoch { starting = false } }
        do { try await beginCaptures(setup, token: token) }
        catch { if token == epoch { errorMessage = ProviderNetwork.safeError(error); await stop(); meeting?.state = .failed; try? persist() }; throw error }
    }
    private func beginCaptures(_ setup: MeetingSetup, token: UUID) async throws {
        var sources: [(AudioSourceID, any AudioCapture)] = []
        if let captureFactory { sources = captureFactory(setup) }
        else {
            if setup.captureMicrophone { sources.append((.microphone, MicrophoneCapture(deviceID: setup.microphoneDeviceID))) }
            if let source = setup.systemSource { sources.append((.system, SystemAudioCapture(source: source))) }
        }
        let offset = max(0, Date().timeIntervalSince(meeting?.startedAt ?? Date()))
        for (source, capture) in sources {
            let recognizer = try await connect(source: source, file: false, offset: offset, token: token)
            if setup.retainAudio, let id = meeting?.id {
                let archive = try AudioArchive(meetingID: id, source: source); archives[source] = archive
                meeting?.audioFiles.append(archive.relativeName); try persist()
            }
            captures.append(capture)
            let stream = try await capture.start()
            guard token == epoch else { await capture.stop(); await recognizer.cancel(); throw CancellationError() }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await incoming in stream {
                        guard token == self.epoch, !Task.isCancelled else { return }
                        var frame = incoming; frame.startSeconds += offset
                        try await self.consume(frame, recognizer: recognizer, token: token)
                    }
                } catch { if token == self.epoch && !Task.isCancelled { self.errorMessage = ProviderNetwork.safeError(error); await self.pause() } }
            }
            captureTasks.append(task)
        }
        guard token == epoch else { throw CancellationError() }
        meeting?.state = .recording; try persist()
    }
    private func consume(_ frame: PCMFrame, recognizer: any SpeechRecognizer, token: UUID) async throws {
        guard token == epoch else { throw CancellationError() }
        try archives[frame.source]?.append(frame.samples)
        levels[frame.source] = min(1, frame.samples.withUnsafeBytes { raw in
            var maximum = 0.0
            for i in stride(from: 0, to: raw.count - 1, by: 2) { maximum = max(maximum, abs(Double(raw.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32768) }; return maximum
        })
        let total = pending.values.reduce(0) { $0 + $1.duration } + segmenters.values.reduce(0) { $0 + $1.bufferedSeconds }
        guard total + frame.duration <= 60.001 else { throw OfficeError.invalid("待处理音频已达到 60 秒，已暂停。") }
        let utterances = segmenters[frame.source]?.append(frame) ?? []
        let clientStreaming = meeting?.configuration.speechProvider == .openai && frame.source != .file
        // Enqueue before network awaits so an immediate final can remove its own backlog.
        for utterance in utterances {
            let serverSegmented = meeting?.configuration.speechProvider == .azureSpeech || meeting?.configuration.speechProvider == .aliyunTingwu
            if !serverSegmented || utterance.startSeconds + utterance.duration > (recognizedThrough[frame.source] ?? -1) + 0.1 { pending[utterance.id] = utterance }
        }
        if !offline {
            do {
                if clientStreaming {
                    for part in segmenters[frame.source]?.streamingParts ?? [] {
                        guard token == epoch else { throw CancellationError() }
                        try await recognizer.append(PCMFrame(source: frame.source, sequence: frame.sequence, startSeconds: part.startSeconds, samples: part.pcm))
                        if let utterance = part.utterance { try await recognizer.commit(utterance) }
                    }
                } else { try await recognizer.append(frame) }
            } catch {
                guard token == epoch else { throw CancellationError() }
                offline = true; errorMessage = ProviderNetwork.safeError(error)
                if frame.source == .file || error is ProviderHTTPError || error is OfficeError { throw error }
            }
        }
        for utterance in utterances {
            guard token == epoch else { throw CancellationError() }
            if !offline && !clientStreaming { try await recognizer.commit(utterance) }
        }
        bufferedSeconds = pending.values.reduce(0) { $0 + $1.duration }
    }
    private func accept(_ event: TranscriptEvent, token: UUID) {
        guard token == epoch, event.id.meetingID == meeting?.id else { return }
        if (event.kind == .partial || event.kind == .translationPartial), let previous = lastPartialUpdate[event.id], Date().timeIntervalSince(previous) < 0.1 { return }
        lastPartialUpdate[event.id] = Date()
        let updated = TranscriptReducer.apply(event, to: segments)
        guard let item = updated.first(where: { $0.id == event.id }) else { return }
        do {
            if event.kind == .final || event.kind == .translation || event.kind == .failure { try repository.upsert(item) }
            let previous = segments.first { $0.id == item.id }
            segments = updated
            if event.kind == .final {
                if previous?.finalText != item.finalText { onFinalSegmentSaved?(item.id.meetingID) }
                recognizedThrough[event.id.source] = max(recognizedThrough[event.id.source] ?? 0, event.endSeconds)
                if meeting?.configuration.speechProvider == .azureSpeech || meeting?.configuration.speechProvider == .aliyunTingwu {
                    pending = pending.filter { $0.key.source != event.id.source || $0.value.startSeconds + $0.value.duration > event.endSeconds + 0.1 }
                } else { pending.removeValue(forKey: event.id) }
                bufferedSeconds = pending.values.reduce(0) { $0 + $1.duration }
                if meeting?.configuration.shouldTranslate == true, previous?.finalText != item.finalText, !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translate(item, token: token) }
                if item.id.source == .file { meeting?.importOffset = Int64(event.endSeconds * 24000); try persist() }
            }
        } catch { errorMessage = "本地保存失败，已暂停，已有记录不会被清空。"; Task { await self.pause() } }
    }
    private func translate(_ item: TranscriptSegment, token: UUID, configuration: AIConfiguration? = nil) {
        guard let config = configuration ?? meeting?.configuration, config.shouldTranslate else { return }
        translationQueue.removeAll { $0.segment.id == item.id }
        guard translationQueue.count < 20 else {
            errorMessage = "翻译积压较多，已暂停采集；已识别原文已保存，可稍后重新翻译。"
            Task { await self.pause() }; return
        }
        translationQueue.append(TranslationWork(segment: item, configuration: config))
        pumpTranslations(token: token)
    }
    private func pumpTranslations(token: UUID) {
        guard token == epoch, let current = meeting else { return }
        translationQueue.removeAll { $0.segment.id.meetingID != current.id }
        for source in AudioSourceID.allCases where !translatingSources.contains(source) && translatingSources.count < 2 {
            guard let index = translationQueue.firstIndex(where: { $0.segment.id.source == source }) else { continue }
            let work = translationQueue.remove(at: index)
            let item = work.segment; let config = work.configuration
            translatingSources.insert(source)
            let context = segments.filter { $0.finalText != nil && $0.id != item.id && $0.sourceStartSeconds <= item.sourceStartSeconds }
            translations[item.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if token == self.epoch {
                        self.translations.removeValue(forKey: item.id)
                        self.translatingSources.remove(source)
                        self.pumpTranslations(token: token)
                    }
                }
                do {
                    for try await event in self.translator.translate(segment: item, configuration: config, context: context) {
                        guard token == self.epoch, !Task.isCancelled else { return }; self.accept(event, token: token)
                    }
                } catch {
                    if token == self.epoch && !Task.isCancelled { self.accept(TranscriptEvent(id: item.id, kind: .failure, text: ProviderNetwork.safeError(error), revision: item.revision), token: token) }
                }
            }
        }
    }
    public func retryTranslation(_ id: SegmentID, editedText: String? = nil, textModel: String? = nil) throws {
        guard !starting, !closing, var item = segments.first(where: { $0.id == id }), item.finalText != nil else { return }
        guard var config = meeting?.configuration else { return }
        if !config.shouldTranslate && editedText == nil { throw OfficeError.invalid("该会议仅转写，未启用翻译。") }
        if !config.shouldTranslate {
            item.finalText = editedText; item.revision += 1; item.translatedText = ""; item.translationModel = nil
            item.translationState = .waiting; item.errorMessage = nil
            try repository.upsert(item); segments = segments.map { $0.id == id ? item : $0 }; return
        }
        if let model = textModel ?? item.translationModel { config.textModels[config.translationProvider.rawValue] = model }
        try config.validate(); item.translationModel = config.textModel
        if let editedText { item.finalText = editedText }
        item.revision += 1
        item.translatedText = ""; item.translationState = .processing; item.errorMessage = nil
        try repository.upsert(item); segments = segments.map { $0.id == id ? item : $0 }; translate(item, token: epoch, configuration: config)
    }
    private func cancelTranslations() {
        for task in translations.values { task.cancel() }
        translations = [:]; translationQueue = []; translatingSources = []
    }
    private func halt() async {
        guard !closing else { return }
        closing = true; defer { closing = false }
        epoch = UUID(); starting = false
        let oldConnections = Array(connectionTasks.values)
        for operation in oldConnections { operation.cancel() }
        for task in captureTasks { task.cancel() }; captureTasks = []
        cancelTranslations()
        let oldCaptures = captures; captures = []
        let oldRecognizers = Array(recognizers.values); recognizers = [:]
        for recognizer in oldRecognizers { recognizer.stopSending() }
        let recognizerClosures = oldRecognizers.map { recognizer in Task { @MainActor in await recognizer.cancel() } }
        for capture in oldCaptures { await capture.stop() }
        for operation in recognizerClosures { await operation.value }
        for operation in oldConnections { _ = await operation.result }
        for archive in archives.values { do { try archive.close() } catch { errorMessage = "录音文件收尾失败，已保存的字幕不受影响。" } }; archives = [:]
        for source in Array(segmenters.keys) {
            if let utterance = segmenters[source]?.finish(), pending[utterance.id] == nil,
               pending.values.reduce(0, { $0 + $1.duration }) + utterance.duration <= 60 { pending[utterance.id] = utterance }
        }
        bufferedSeconds = pending.values.reduce(0) { $0 + $1.duration }; levels = [:]
    }
    public func pause() async {
        guard let id = meeting?.id, !closing else { return }; meeting?.state = .paused; onRecordingStopped?(id); await halt(); try? persist()
    }
    public func stop() async {
        guard let id = meeting?.id, !closing else { return }; meeting?.state = .completed; meeting?.endedAt = Date(); onRecordingStopped?(id); await halt(); try? persist()
    }
    public func interrupt() async { guard let id = meeting?.id, !closing else { return }; meeting?.state = .interrupted; onRecordingStopped?(id); await halt(); try? persist() }
    public func discardBuffered() { guard !isActive else { return }; pending = [:]; segmenters = [:]; bufferedSeconds = 0 }
    public func processUnfinishedAudio() async throws {
        guard !isActive, let meeting, !pending.isEmpty else { return }
        try preflight(meeting.configuration, file: true)
        starting = true; epoch = UUID(); let token = epoch; offline = false
        defer { if token == epoch { starting = false } }
        let items = pending.values.sorted { $0.startSeconds < $1.startSeconds }
        do {
            for source in Set(items.map { $0.id.source }) {
                let recognizer = try await connect(source: source, file: true, offset: 0, token: token)
                for item in items where item.id.source == source { try await recognizer.commit(item) }
            }
            try await drain(token: token); guard token == epoch else { throw CancellationError() }; await halt(); try persist()
        } catch { if token == epoch { await halt() }; throw error }
    }
    public func resume(processBufferedAudio: Bool) async throws {
        guard canResume, let setup = savedSetup else { throw OfficeError.invalid("请重新打开录音设置后开始。") }
        if !pending.isEmpty {
            if processBufferedAudio { try await processUnfinishedAudio() }
            else { discardBuffered() }
        }
        if let url = importURL {
            try await continueImport(url: url); return
        }
        try preflight(setup.configuration, file: false); starting = true; epoch = UUID(); offline = false; let token = epoch
        defer { if token == epoch { starting = false } }
        do { try await beginCaptures(setup, token: token) } catch { if token == epoch { await pause() }; throw error }
    }
    private func drain(token: UUID) async throws {
        let deadline = Date().addingTimeInterval(180)
        while (!pending.isEmpty || !translations.isEmpty || !translationQueue.isEmpty) && token == epoch {
            try Task.checkCancellation()
            if offline { throw OfficeError.invalid("服务连接已中断，未处理片段已保留。") }
            guard Date() < deadline else { throw OfficeError.invalid("处理超时，未完成音频已暂存。") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard token == epoch else { throw CancellationError() }
    }
    public func importAudio(url: URL, setup: MeetingSetup) async throws {
        // Check the local file before creating a new meeting or sending anything.
        let identity = try AudioImportFingerprint.read(url)
        try prepare(setup, file: true); importURL = url; meeting?.importIdentity = identity; try persist()
        if setup.retainAudio, let id = meeting?.id {
            do {
                let name = try MeetingAudioFiles().retainImport(url, meetingID: id)
                meeting?.audioFiles.append(name); try persist()
            } catch { meeting?.state = .failed; try? persist(); throw error }
        }
        try await continueImport(url: url)
    }
    public func restoreImport(url: URL) async throws {
        guard !isActive, !canProcessBuffered, let record = meeting, let identity = record.importIdentity, record.state == .paused || record.state == .interrupted else { throw OfficeError.invalid("请先处理暂存音频，再恢复中断的文件导入。") }
        guard try AudioImportFingerprint.read(url) == identity else { throw OfficeError.invalid("文件与原导入音频不匹配，请重新选择原文件。") }
        savedSetup = MeetingSetup(title: record.title, configuration: record.configuration); savedSetupMeetingID = record.id; importURL = url
        try await continueImport(url: url)
    }
    private func continueImport(url: URL) async throws {
        guard let configuration = meeting?.configuration, let identity = meeting?.importIdentity else { throw OfficeError.invalid("缺少原文件校验信息，请重新导入。") }
        guard try AudioImportFingerprint.read(url) == identity else { throw OfficeError.invalid("原音频文件已变化，已停止续传。请选择原文件恢复。") }
        try preflight(configuration, file: true)
        starting = true; epoch = UUID(); offline = false; let token = epoch
        let offset = meeting?.importOffset ?? 0
        do {
            let recognizer = try await connect(source: .file, file: true, offset: 0, token: token)
            meeting?.state = .recording; starting = false; try persist()
            for try await frame in AudioFileReader.frames(url: url, startFrame: offset) {
                guard token == epoch else { throw CancellationError() }
                while (bufferedSeconds > 35 || translationQueue.count > 10) && token == epoch { try Task.checkCancellation(); if offline { throw OfficeError.invalid("文件识别已中断。") }; try await Task.sleep(for: .milliseconds(100)) }
                try await consume(frame, recognizer: recognizer, token: token)
            }
            guard token == epoch else { throw CancellationError() }
            if let tail = segmenters[.file]?.finish() { pending[tail.id] = tail; try await recognizer.commit(tail) }
            guard token == epoch else { throw CancellationError() }
            bufferedSeconds = pending.values.reduce(0) { $0 + $1.duration }; meeting?.state = .finishing
            try await drain(token: token); guard token == epoch else { throw CancellationError() }; await stop()
        } catch { if token == epoch { errorMessage = ProviderNetwork.safeError(error); await pause() }; throw error }
    }
    public func cleanupRemoteTasks() async {
        guard !isActive else { return }
        let client = TingwuTaskClient(credentials: credentials)
        do {
            for var item in try repository.list() {
                for index in item.remoteTasks.indices where item.remoteTasks[index].needsStop {
                    try await client.stop(taskID: item.remoteTasks[index].taskID); item.remoteTasks[index].needsStop = false; try repository.save(item)
                    if meeting?.id == item.id { meeting = item }
                }
            }
            errorMessage = nil; reloadHistory()
        } catch { errorMessage = "部分听悟云端任务尚未确认关闭，请检查网络和凭证后重试。" }
    }
}
