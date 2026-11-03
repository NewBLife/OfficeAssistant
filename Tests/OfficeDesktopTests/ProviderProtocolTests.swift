import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

struct AlibabaRequestSignerTests {
    @Test func testCanonicalQueryEncodingAndOrder() {
        let values = [URLQueryItem(name: "type", value: "realtime"), URLQueryItem(name: "name", value: "日语 &"), URLQueryItem(name: "operation", value: "start")]
        #expect(AlibabaRequestSigner.canonicalQuery(values) == "name=%E6%97%A5%E8%AF%AD%20%26&operation=start&type=realtime")
    }
    @Test func testSHA256AndSignedSTSHeader() throws {
        #expect(AlibabaRequestSigner.hash(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        var request = URLRequest(url: URL(string: "https://tingwu.cn-beijing.aliyuncs.com/openapi/tingwu/v2/tasks?type=realtime")!)
        request.httpMethod = "PUT"; request.httpBody = Data("{}".utf8)
        let signed = try AlibabaRequestSigner.sign(request, credentials: TingwuCredentials(accessKeyID: "test-id", accessKeySecret: "test-secret", appKey: "test-app", securityToken: "test-token"), date: Date(timeIntervalSince1970: 0), nonce: "fixed-nonce")
        #expect(signed.value(forHTTPHeaderField: "Authorization")?.contains("x-acs-security-token") == true)
        #expect(signed.value(forHTTPHeaderField: "x-acs-security-token") == "test-token")
        #expect(signed.value(forHTTPHeaderField: "x-acs-date") == "1970-01-01T00:00:00Z")
    }
}
@MainActor final class FakeAzureBridge: AzureSpeechBridge {
    var onResult: ((AzureRecognitionEvent) -> Void)?; var onFailure: ((Error) -> Void)?
    var writes = 0; var stopped = false; var receivedSource: AudioSourceID?
    func start(credentials: AzureSpeechCredentials, context: RecognitionContext) async throws { receivedSource = context.source }
    func write(_ data: Data) throws { writes += 1 }
    func stop() async { stopped = true }
}
@MainActor @Suite struct AzureSpeechRecognizerTests {
    @Test func testSelectedSourceAndStablePartialFinal() async throws {
        let creds = TestCredentials(); try creds.save(JSONEncoder().encode(AzureSpeechCredentials(key: "test-key", region: "japaneast")), for: .azureSpeech)
        let bridge = FakeAzureBridge(); let service = AzureSpeechRecognizer(credentials: creds, bridge: bridge)
        let context = RecognitionContext(meetingID: UUID(), source: .system, configuration: AIConfiguration())
        var results: [TranscriptEvent] = []; service.onEvent = { results.append($0) }
        try await service.start(context)
        bridge.onResult?(AzureRecognitionEvent(text: "会", offset: 0.5, duration: 0.1, final: false))
        bridge.onResult?(AzureRecognitionEvent(text: "会議", offset: 0.5, duration: 1, final: true))
        bridge.onResult?(AzureRecognitionEvent(text: "会議", offset: 0.5, duration: 1, final: true))
        #expect(bridge.receivedSource == .system); #expect(results.count == 2); #expect(results[0].id == results[1].id)
        await service.cancel(); #expect(bridge.stopped)
        await #expect(throws: (any Error).self) { try await service.append(PCMFrame(source: .system, sequence: 0, startSeconds: 0, samples: Data(count: 4800))) }
    }
}
@MainActor final class TingwuFakeTransport: ProviderTransport {
    var operations: [String] = []
    func data(for request: URLRequest) async throws -> Data {
        let operation = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "operation" }!.value!
        operations.append(operation)
        if operation == "stop" { return Data("{\"Code\":\"0\",\"Data\":{}}".utf8) }
        return Data("{\"Code\":\"0\",\"Data\":{\"TaskId\":\"test-task\",\"MeetingJoinUrl\":\"wss://untrusted.example/ws?secret=fake\"}}".utf8)
    }
    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
}
@MainActor @Suite struct TingwuRecognizerTests {
    @Test func testInvalidJoinURLClosesCreatedRemoteTask() async throws {
        let creds = TestCredentials(); try creds.save(JSONEncoder().encode(TingwuCredentials(accessKeyID: "test-id", accessKeySecret: "test-secret", appKey: "test-app")), for: .aliyunTingwu)
        let transport = TingwuFakeTransport(); let service = TingwuTaskClient(credentials: creds, transport: transport)
        var remote: [RemoteTask] = []
        await #expect(throws: (any Error).self) { try await service.start(context: RecognitionContext(meetingID: UUID(), source: .system, configuration: AIConfiguration()), created: { remote.append($0) }) }
        #expect(transport.operations == ["start", "stop"])
        #expect(remote.first?.needsStop == true); #expect(remote.last?.needsStop == false)
    }
}
