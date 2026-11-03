import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct MinutesPersistenceTests {
    @Test func testMinutesRoundTripAfterReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meetings.store")
        let meeting = MeetingSession(title: "会議", configuration: AIConfiguration())
        let options = MinutesOptions(provider: .openai, model: "gpt-5.4-mini")
        var doc = MinutesDocument(meetingID: meeting.id, meetingTitle: meeting.title, options: options)
        doc.overviewZH = "讨论报价"; doc.overviewJA = "見積もりについて"; doc.revision = 1
        let evidence = EvidenceReference(segmentID: SegmentID(meetingID: meeting.id, source: .file, sequence: 0), revision: 1, quote: "报价", startUTF16: 0, lengthUTF16: 2)
        let candidate = ActionCandidate(meetingID: meeting.id, titleZH: "发送报价", evidence: [evidence])
        do { let repo = try CoreDataMeetingRepository(url: url); try repo.save(meeting); try repo.save(document: doc, candidates: [candidate]) }
        let reopened = try CoreDataMeetingRepository(url: url)
        #expect(try reopened.documents(meetingID: meeting.id) == [doc])
        #expect(try reopened.candidates(meetingID: meeting.id) == [candidate])
        #expect(try reopened.list() == [meeting])
    }
    @Test func testVersionSaveIsAtomicAndImmutable() throws {
        let repo = try CoreDataMeetingRepository(inMemory: true)
        let meeting = MeetingSession(title: "测试", configuration: AIConfiguration()); try repo.save(meeting)
        var doc = MinutesDocument(meetingID: meeting.id, meetingTitle: meeting.title, options: MinutesOptions())
        try repo.save(document: doc, candidates: [])
        doc.overviewZH = "不得覆盖旧版本"
        #expect(throws: (any Error).self) { try repo.save(document: doc, candidates: []) }
        #expect(try repo.documents(meetingID: meeting.id).first?.overviewZH == "")
        var next = doc; next.id = UUID()
        let wrong = ActionCandidate(meetingID: UUID(), titleZH: "错误会议", evidence: [])
        #expect(throws: (any Error).self) { try repo.save(document: next, candidates: [wrong]) }
        #expect(try repo.documents(meetingID: meeting.id).count == 1)
    }
}
