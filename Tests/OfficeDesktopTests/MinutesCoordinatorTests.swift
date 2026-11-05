import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor final class FakeMinutesGenerator: MinutesGenerating {
    var held = false; var started = false; var release: CheckedContinuation<Void, Never>?
    var inputs: [MinutesSnapshot] = []; var candidates: [ActionCandidate] = []
    func generate(snapshot: MinutesSnapshot, options: MinutesOptions) async throws -> MinutesGenerationResult {
        started = true
        inputs.append(snapshot)
        if held { await withCheckedContinuation { release = $0 } }
        var document = MinutesDocument(meetingID: snapshot.meeting.id, meetingTitle: snapshot.meeting.title, options: options)
        document.overviewZH = "测试纪要"; document.sourceFingerprint = snapshot.fingerprint
        return MinutesGenerationResult(document: document, candidates: candidates)
    }
}
@MainActor @Suite struct MinutesCoordinatorTests {
    func data() throws -> (CoreDataMeetingRepository, MeetingSession, TranscriptSegment) {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        var meeting = MeetingSession(title: "无翻译会议", configuration: AIConfiguration()); meeting.configuration.translationEnabled = false; meeting.state = .completed; try repo.save(meeting)
        var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)); segment.finalText = "讨论报价"; try repo.upsert(segment)
        return (repo, meeting, segment)
    }
    @Test func testOnlyTranscriptionCanGenerateAndRestartJobDoesNotRun() async throws {
        let (repo, meeting, _) = try data(); let fake = FakeMinutesGenerator()
        var job = MinutesJobRecord(meetingID: meeting.id, options: MinutesOptions(), sourceFingerprint: "old"); job.status = .running; try repo.saveJob(job)
        let service = MinutesCoordinator(meetings: repo, notes: repo, generator: fake)
        #expect(try repo.jobs(meetingID: meeting.id).first?.status == .interrupted); #expect(!fake.started)
        try await service.generate(meetingID: meeting.id, options: MinutesOptions())
        #expect(try repo.documents(meetingID: meeting.id).count == 1)
    }
    @Test func testEditedSourceRejectsLateResult() async throws {
        let (repo, meeting, segment) = try data(); let fake = FakeMinutesGenerator(); fake.held = true
        let service = MinutesCoordinator(meetings: repo, notes: repo, generator: fake)
        let operation = Task { try await service.generate(meetingID: meeting.id, options: MinutesOptions()) }
        for _ in 0..<100 where !fake.started { await Task.yield() }
        var edited = segment; edited.revision += 1; edited.finalText = "用户已改原文"; try repo.upsert(edited)
        fake.release?.resume(); let result = await operation.result
        if case .success = result { Issue.record("旧原文的结果不能提交") }
        #expect(try repo.documents(meetingID: meeting.id).isEmpty)
        #expect(try repo.jobs(meetingID: meeting.id).first?.status == .stale)
    }
    @Test func testRenamingMeetingDoesNotMarkMinutesStaleButTranscriptEditsDo() async throws {
        let (repo, meeting, segment) = try data(); let service = MinutesCoordinator(meetings: repo, notes: repo, generator: FakeMinutesGenerator())
        try await service.generate(meetingID: meeting.id, options: MinutesOptions())
        let document = try #require(repo.documents(meetingID: meeting.id).first)
        let controller = MeetingSessionController(repository: repo, credentials: TestCredentials())
        try controller.open(meeting)
        try controller.rename(meeting.id, title: "更新后的会议名称")
        #expect(!service.isStale(document))
        var edited = segment; edited.revision += 1; edited.finalText = "修改后的原文"; try repo.upsert(edited)
        #expect(service.isStale(document))
    }
}

extension MinutesCoordinatorTests {
    @Test func testCancelLateResultAndPreserveEditedHistory() async throws {
        let (repo, meeting, _) = try data(); let fake = FakeMinutesGenerator()
        let service = MinutesCoordinator(meetings: repo, notes: repo, generator: fake)
        try await service.generate(meetingID: meeting.id, options: MinutesOptions())
        var first = try #require(repo.documents(meetingID: meeting.id).first)
        first.overviewZH = "人工修改"; try service.saveEdit(first)
        let history = try repo.documents(meetingID: meeting.id)
        #expect(history.count == 2); #expect(history[0].overviewZH == "人工修改")
        fake.held = true; fake.started = false
        let operation = Task { try await service.generate(meetingID: meeting.id, options: MinutesOptions()) }
        for _ in 0..<100 where !fake.started { await Task.yield() }
        service.cancel(meetingID: meeting.id); fake.release?.resume()
        _ = await operation.result
        #expect(try repo.documents(meetingID: meeting.id) == history)
        #expect(try repo.jobs(meetingID: meeting.id).first?.status == .cancelled)
        fake.held = false
        try await service.generate(meetingID: meeting.id, options: MinutesOptions())
        #expect(try repo.documents(meetingID: meeting.id).count == 3)
        #expect(try repo.documents(meetingID: meeting.id).contains { $0.id == history[0].id && $0.overviewZH == "人工修改" })
    }
    @Test func testIncrementalThresholdAppendAndStopBarrier() async throws {
        let (repo, meeting, _) = try data(); let fake = FakeMinutesGenerator(); fake.held = true
        let service = MinutesCoordinator(meetings: repo, notes: repo, generator: fake, isRecording: { _ in true })
        let options = MinutesOptions()
        service.setIncrementalExtraction(true, meetingID: meeting.id, options: options)
        for i in 1...4 {
            var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: i)); segment.finalText = "新增\(i)"; try repo.upsert(segment)
            service.noticeFinal(meetingID: meeting.id)
        }
        await Task.yield(); #expect(!fake.started)
        var fifth = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 5)); fifth.finalText = "第五段"; try repo.upsert(fifth)
        service.noticeFinal(meetingID: meeting.id)
        for _ in 0..<100 where !fake.started { await Task.yield() }
        #expect(fake.started)
        var appended = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 6)); appended.finalText = "请求期间追加"; try repo.upsert(appended)
        fake.release?.resume()
        for _ in 0..<100 where service.isRunning { await Task.yield() }
        #expect(service.currentJob?.status == .completed)
        #expect(try repo.documents(meetingID: meeting.id).isEmpty)
        #expect(try repo.candidates(meetingID: meeting.id).isEmpty)
        fake.started = false
        for i in 7...11 { var segment = appended; segment.id = SegmentID(meetingID: meeting.id, source: .file, sequence: i); try repo.upsert(segment) }
        service.noticeFinal(meetingID: meeting.id); await Task.yield()
        #expect(!fake.started) // 60-second interval defers the next batch.
        service.recordingStopped(meetingID: meeting.id)
        #expect(!service.incrementalEnabled(meetingID: meeting.id))
        // A queued task disabled before it starts must never upload.
        let other = MinutesCoordinator(meetings: repo, notes: repo, generator: fake, isRecording: { _ in true })
        other.setIncrementalExtraction(true, meetingID: meeting.id, options: options)
        for i in 12...16 { var segment = appended; segment.id = SegmentID(meetingID: meeting.id, source: .file, sequence: i); try repo.upsert(segment) }
        other.noticeFinal(meetingID: meeting.id)
        other.setIncrementalExtraction(false, meetingID: meeting.id, options: options)
        for _ in 0..<20 { await Task.yield() }
        #expect(!fake.started)
    }
}

extension MinutesCoordinatorTests {
    @Test func testRegenerationRemovesCancelledProposalButKeepsAccepted() async throws {
        let (repo, meeting, segment) = try data(); let fake = FakeMinutesGenerator()
        let ref = EvidenceReference(segmentID: segment.id, revision: segment.revision, quote: segment.text, startUTF16: 0, lengthUTF16: segment.text.utf16.count)
        let cancelled = ActionCandidate(meetingID: meeting.id, titleZH: "后续取消", evidence: [ref])
        var accepted = ActionCandidate(meetingID: meeting.id, titleZH: "已加入事项", evidence: [ref]); accepted.reviewState = .accepted; accepted.acceptedTaskID = UUID()
        try repo.saveCandidates([cancelled, accepted], meetingID: meeting.id)
        let service = MinutesCoordinator(meetings: repo, notes: repo, generator: fake)
        try await service.generate(meetingID: meeting.id, options: MinutesOptions())
        #expect(try repo.candidates(meetingID: meeting.id) == [accepted])
    }
    @Test func testIncrementalIncludesLateFinalBeforeOldSourceTime() async throws {
        let (repo, meeting, old) = try data(); var edited = old; edited.sourceStartSeconds = 100; try repo.upsert(edited)
        let fake = FakeMinutesGenerator()
        let service = MinutesCoordinator(meetings: repo, notes: repo, generator: fake, isRecording: { _ in true })
        service.setIncrementalExtraction(true, meetingID: meeting.id, options: MinutesOptions())
        for (i, offset) in [50.0, 110, 120, 130, 140].enumerated() {
            var next = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .microphone, sequence: i)); next.finalText = "新片段\(i)"; next.sourceStartSeconds = offset; try repo.upsert(next)
        }
        service.noticeFinal(meetingID: meeting.id)
        for _ in 0..<100 where fake.inputs.isEmpty { await Task.yield() }
        let submitted = try #require(fake.inputs.first)
        #expect(submitted.segments.count == 5)
        #expect(submitted.segments.contains { $0.sourceStartSeconds == 50 })
        #expect(!submitted.segments.contains { $0.id == edited.id })
        for _ in 0..<100 where service.isRunning { await Task.yield() }
        service.recordingStopped(meetingID: meeting.id)
    }
}
