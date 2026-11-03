import Foundation
import OfficeCore

@MainActor public final class FileSpeechRecognizer: SpeechRecognizer {
    public var onEvent: ((TranscriptEvent) -> Void)?; public var onFailure: ((Error) -> Void)?; public var onRemoteTask: ((RemoteTask) throws -> Void)?
    private let credentials: any CredentialStore; private let transport: any ProviderTransport
    private var context: RecognitionContext?; private var pending: [AudioUtterance] = []; private var worker: Task<Void, Never>?
    private var epoch = UUID(); private var queuedSeconds = 0.0
    public init(credentials: any CredentialStore, transport: any ProviderTransport = URLSessionProviderTransport()) { self.credentials = credentials; self.transport = transport }
    public func start(_ context: RecognitionContext) async throws {
        guard context.configuration.speechProvider.supportsFiles else { throw OfficeError.invalid("所选服务不支持文件/分段识别。") }
        _ = try credentials.read(context.configuration.speechProvider); self.context = context; epoch = UUID()
    }
    public func append(_ frame: PCMFrame) async throws {}
    public func commit(_ utterance: AudioUtterance) async throws {
        guard context != nil else { throw CancellationError() }
        guard queuedSeconds + utterance.duration <= 60.001 else { throw OfficeError.invalid("识别积压已达到 60 秒，请暂停后继续处理。") }
        queuedSeconds += utterance.duration; pending.append(utterance)
        if worker == nil { run() }
    }
    public func request(_ utterance: AudioUtterance) throws -> URLRequest {
        guard let context, let base = context.configuration.speechProvider.baseURL else { throw OfficeError.invalid("语音服务尚未启动。") }
        let provider = context.configuration.speechProvider
        let key = String(data: try credentials.read(provider), encoding: .utf8) ?? ""
        let model = provider == .siliconflow ? context.configuration.siliconSpeechModel : context.configuration.fileModel
        let boundary = "office-\(UUID().uuidString)"; var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        if provider == .openai && context.configuration.effectiveRecognitionLanguage != .mixed {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(context.language)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(PCMCodec.wav(utterance.pcm)); add("\r\n--\(boundary)--\r\n")
        guard body.count <= 20_000_000 else { throw OfficeError.invalid("单次音频超过请求限制。") }
        var request = URLRequest(url: base.appendingPathComponent("audio/transcriptions")); request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); request.httpBody = body
        return request
    }
    private func transcribe(_ item: AudioUtterance) async throws -> Data {
        let request = try request(item)
        do { return try await transport.data(for: request) }
        catch let error as ProviderHTTPError where error.status == 429 {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(min(30, max(0, error.retryAfter ?? 1))))
            try Task.checkCancellation()
            return try await transport.data(for: request)
        }
    }
    private func run() {
        let token = epoch
        worker = Task { @MainActor [weak self] in
            guard let self else { return }; defer { if token == self.epoch { self.worker = nil } }
            while !self.pending.isEmpty && token == self.epoch {
                let item = self.pending[0]
                do {
                    let data = try await self.transcribe(item); try Task.checkCancellation()
                    guard token == self.epoch else { return }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String else { throw OfficeError.invalid("识别服务返回格式不正确。") }
                    self.pending.removeFirst(); self.queuedSeconds -= item.duration
                    self.onEvent?(TranscriptEvent(id: item.id, kind: .final, text: text, startSeconds: item.startSeconds, endSeconds: item.startSeconds + item.duration))
                } catch {
                    guard token == self.epoch, !Task.isCancelled else { return }
                    self.onFailure?(error); return
                }
            }
        }
    }
    public func stopSending() { epoch = UUID(); context = nil; worker?.cancel(); worker = nil; pending = []; queuedSeconds = 0 }
    public func cancel() async { stopSending() }
}
