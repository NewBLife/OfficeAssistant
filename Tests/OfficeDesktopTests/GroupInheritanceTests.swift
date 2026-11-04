import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct GroupInheritanceTests {
    @Test func inheritOverrideAssociateAndRetryKeepUserChoice() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let groups = GroupStore(url: url), a = try groups.create(name: "A"), b = try groups.create(name: "B")
        let repo = try CoreDataMeetingRepository(inMemory: true), store = TaskStore(repository: MemoryRepository(), groups: groups)
        var meeting = MeetingSession(title: "来源", configuration: AIConfiguration()); meeting.groupID = a; try repo.save(meeting)
        var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)); segment.finalText = "发送报价"; try repo.upsert(segment)
        let evidence = EvidenceReference(segmentID: segment.id, revision: 0, quote: segment.text, startUTF16: 0, lengthUTF16: segment.text.utf16.count)
        let candidates = (0..<5).map { ActionCandidate(meetingID: meeting.id, titleZH: "报价\($0)", evidence: [evidence]) }
        try repo.saveCandidates(candidates, meetingID: meeting.id)
        let failing = FailingCandidateRepository(repo); failing.fails = false
        let links = MeetingTaskLinkService(tasks: store, notes: failing, meetings: repo, groups: groups)
        let draft = TaskItem(title: "报价")
        let inherited = try links.accept(candidates[0], editedTask: draft)
        #expect(store.items.first { $0.id == inherited }?.groupID == a)
        let override = try links.accept(candidates[1], editedTask: draft, groupAssignment: .explicit(b))
        #expect(store.items.first { $0.id == override }?.groupID == b)
        let ungrouped = try links.accept(candidates[2], editedTask: draft, groupAssignment: .explicit(nil))
        #expect(store.items.first { $0.id == ungrouped }?.groupID == nil)
        _ = try links.associate(candidate: candidates[3], existingTaskID: override)
        #expect(store.items.first { $0.id == override }?.groupID == b)
        failing.fails = true
        #expect(throws: (any Error).self) { try links.accept(candidates[4], editedTask: draft) }
        let saved = try #require(store.taskForCandidate(meetingID: meeting.id, candidateID: candidates[4].id))
        try store.moveToGroup(id: saved.id, groupID: b)
        failing.fails = false
        #expect(try links.accept(candidates[4], editedTask: draft) == saved.id)
        #expect(store.items.first { $0.id == saved.id }?.groupID == b)
        #expect(store.items.count == 4)
        try groups.delete(id: a)
        #expect(try links.defaultGroupID(meetingID: meeting.id) == nil)
    }
}
