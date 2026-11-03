import Foundation
import OfficeCore

public struct TingwuTaskHandle { public let taskID: String; let joinURL: URL }
@MainActor public final class TingwuTaskClient {
    private let credentials: any CredentialStore; private let transport: any ProviderTransport
    public init(credentials: any CredentialStore, transport: any ProviderTransport = URLSessionProviderTransport()) { self.credentials = credentials; self.transport = transport }
    private func call(body: [String: Any], operation: String) async throws -> [String: Any] {
        let value = try JSONDecoder().decode(TingwuCredentials.self, from: credentials.read(.aliyunTingwu))
        var body = body; body["AppKey"] = value.appKey
        let url = URL(string: "https://tingwu.cn-beijing.aliyuncs.com/openapi/tingwu/v2/tasks?operation=\(operation)&type=realtime")!
        var request = try jsonRequest(url: url, body: body); request.httpMethod = "PUT"
        request = try AlibabaRequestSigner.sign(request, credentials: value)
        let data = try await transport.data(for: request)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              String(describing: response["Code"] ?? "") == "0" else { throw OfficeError.invalid("听悟任务请求未成功，请核对 AccessKey、AppKey、权限和服务开通状态。") }
        return (response["Data"] as? [String: Any]) ?? [:]
    }
    public func start(context: RecognitionContext, created: ((RemoteTask) throws -> Void)? = nil) async throws -> TingwuTaskHandle {
        var input: [String: Any] = ["Format": "pcm", "SampleRate": 16000, "SourceLanguage": context.language == "ja" ? "ja" : "cn"]
        if context.configuration.effectiveRecognitionLanguage == .mixed { input["SourceLanguage"] = "multilingual"; input["LanguageHints"] = ["ja", "cn"] }
        let response = try await call(body: ["Input": input, "TaskKey": "office.\(context.meetingID).\(context.source.rawValue).\(UUID())"], operation: "start")
        guard let id = response["TaskId"] as? String else { throw OfficeError.invalid("听悟未返回任务编号，请到服务控制台核对本次任务。") }
        do {
            try created?(RemoteTask(taskID: id, source: context.source))
            guard let join = response["MeetingJoinUrl"] as? String, let url = URL(string: join), url.scheme == "wss", url.host == "tingwu-realtime-cn-beijing.aliyuncs.com" else { throw OfficeError.invalid("听悟未返回有效的官方推流地址。") }
            return TingwuTaskHandle(taskID: id, joinURL: url)
        } catch {
            let originalError = error
            do {
                try await Task { @MainActor in try await self.stop(taskID: id) }.value
                try? created?(RemoteTask(taskID: id, source: context.source, needsStop: false))
            } catch { throw OfficeError.invalid("听悟任务未能连接，且云端尚未确认关闭，请在会议页清理云端任务。") }
            throw originalError
        }
    }
    public func stop(taskID: String) async throws { _ = try await call(body: ["Input": ["TaskId": taskID]], operation: "stop") }
}
@MainActor public final class TingwuSpeechRecognizer: SpeechRecognizer {
    public var onEvent: ((TranscriptEvent) -> Void)?; public var onFailure: ((Error) -> Void)?; public var onRemoteTask: ((RemoteTask) throws -> Void)?
    private let converter = PCMConversionStream()
    private let client: TingwuTaskClient; private var handle: TingwuTaskHandle?; private var context: RecognitionContext?
    private var socket: URLSessionWebSocketTask?; private var receiver: Task<Void, Never>?; private var epoch = UUID()
    private var remoteClosing: Task<Void, Error>?
    private var sourceID: AudioSourceID?
    private var streamTaskID = ""; private var completed: Set<Int> = []
    public init(credentials: any CredentialStore, transport: any ProviderTransport = URLSessionProviderTransport()) { client = TingwuTaskClient(credentials: credentials, transport: transport) }
    private func command(_ name: String) async throws {
        guard let socket else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: ["header": ["message_id": UUID().uuidString.replacingOccurrences(of: "-", with: ""), "task_id": streamTaskID, "namespace": "SpeechTranscriber", "name": name, "appkey": "default"], "payload": [:]])
        try await socket.send(.string(String(data: data, encoding: .utf8)!))
    }
    private func object(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive(); let data: Data
        switch message { case .string(let value): data = Data(value.utf8); case .data(let value): data = value; @unknown default: throw OfficeError.invalid("听悟返回未知消息。") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    public func start(_ context: RecognitionContext) async throws {
        self.context = context; sourceID = context.source; epoch = UUID(); streamTaskID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            let handle = try await client.start(context: context, created: { [weak self] remote in try self?.onRemoteTask?(remote) }); self.handle = handle
            try Task.checkCancellation()
            var request = URLRequest(url: handle.joinURL); request.setValue("default", forHTTPHeaderField: "X-NLS-Token")
            let socket = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil).webSocketTask(with: request)
            self.socket = socket; socket.resume(); try await command("StartTranscription")
            let timeout = Task { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
            defer { timeout.cancel() }
            while true {
                let response = try await object(socket)
                let header = response["header"] as? [String: Any] ?? [:]
                if header["name"] as? String == "TranscriptionStarted" { break }
                if header["name"] as? String == "TaskFailed" { throw OfficeError.invalid("听悟推流启动失败，请检查任务配置。") }
            }
            try Task.checkCancellation()
            let token = epoch
            receiver = Task { @MainActor [weak self] in
                guard let self else { return }
                do { while token == self.epoch && !Task.isCancelled { let message = try await self.object(socket); guard token == self.epoch else { return }; try self.handleMessage(message) } }
                catch { if token == self.epoch && !Task.isCancelled { self.onFailure?(error) } }
            }
        } catch { await cancel(); throw error }
    }
    func handleMessage(_ object: [String: Any]) throws {
        guard let context, let header = object["header"] as? [String: Any] else { return }
        let name = header["name"] as? String ?? ""
        if name == "TaskFailed" { throw OfficeError.invalid("听悟识别已中断，请核对服务状态和额度。") }
        guard name == "SentenceEnd" || name == "TranscriptionResultChanged", let payload = object["payload"] as? [String: Any],
              let index = payload["index"] as? Int, let text = payload["result"] as? String, !completed.contains(index) else { return }
        let words = payload["words"] as? [[String: Any]] ?? []
        let start = Double((words.first?["startTime"] as? Int) ?? 0) / 1000
        let end = Double((payload["time"] as? Int) ?? 0) / 1000
        onEvent?(TranscriptEvent(id: context.id(context.nextSequence + index), kind: name == "SentenceEnd" ? .final : .partial, text: text,
                                 providerItemID: String(index), startSeconds: start, endSeconds: end))
        if name == "SentenceEnd" { completed.insert(index) }
        if let stash = payload["stash_result"] as? [String: Any], let stashIndex = stash["index"] as? Int, let value = stash["text"] as? String, !completed.contains(stashIndex) {
            onEvent?(TranscriptEvent(id: context.id(context.nextSequence + stashIndex), kind: .partial, text: value, startSeconds: Double((stash["beginTime"] as? Int) ?? 0) / 1000))
        }
    }
    public func append(_ frame: PCMFrame) async throws {
        guard context != nil, let socket else { throw CancellationError() }
        let data = try converter.convert(PCMCodec.buffer(frame.samples), rate: 16000)
        if !data.isEmpty { try await socket.send(.data(data)) }
    }
    public func commit(_ utterance: AudioUtterance) async throws {}
    public func stopSending() {
        epoch = UUID(); receiver?.cancel(); receiver = nil; context = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
    public func cancel() async {
        stopSending()
        let source = sourceID
        if let handle, let source {
            do {
                let operation: Task<Void, Error>
                if let current = remoteClosing { operation = current }
                else { operation = Task { @MainActor in try await self.client.stop(taskID: handle.taskID) }; remoteClosing = operation }
                try await operation.value
                try onRemoteTask?(RemoteTask(taskID: handle.taskID, source: source, needsStop: false)); self.handle = nil; sourceID = nil; remoteClosing = nil
            }
            catch { remoteClosing = nil; onFailure?(OfficeError.invalid("听悟云端任务待关闭，请联网后点击清理云端任务。")) }
        }
    }
}
