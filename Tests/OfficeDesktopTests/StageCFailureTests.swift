import Foundation
import Testing
import CoreData
import OfficeCore
@testable import OfficeDesktop

@MainActor final class FailingCandidateRepository: MinutesRepository {
    let base: CoreDataMeetingRepository; var fails = true
    init(_ base: CoreDataMeetingRepository) { self.base = base }
    func documents(meetingID: UUID) throws -> [MinutesDocument] { try base.documents(meetingID: meetingID) }
    func candidates(meetingID: UUID) throws -> [ActionCandidate] { try base.candidates(meetingID: meetingID) }
    func save(document: MinutesDocument, candidates: [ActionCandidate]) throws { try base.save(document: document, candidates: candidates) }
    func saveCandidates(_ candidates: [ActionCandidate], meetingID: UUID) throws { if fails { throw OfficeError.invalid("模拟第二次保存失败") }; try base.saveCandidates(candidates, meetingID: meetingID) }
    func jobs(meetingID: UUID?) throws -> [MinutesJobRecord] { try base.jobs(meetingID: meetingID) }
    func saveJob(_ job: MinutesJobRecord) throws { try base.saveJob(job) }
}
@MainActor @Suite struct StageCFailureTests {
    @Test func testReceiptPreventsDuplicateAfterMeetingSaveFailure() throws {
        let repo = try CoreDataMeetingRepository(inMemory: true); let store = TaskStore(repository: MemoryRepository())
        let meeting = MeetingSession(title: "关联", configuration: AIConfiguration()); try repo.save(meeting)
        var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)); segment.finalText = "张三发送报价"; try repo.upsert(segment)
        let ref = EvidenceReference(segmentID: segment.id, revision: 0, quote: segment.text, startUTF16: 0, lengthUTF16: segment.text.utf16.count)
        let candidate = ActionCandidate(meetingID: meeting.id, titleZH: "发送报价", evidence: [ref]); try repo.saveCandidates([candidate], meetingID: meeting.id)
        let failing = FailingCandidateRepository(repo); let links = MeetingTaskLinkService(tasks: store, notes: failing, meetings: repo)
        #expect(throws: (any Error).self) { try links.accept(candidate, editedTask: TaskItem(title: candidate.titleZH)) }
        #expect(store.items.count == 1)
        var edited = store.items[0]; edited.title = "用户修改的任务"; try store.upsert(edited)
        failing.fails = false
        _ = try links.accept(candidate, editedTask: TaskItem(title: "不能覆盖"))
        #expect(store.items.count == 1); #expect(store.items[0].title == edited.title)
        #expect(try repo.candidates(meetingID: meeting.id).first?.reviewState == .accepted)
    }
    @Test func testUnknownMinutesSchemaKeepsOriginalMeeting() throws {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        let meeting = MeetingSession(title: "保留", configuration: AIConfiguration()); try repo.save(meeting)
        let record = MeetingBlob(entity: NSEntityDescription.entity(forEntityName: "MeetingBlob", in: repo.context)!, insertInto: repo.context)
        record.key = "n.\(meeting.id).\(UUID())"; record.version = 99; record.payload = Data("{}".utf8); try repo.context.save()
        #expect(throws: (any Error).self) { try repo.documents(meetingID: meeting.id) }
        #expect(try repo.list() == [meeting])
    }
    @Test func testLegacyTaskAndRepeatKeepSources() throws {
        let item = TaskItem(title: "旧待办")
        let decoded = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.meetingLinks == nil); #expect(decoded.meetingActionReceipts == nil)
        var repeating = TaskItem(title: "周期", dueAt: Date().addingTimeInterval(-3600), repeatRule: .daily)
        repeating.meetingLinks = [TaskMeetingLink(meetingID: UUID(), meetingTitleSnapshot: "会议")]
        repeating.meetingActionReceipts = [MeetingActionReceipt(meetingID: repeating.meetingLinks![0].meetingID, candidateID: UUID(), joinedAt: Date())]
        let next = try #require(TaskRules.complete(repeating, at: Date()).next)
        #expect(next.meetingLinks == repeating.meetingLinks); #expect(next.meetingActionReceipts == repeating.meetingActionReceipts)
    }
}
@MainActor struct FakeMinutesDestination: MinutesSaveDestinationChoosing {
    var url: URL?
    func choose(suggestedName: String, format: MinutesExportFormat) async throws -> URL? { url }
}
@MainActor @Suite struct MinutesFileExportTests {
    @Test func testUTF8CancelAndWriteFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("minutes.txt"); let text = "纪要\n見積もり15万日元"
        _ = try await MinutesFileExporter(destination: FakeMinutesDestination(url: url)).export(text: text, suggestedName: "../../测试", format: .plainText)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        let cancelled = try await MinutesFileExporter(destination: FakeMinutesDestination(url: nil)).export(text: "不写入", suggestedName: "取消", format: .plainText)
        #expect(cancelled == nil)
        do { _ = try await MinutesFileExporter(destination: FakeMinutesDestination(url: url.appendingPathComponent("child"))).export(text: "失败", suggestedName: "失败", format: .markdown); Issue.record("应写入失败") } catch {}
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }
}

extension StageCFailureTests {
    @Test func testCrossChunkReviewCannotBeAcceptedBeforeConfirmation() throws {
        let repo = try CoreDataMeetingRepository(inMemory: true); let store = TaskStore(repository: MemoryRepository())
        let meeting = MeetingSession(title: "分段核对", configuration: AIConfiguration()); try repo.save(meeting)
        var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)); segment.finalText = "发送报价"; try repo.upsert(segment)
        let ref = EvidenceReference(segmentID: segment.id, revision: 0, quote: segment.text, startUTF16: 0, lengthUTF16: segment.text.utf16.count)
        var candidate = ActionCandidate(meetingID: meeting.id, titleZH: "发送报价", evidence: [ref]); candidate.clarifications = [.crossChunkReview]
        try repo.saveCandidates([candidate], meetingID: meeting.id)
        let service = MeetingTaskLinkService(tasks: store, notes: repo, meetings: repo)
        #expect(throws: (any Error).self) { try service.accept(candidate, editedTask: TaskItem(title: candidate.titleZH)) }
        #expect(store.items.isEmpty)
    }
}
