import Foundation
import OfficeCore

@MainActor public final class OpenAIRealtimeRecognizer: SpeechRecognizer {
    public var onEvent: ((TranscriptEvent) -> Void)?; public var onFailure: ((Error) -> Void)?; public var onRemoteTask: ((RemoteTask) throws -> Void)?
    private let credentials: any CredentialStore
    private var context: RecognitionContext?; private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?; private var epoch = UUID()
    private var sequence = 0; private var currentStart = 0.0
    private var waiting: [AudioUtterance] = []; private var mapped: [String: AudioUtterance] = [:]; private var partial: [String: String] = [:]
    private var completedItems: Set<String> = []
    private var fallbackIDs: [String: SegmentID] = [:]; private var pendingSeconds = 0.0
    public init(credentials: any CredentialStore) { self.credentials = credentials }
    private func send(_ object: [String: Any]) async throws {
        guard let socket, context != nil else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(data: data, encoding: .utf8)!))
    }
    private func receiveObject(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message { case .string(let value): data = Data(value.utf8); case .data(let value): data = value; @unknown default: throw OfficeError.invalid("语音服务返回未知格式。") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    public func start(_ context: RecognitionContext) async throws {
        let key = String(data: try credentials.read(.openai), encoding: .utf8) ?? ""
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.timeoutInterval = 20
        let socket = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil).webSocketTask(with: request); self.socket = socket; self.context = context; sequence = context.nextSequence; epoch = UUID()
        socket.resume()
        let timeout = Task { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { timeout.cancel() }
        do {
            var transcription: [String: Any] = ["model": context.configuration.realtimeModel, "languages": context.configuration.effectiveRecognitionLanguage == .mixed ? ["ja", "zh"] : [context.language], "delay": "low"]
            let terms = context.configuration.glossary.map(\.source).filter { !$0.contains("\n") && !$0.contains("<") && !$0.contains(">") }
            if !terms.isEmpty { transcription["keywords"] = terms }
            try await send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": ["format": ["type": "audio/pcm", "rate": 24000], "transcription": transcription, "turn_detection": NSNull()]]]])
            while true {
                let object = try await receiveObject(socket)
                if object["type"] as? String == "session.updated" { break }
                if object["type"] as? String == "error" { throw OfficeError.invalid("OpenAI 拒绝了语音配置，请检查模型、密钥和访问权限。") }
            }
            try Task.checkCancellation()
            let token = epoch
            receiver = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled && token == self.epoch {
                        let object = try await self.receiveObject(socket)
                        guard token == self.epoch else { return }; try self.handle(object)
                    }
                } catch { if token == self.epoch && !Task.isCancelled { self.onFailure?(error) } }
            }
        } catch { await cancel(); throw error }
    }
    public func append(_ frame: PCMFrame) async throws {
        guard context != nil else { throw CancellationError() }
        guard pendingSeconds + frame.duration <= 60 else { throw OfficeError.invalid("待识别音频已达到 60 秒，已暂停。") }
        if pendingSeconds == 0 { currentStart = frame.startSeconds }
        pendingSeconds += frame.duration
        try await send(["type": "input_audio_buffer.append", "audio": frame.samples.base64EncodedString()])
    }
    public func commit(_ utterance: AudioUtterance) async throws {
        waiting.append(utterance); sequence = max(sequence, utterance.id.sequence + 1); currentStart = utterance.startSeconds + utterance.duration
        try await send(["type": "input_audio_buffer.commit"])
    }
    func handle(_ object: [String: Any]) throws {
        guard let context, let type = object["type"] as? String else { return }
        if type == "error" || type == "conversation.item.input_audio_transcription.failed" { throw OfficeError.invalid("OpenAI 语音识别失败，请检查模型权限和服务额度后重试。") }
        guard let itemID = object["item_id"] as? String, !completedItems.contains(itemID) else { return }
        if type == "input_audio_buffer.committed", !waiting.isEmpty { mapped[itemID] = waiting.removeFirst(); return }
        let item = mapped[itemID]
        let id = item?.id ?? fallbackIDs[itemID] ?? context.id(sequence)
        if fallbackIDs[itemID] == nil { fallbackIDs[itemID] = id }
        if type == "conversation.item.input_audio_transcription.delta", let text = object["delta"] as? String {
            partial[itemID, default: ""] += text
            onEvent?(TranscriptEvent(id: id, kind: .partial, text: partial[itemID] ?? "", providerItemID: itemID, startSeconds: item?.startSeconds ?? currentStart))
        } else if type == "conversation.item.input_audio_transcription.completed", let text = object["transcript"] as? String {
            onEvent?(TranscriptEvent(id: id, kind: .final, text: text, providerItemID: itemID, startSeconds: item?.startSeconds ?? currentStart, endSeconds: item.map { $0.startSeconds + $0.duration } ?? currentStart))
            completedItems.insert(itemID)
            pendingSeconds = max(0, pendingSeconds - (item?.duration ?? 0)); mapped.removeValue(forKey: itemID); partial.removeValue(forKey: itemID); fallbackIDs.removeValue(forKey: itemID)
        }
    }
    public func stopSending() {
        epoch = UUID(); context = nil; receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; waiting = []; mapped = [:]; partial = [:]; fallbackIDs = [:]; pendingSeconds = 0; completedItems = []
    }
    public func cancel() async { stopSending() }
}
