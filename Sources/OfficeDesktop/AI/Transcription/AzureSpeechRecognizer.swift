import Foundation
import MicrosoftCognitiveServicesSpeech
import OfficeCore

public struct AzureRecognitionEvent: Sendable {
    public var text: String; public var offset: Double; public var duration: Double; public var final: Bool
}
@MainActor public protocol AzureSpeechBridge: AnyObject {
    var onResult: ((AzureRecognitionEvent) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start(credentials: AzureSpeechCredentials, context: RecognitionContext) async throws
    func write(_ data: Data) throws
    func stop() async
}
@MainActor public final class NativeAzureSpeechBridge: AzureSpeechBridge {
    public var onResult: ((AzureRecognitionEvent) -> Void)?; public var onFailure: ((Error) -> Void)?
    private var recognizer: SPXSpeechRecognizer?; private var input: SPXPushAudioInputStream?; private var epoch = UUID()
    public init() {}
    public func start(credentials: AzureSpeechCredentials, context: RecognitionContext) async throws {
        let speech = try SPXSpeechConfiguration(subscription: credentials.key, region: credentials.region)
        speech.speechRecognitionLanguage = context.language == "ja" ? "ja-JP" : "zh-CN"
        let input = SPXPushAudioInputStream(audioFormat: SPXAudioStreamFormat(usingPCMWithSampleRate: 16000, bitsPerSample: 16, channels: 1)!)!
        let audio = SPXAudioConfiguration(streamInput: input)!
        let recognizer: SPXSpeechRecognizer
        if context.configuration.effectiveRecognitionLanguage == .mixed {
            speech.setPropertyTo("Continuous", byName: "SpeechServiceConnection_LanguageIdMode")
            recognizer = try SPXSpeechRecognizer(speechConfiguration: speech, autoDetectSourceLanguageConfiguration: SPXAutoDetectSourceLanguageConfiguration(["ja-JP", "zh-CN"]), audioConfiguration: audio)
        } else { recognizer = try SPXSpeechRecognizer(speechConfiguration: speech, audioConfiguration: audio) }
        self.input = input; self.recognizer = recognizer; epoch = UUID(); let token = epoch
        recognizer.addRecognizingEventHandler { [weak self] _, event in
            let result = event.result
            let value = AzureRecognitionEvent(text: result.text ?? "", offset: Double(result.offset) / 10_000_000, duration: Double(result.duration) / 10_000_000, final: false)
            Task { @MainActor in guard let self, self.epoch == token else { return }; self.onResult?(value) }
        }
        recognizer.addRecognizedEventHandler { [weak self] _, event in
            let result = event.result
            let value = AzureRecognitionEvent(text: result.text ?? "", offset: Double(result.offset) / 10_000_000, duration: Double(result.duration) / 10_000_000, final: true)
            Task { @MainActor in guard let self, self.epoch == token else { return }; if !value.text.isEmpty { self.onResult?(value) } }
        }
        recognizer.addCanceledEventHandler { [weak self] _, _ in
            Task { @MainActor in guard let self, self.epoch == token else { return }; self.onFailure?(OfficeError.invalid("Azure 识别连接已中断，请检查密钥、区域、权限和额度。")) }
        }
        do { try await Task.detached { try recognizer.startContinuousRecognition() }.value }
        catch { await stop(); throw OfficeError.invalid("Azure 识别未能启动，请检查 Speech 资源配置。") }
    }
    public func write(_ data: Data) throws {
        guard let input, recognizer != nil else { throw CancellationError() }; input.write(data)
    }
    public func stop() async {
        epoch = UUID(); let recognizer = self.recognizer; self.recognizer = nil
        input?.close(); input = nil
        if let recognizer { await Task.detached { try? recognizer.stopContinuousRecognition() }.value }
    }
}
@MainActor public final class AzureSpeechRecognizer: SpeechRecognizer {
    public var onEvent: ((TranscriptEvent) -> Void)?; public var onFailure: ((Error) -> Void)?; public var onRemoteTask: ((RemoteTask) throws -> Void)?
    private let converter = PCMConversionStream()
    private let credentials: any CredentialStore; private let bridge: any AzureSpeechBridge
    private var context: RecognitionContext?; private var mapping: [Int64: Int] = [:]; private var nextSequence = 0; private var completed: Set<Int64> = []
    public init(credentials: any CredentialStore, bridge: any AzureSpeechBridge) { self.credentials = credentials; self.bridge = bridge }
    public func start(_ context: RecognitionContext) async throws {
        let data = try credentials.read(.azureSpeech)
        let value = try JSONDecoder().decode(AzureSpeechCredentials.self, from: data)
        self.context = context; nextSequence = context.nextSequence
        bridge.onResult = { [weak self] result in
            guard let self, let context = self.context else { return }
            let key = Int64((result.offset * 10_000_000).rounded())
            if self.completed.contains(key) { return }
            if self.mapping[key] == nil { self.mapping[key] = self.nextSequence; self.nextSequence += 1 }
            let id = context.id(self.mapping[key]!)
            self.onEvent?(TranscriptEvent(id: id, kind: result.final ? .final : .partial, text: result.text, providerItemID: String(key), startSeconds: result.offset, endSeconds: result.offset + result.duration))
            if result.final { self.completed.insert(key) }
        }
        bridge.onFailure = { [weak self] error in self?.onFailure?(error) }
        try await bridge.start(credentials: value, context: context)
        try Task.checkCancellation()
    }
    public func append(_ frame: PCMFrame) async throws { guard context != nil else { throw CancellationError() }; let data = try converter.convert(PCMCodec.buffer(frame.samples), rate: 16000); if !data.isEmpty { try bridge.write(data) } }
    public func commit(_ utterance: AudioUtterance) async throws {}
    public func stopSending() { context = nil; bridge.onResult = nil; bridge.onFailure = nil }
    public func cancel() async { stopSending(); await bridge.stop() }
}
