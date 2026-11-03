import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor final class SpeechOnlyCredentials: CredentialStore {
    var reads: [AIProvider] = []
    func contains(_ provider: AIProvider) throws -> Bool { provider == .openai }
    func save(_ secret: Data, for provider: AIProvider) throws {}
    func read(_ provider: AIProvider) throws -> Data {
        reads.append(provider)
        guard provider == .openai else { throw OfficeError.invalid("未配置翻译凭证") }
        return Data("fake-openai".utf8)
    }
}
@MainActor @Suite struct TranscriptionOnlyTests {
    @Test func testOnlySpeechCredentialRequiredAndNoTranslationSent() async throws {
        let credentials = SpeechOnlyCredentials(); let transport = HeldTranslationTransport()
        let repo = try CoreDataMeetingRepository(inMemory: true); let speech = TestRecognizer()
        let controller = MeetingSessionController(repository: repo, credentials: credentials, translator: ChatCompletionTranslator(credentials: credentials, transport: transport), factory: { _, _ in speech }, captureFactory: { _ in [(.microphone, TestCapture())] })
        var config = AIConfiguration(); config.translationEnabled = false; config.recognitionLanguage = .chinese
        try await controller.start(MeetingSetup(title: "transcription only", configuration: config))
        let id = SegmentID(meetingID: controller.meeting!.id, source: .microphone, sequence: 0)
        speech.onEvent?(TranscriptEvent(id: id, kind: .final, text: "明天下午三点开会。"))
        for _ in 0..<20 { await Task.yield() }
        #expect(credentials.reads == [.openai]); #expect(transport.requests.isEmpty)
        #expect(try repo.segments(meetingID: id.meetingID).first?.finalText == "明天下午三点开会。")
        #expect(throws: (any Error).self) { try controller.retryTranslation(id) }
        try controller.retryTranslation(id, editedText: "明天下午四点开会。")
        #expect(controller.segments.first?.finalText == "明天下午四点开会。")
        #expect(transport.requests.isEmpty); #expect(credentials.reads == [.openai])
        await controller.stop()
    }
    @Test func testTranslatorRejectsTranscriptionOnlyWithoutReadingKey() {
        let credentials = SpeechOnlyCredentials()
        let translator = ChatCompletionTranslator(credentials: credentials, transport: TestTransport())
        var config = AIConfiguration(); config.translationEnabled = false
        let segment = TranscriptSegment(id: SegmentID(meetingID: UUID(), source: .file, sequence: 0))
        #expect(throws: (any Error).self) { try translator.request(segment: segment, configuration: config, context: []) }
        #expect(credentials.reads.isEmpty)
    }
    @Test func testOpenAIFileReceivesSelectedRecognitionLanguage() async throws {
        let speech = FileSpeechRecognizer(credentials: SpeechOnlyCredentials(), transport: TestTransport())
        var config = AIConfiguration(); config.translationEnabled = false; config.recognitionLanguage = .chinese
        let context = RecognitionContext(meetingID: UUID(), source: .file, configuration: config)
        #expect(context.language == "zh")
        try await speech.start(context)
        let request = try speech.request(AudioUtterance(id: context.id(0), startSeconds: 0, pcm: Data(count: 48000)))
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"language\"\r\n\r\nzh\r\n"))
        await speech.cancel()
    }
}
