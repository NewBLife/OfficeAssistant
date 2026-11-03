import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor final class TestCapture: AudioCapture {
    let pair = AsyncThrowingStream<PCMFrame, Error>.makeStream()
    var stopped = false
    func start() async throws -> AsyncThrowingStream<PCMFrame, Error> { pair.stream }
    func stop() async { stopped = true; pair.continuation.finish() }
}
@MainActor final class TestRecognizer: SpeechRecognizer {
    var onEvent: ((TranscriptEvent) -> Void)?; var onFailure: ((Error) -> Void)?; var onRemoteTask: ((RemoteTask) throws -> Void)?
    var appends = 0; var canceled = false
    func start(_ context: RecognitionContext) async throws {}
    func append(_ frame: PCMFrame) async throws { if !canceled { appends += 1 } }
    func commit(_ utterance: AudioUtterance) async throws {}
    func stopSending() { canceled = true }
    func cancel() async { stopSending() }
}
@MainActor @Suite struct MeetingSessionTests {
    func harness() throws -> (MeetingSessionController, TestCapture, TestRecognizer) {
        let capture = TestCapture(); let speech = TestRecognizer()
        let service = MeetingSessionController(repository: try CoreDataMeetingRepository(inMemory: true), credentials: TestCredentials(), translator: ChatCompletionTranslator(credentials: TestCredentials(), transport: TestTransport()), factory: { _, _ in speech }, captureFactory: { _ in [(.microphone, capture)] })
        return (service, capture, speech)
    }
    @Test func testPauseStopsCaptureAndRejectsLateCallbacks() async throws {
        let (service, capture, speech) = try harness()
        try await service.start(MeetingSetup(title: "测试", configuration: AIConfiguration()))
        let callback = speech.onEvent!; let id = SegmentID(meetingID: service.meeting!.id, source: .microphone, sequence: 0)
        await service.pause(); callback(TranscriptEvent(id: id, kind: .final, text: "迟到内容"))
        #expect(capture.stopped); #expect(speech.canceled); #expect(service.segments.isEmpty)
        #expect(service.meeting?.state == .paused)
    }
    @Test func testStopAndInterruptAreUploadBarriers() async throws {
        let (service, capture, speech) = try harness()
        try await service.start(MeetingSetup(title: "测试", configuration: AIConfiguration()))
        await service.stop()
        #expect(capture.stopped && speech.canceled); #expect(service.meeting?.state == .completed)
    }
    @Test func testLongSilenceDoesNotUploadOrPause() async throws {
        let (service, capture, speech) = try harness()
        try await service.start(MeetingSetup(title: "测试", configuration: AIConfiguration()))
        for n in 0..<65 {
            capture.pair.continuation.yield(PCMFrame(source: .microphone, sequence: n, startSeconds: Double(n), samples: Data(count: 48000)))
            await Task.yield()
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(speech.appends == 0); #expect(service.meeting?.state == .recording)
        await service.stop()
    }
    @Test func testFinalTranscriptSavedBeforeTranslation() async throws {
        let (service, _, speech) = try harness()
        try await service.start(MeetingSetup(title: "测试", configuration: AIConfiguration()))
        let id = SegmentID(meetingID: service.meeting!.id, source: .microphone, sequence: 0)
        speech.onEvent?(TranscriptEvent(id: id, kind: .final, text: "会議"))
        #expect(service.segments.first?.finalText == "会議")
        await service.stop()
    }
}
