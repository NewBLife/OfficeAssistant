import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct MeetingTaskLinkTests {
    @Test func testReceiptAndStaleEditorPreserveTaskAndSource() throws {
        let store = TaskStore(repository: MemoryRepository()); let meetingID = UUID(); let candidateID = UUID()
        let draft = TaskItem(title: "报价")
        let link = TaskMeetingLink(meetingID: meetingID, meetingTitleSnapshot: "会议", candidateID: candidateID)
        let item = try store.acceptMeetingAction(draft, candidateID: candidateID, link: link, at: Date())
        var edited = item; edited.title = "用户校对后的报价"; try store.upsert(edited)
        _ = try store.acceptMeetingAction(draft, candidateID: candidateID, link: link, at: Date())
        #expect(store.items.count == 1); #expect(store.items.first?.title == edited.title)
        try store.unlinkMeeting(taskID: item.id, meetingID: meetingID)
        try store.upsert(edited)
        #expect(store.items.first?.meetingLinks?.isEmpty == true)
        _ = try store.acceptMeetingAction(draft, candidateID: candidateID, link: link, at: Date())
        #expect(store.items.count == 1)
    }
    @Test func testLinkCompletedTaskAndIDCollision() throws {
        let store = TaskStore(repository: MemoryRepository()); let item = TaskItem(title: "完成任务")
        try store.upsert(item); try store.complete(id: item.id, at: Date())
        let link = TaskMeetingLink(meetingID: UUID(), meetingTitleSnapshot: "来源")
        try store.linkMeeting(taskID: item.id, link: link); try store.linkMeeting(taskID: item.id, link: link)
        #expect(store.items.first?.status == .completed); #expect(store.items.first?.meetingLinks?.count == 1)
        let collidingLink = TaskMeetingLink(meetingID: link.meetingID, meetingTitleSnapshot: link.meetingTitleSnapshot, candidateID: item.id)
        #expect(throws: (any Error).self) { try store.acceptMeetingAction(item, candidateID: item.id, link: collidingLink, at: Date()) }
        #expect(store.items.first?.title == item.title)
    }
}
