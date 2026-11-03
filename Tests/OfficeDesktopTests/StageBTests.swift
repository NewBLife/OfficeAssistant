import Foundation
import Testing
import AVFoundation
import OfficeCore
@testable import OfficeDesktop

@MainActor final class TestCredentials: CredentialStore {
    var values: [AIProvider: Data] = [.openai: Data("fake-openai".utf8), .deepseek: Data("fake-deepseek".utf8), .siliconflow: Data("fake-silicon".utf8)]
    func contains(_ provider: AIProvider) throws -> Bool { values[provider] != nil }
    func save(_ secret: Data, for provider: AIProvider) throws { try CredentialValidation.validate(secret, for: provider); values[provider] = secret }
    func read(_ provider: AIProvider) throws -> Data { guard let value = values[provider] else { throw OfficeError.invalid("缺少测试凭证") }; return value }
}
final class TestTransport: ProviderTransport {
    var responses: [Data] = []
    func data(for request: URLRequest) async throws -> Data { Data("{\"text\":\"会議\"}".utf8) }
    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        let values = responses
        return AsyncThrowingStream { continuation in for value in values { continuation.yield(value) }; continuation.finish() }
    }
}
@MainActor @Suite struct CredentialStoreTests {
    @Test func testBlankCredentialRejectedAndOldValueRetained() throws {
        let store = TestCredentials(); let original = try store.read(.openai)
        #expect(throws: (any Error).self) { try store.save(Data(" \n".utf8), for: .openai) }
        #expect(try store.read(.openai) == original)
    }
    @Test func testAzureAndTingwuRequireTheirOwnFields() throws {
        #expect(throws: (any Error).self) { try CredentialValidation.validate(Data("not-json".utf8), for: .azureSpeech) }
        let value = AzureSpeechCredentials(key: "fake", region: "")
        #expect(throws: (any Error).self) { try CredentialValidation.validate(JSONEncoder().encode(value), for: .azureSpeech) }
        let tingwu = TingwuCredentials(accessKeyID: "fake", accessKeySecret: "", appKey: "app")
        #expect(throws: (any Error).self) { try CredentialValidation.validate(JSONEncoder().encode(tingwu), for: .aliyunTingwu) }
    }
    @Test func testNetworkRejectsCredentialsAtUntrustedHost() {
        #expect(!ProviderNetwork.allowed(URL(string: "https://api.openai.com.attacker.example/v1/models")!))
        #expect(!ProviderNetwork.allowed(URL(string: "http://api.openai.com/v1/models")!))
        #expect(ProviderNetwork.allowed(URL(string: "https://api.deepseek.com/chat/completions")!))
    }
    @Test func testNoModelDiscoveryAtAzure() async {
        let client = ProviderModelClient(credentials: TestCredentials(), transport: TestTransport())
        await #expect(throws: (any Error).self) { try await client.models(provider: .azureSpeech) }
    }
}
struct SSEDecoderTests {
    @Test func testSplitUnicodeAndCRLF() throws {
        var decoder = SSEDecoder(); let data = Data("data: 会議\r\n\r\n".utf8)
        var output: [SSEMessage] = []
        for byte in data { output += try decoder.feed(Data([byte])) }
        #expect(output.count == 1); #expect(output[0].data == "会議")
    }
    @Test func testMultilineData() throws {
        var decoder = SSEDecoder()
        let output = try decoder.feed(Data("event: response\ndata: one\ndata: two\n\n".utf8))
        #expect(output.first?.data == "one\ntwo"); #expect(output.first?.event == "response")
    }
}
@MainActor @Suite struct TranslationTests {
    @Test func testSelectedProviderUsesOnlyItsOwnKeyAndBoundedContext() throws {
        let service = ChatCompletionTranslator(credentials: TestCredentials(), transport: TestTransport())
        let segment = TranscriptSegment(id: SegmentID(meetingID: UUID(), source: .microphone, sequence: 0))
        let request = try service.request(segment: segment, configuration: AIConfiguration(), context: [])
        #expect(request.url?.host == "api.deepseek.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-deepseek")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    }
    @Test func testReasoningIgnoredAndProperFinishRequired() async throws {
        let transport = TestTransport()
        transport.responses = [Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private\",\"content\":\"译文\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)]
        let service = ChatCompletionTranslator(credentials: TestCredentials(), transport: transport)
        let segment = TranscriptSegment(id: SegmentID(meetingID: UUID(), source: .microphone, sequence: 0))
        var output: [TranscriptEvent] = []
        for try await item in service.translate(segment: segment, configuration: AIConfiguration(), context: []) { output.append(item) }
        #expect(output.last?.text == "译文")
    }
    @Test func testInterruptedStreamDoesNotMarkTranslationComplete() async {
        let transport = TestTransport(); transport.responses = [Data("data: {\"choices\":[{\"delta\":{\"content\":\"一半\"}}]}\n\n".utf8)]
        let service = ChatCompletionTranslator(credentials: TestCredentials(), transport: transport)
        let segment = TranscriptSegment(id: SegmentID(meetingID: UUID(), source: .microphone, sequence: 0))
        var failed = false
        do { for try await _ in service.translate(segment: segment, configuration: AIConfiguration(), context: []) {} } catch { failed = true }
        #expect(failed)
    }
}
@MainActor @Suite struct MeetingPersistenceTests {
    @Test func testRoundTripIndependentStore() throws {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        let meeting = MeetingSession(title: "会議", configuration: AIConfiguration()); try repo.save(meeting)
        var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .system, sequence: 0)); segment.finalText = "会議"
        try repo.upsert(segment)
        #expect(try repo.list() == [meeting]); #expect(try repo.segments(meetingID: meeting.id) == [segment])
    }
    @Test func testReopenInterruptedDoesNotRecord() throws {
        let repo = try CoreDataMeetingRepository(inMemory: true); var meeting = MeetingSession(title: "中断", configuration: AIConfiguration()); meeting.state = .recording; try repo.save(meeting)
        let service = MeetingSessionController(repository: repo, credentials: TestCredentials())
        #expect(service.history.first?.state == .interrupted); #expect(!service.isActive)
    }
}
struct PCMConverterTests {
    @Test func testResampleDurationAndWAV() throws {
        let pcm = Data(count: 48000)
        let sixteen = try PCMCodec.sixteenK(pcm)
        #expect(abs(sixteen.count - 32000) < 256)
        let wav = PCMCodec.wav(pcm); #expect(wav.count == pcm.count + 44)
        #expect(String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
    }
    @Test func testStreamingResamplerKeepsDurationAcrossSmallBlocks() throws {
        let stream = PCMConversionStream(); var output = Data()
        for _ in 0..<100 { output.append(try stream.convert(PCMCodec.buffer(Data(count: 480)), rate: 16000)) }
        output.append(try stream.finish())
        #expect(abs(output.count - 32000) <= 2)
    }
    @Test func testFileReaderResumeUsesCanonicalFrameOffset() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try PCMCodec.wav(Data(count: 96000)).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        var total = 0; var start: Double?
        for try await frame in AudioFileReader.frames(url: url, startFrame: 24000) { if start == nil { start = frame.startSeconds }; total += frame.samples.count }
        #expect(start == 1); #expect(abs(total - 48000) <= 2)
    }
    @Test func testInvalidFileFailsBeforeYield() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not an audio file".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        var yielded = false; var failed = false
        do { for try await _ in AudioFileReader.frames(url: url) { yielded = true } } catch { failed = true }
        #expect(failed); #expect(!yielded)
    }
}
