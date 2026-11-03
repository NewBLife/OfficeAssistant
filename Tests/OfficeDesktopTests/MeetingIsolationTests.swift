import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor final class HangingStopCapture: AudioCapture {
    var stopEntered = false
    var release: CheckedContinuation<Void, Never>?
    func start() async throws -> AsyncThrowingStream<PCMFrame, Error> { AsyncThrowingStream { _ in } }
    func stop() async { stopEntered = true; await withCheckedContinuation { release = $0 } }
}
@MainActor final class HangingStartCapture: AudioCapture {
    var entered = false; var release: CheckedContinuation<Void, Never>?
    func start() async throws -> AsyncThrowingStream<PCMFrame, Error> {
        entered = true; await withCheckedContinuation { release = $0 }; return AsyncThrowingStream { _ in }
    }
    func stop() async {}
}
final class HeldTranslationTransport: ProviderTransport {
    var requests: [URLRequest] = []
    var streams: [AsyncThrowingStream<Data, Error>.Continuation] = []
    func data(for request: URLRequest) async throws -> Data { Data() }
    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        requests.append(request)
        return AsyncThrowingStream { streams.append($0) }
    }
}
@MainActor @Suite struct MeetingIsolationTests {
    @Test func testPauseClosesUploadBeforeWaitingForDevice() async throws {
        let capture = HangingStopCapture(); let speech = TestRecognizer()
        let controller = MeetingSessionController(repository: try CoreDataMeetingRepository(inMemory: true), credentials: TestCredentials(), factory: { _, _ in speech }, captureFactory: { _ in [(.microphone, capture)] })
        try await controller.start(MeetingSetup(title: "A", configuration: AIConfiguration()))
        let stopping = Task { await controller.pause() }
        for _ in 0..<100 where !capture.stopEntered { await Task.yield() }
        #expect(capture.stopEntered); #expect(speech.canceled); #expect(controller.closing)
        capture.release?.resume(); await stopping.value
        #expect(!controller.closing)
    }
    @Test func testOpeningHistoryClearsPreviousCaptureSetup() async throws {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        var other = MeetingSession(title: "B", configuration: AIConfiguration()); other.state = .paused; try repo.save(other)
        let controller = MeetingSessionController(repository: repo, credentials: TestCredentials(), factory: { _, _ in TestRecognizer() }, captureFactory: { _ in [(.microphone, TestCapture())] })
        try await controller.start(MeetingSetup(title: "A", configuration: AIConfiguration()))
        await controller.pause(); controller.discardBuffered(); #expect(controller.canResume)
        try controller.open(other); #expect(!controller.canResume)
        await #expect(throws: (any Error).self) { try await controller.resume(processBufferedAudio: false) }
        #expect(controller.meeting?.id == other.id); #expect(!controller.isActive)
    }
    @Test func testOpeningAnotherMeetingCancelsOldTranslationQueue() async throws {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        var a = MeetingSession(title: "A", configuration: AIConfiguration()); a.state = .completed
        var config = AIConfiguration(); config.translationProvider = .openai
        var b = MeetingSession(title: "B", configuration: config); b.state = .completed
        try repo.save(a); try repo.save(b)
        for n in 0..<2 { var item = TranscriptSegment(id: SegmentID(meetingID: a.id, source: .microphone, sequence: n)); item.finalText = "Aの秘密"; try repo.upsert(item) }
        let transport = HeldTranslationTransport()
        let controller = MeetingSessionController(repository: repo, credentials: TestCredentials(), translator: ChatCompletionTranslator(credentials: TestCredentials(), transport: transport))
        try controller.open(a)
        for item in controller.segments { try controller.retryTranslation(item.id) }
        for _ in 0..<100 where transport.requests.isEmpty { await Task.yield() }
        #expect(transport.requests.count == 1)
        try controller.open(b)
        transport.streams.first?.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"译文\"},\"finish_reason\":\"stop\"}]}\n\n".utf8)); transport.streams.first?.finish()
        for _ in 0..<30 { await Task.yield() }
        #expect(transport.requests.count == 1); #expect(controller.segments.isEmpty)
    }
    @Test func testLateResumeFailureCannotPauseNewMeeting() async throws {
        let capture = HangingStartCapture(); var captureNumber = 0
        let controller = MeetingSessionController(repository: try CoreDataMeetingRepository(inMemory: true), credentials: TestCredentials(), factory: { _, _ in TestRecognizer() }, captureFactory: { _ in
            captureNumber += 1
            return [(.microphone, captureNumber == 2 ? capture : TestCapture())]
        })
        try await controller.start(MeetingSetup(title: "A", configuration: AIConfiguration())); await controller.pause()
        let resume = Task { try await controller.resume(processBufferedAudio: false) }
        for _ in 0..<100 where !capture.entered { await Task.yield() }
        #expect(capture.entered); await controller.stop()
        try await controller.start(MeetingSetup(title: "B", configuration: AIConfiguration()))
        let newID = controller.meeting?.id
        capture.release?.resume(); _ = await resume.result
        #expect(controller.meeting?.id == newID); #expect(controller.meeting?.state == .recording)
        await controller.stop()
    }
    @Test func testRetryUsesExplicitNewModelAndPreservesMeetingSnapshot() async throws {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        var config = AIConfiguration(); config.translationProvider = .openai
        var meeting = MeetingSession(title: "retry", configuration: config); meeting.state = .completed; try repo.save(meeting)
        var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)); segment.finalText = "十五万円"; try repo.upsert(segment)
        let transport = HeldTranslationTransport()
        let controller = MeetingSessionController(repository: repo, credentials: TestCredentials(), translator: ChatCompletionTranslator(credentials: TestCredentials(), transport: transport))
        try controller.open(meeting)
        try controller.retryTranslation(segment.id, textModel: "gpt-5.4-mini")
        for _ in 0..<100 where transport.requests.isEmpty { await Task.yield() }
        let request = try #require(transport.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "gpt-5.4-mini"); #expect(request.url?.host == "api.openai.com")
        #expect(body["max_completion_tokens"] as? Int == 2048); #expect(body["max_tokens"] == nil)
        #expect(controller.meeting?.configuration == config)
        #expect(try repo.segments(meetingID: meeting.id).first?.translationModel == "gpt-5.4-mini")
        await controller.stop()
    }
    @Test func testRecoveryRejectsReplacedAudioBeforeConnecting() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PCMCodec.wav(Data(count: 48000)).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let repo = try CoreDataMeetingRepository(inMemory: true)
        var item = MeetingSession(title: "导入", configuration: AIConfiguration()); item.state = .interrupted; item.importOffset = 12000; item.importIdentity = try AudioImportFingerprint.read(url); try repo.save(item)
        let controller = MeetingSessionController(repository: repo, credentials: TestCredentials(), factory: { _, _ in Issue.record("不匹配文件不得连接云端"); return TestRecognizer() })
        try controller.open(item)
        try PCMCodec.wav(Data(repeating: 1, count: 48000)).write(to: url)
        await #expect(throws: (any Error).self) { try await controller.restoreImport(url: url) }
        #expect(controller.meeting?.importOffset == 12000); #expect(!controller.isActive)
    }
}
