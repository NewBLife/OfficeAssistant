import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct GroupAssignmentTests {
    @Test func completedTasksRepeatsAndDeletedGroupEditors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let groups = GroupStore(url: url), repo = MemoryRepository()
        let a = try groups.create(name: "A"), b = try groups.create(name: "B")
        let store = TaskStore(repository: repo, groups: groups)
        var task = TaskItem(title: "旧编辑器"); task.groupID = a; try store.upsert(task)
        try groups.delete(id: a); try store.upsert(task)
        #expect(store.items.first?.groupID == nil)
        var repeating = TaskItem(title: "重复", dueAt: Date().addingTimeInterval(3600), repeatRule: .daily); repeating.groupID = b
        try store.upsert(repeating); let now = Date(); try store.complete(id: repeating.id, at: now)
        let completed = try #require(store.items.first { $0.id == repeating.id })
        let nextID = try #require(completed.nextOccurrenceID)
        #expect(store.items.first { $0.id == nextID }?.groupID == b)
        try store.moveToGroup(id: nextID, groupID: nil)
        #expect(throws: (any Error).self) { try store.reopen(id: repeating.id) }
        try store.moveToGroup(id: repeating.id, groupID: nil)
        #expect(store.items.first { $0.id == repeating.id }?.status == .completed)
        #expect(store.items.first { $0.id == repeating.id }?.completedAt == now)
        let reopened = TaskStore(repository: repo, groups: groups)
        #expect(reopened.items == store.items)
    }
    @Test func assignmentsSurviveDatabaseReopenAndGroupDeletionKeepsContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let groups = GroupStore(url: directory.appendingPathComponent("groups.json"))
        let parent = try groups.create(name: "客户"), child = try groups.create(name: "项目", parentID: parent)
        var task = TaskItem(title: "保留的待办"); task.groupID = child
        var meeting = MeetingSession(title: "保留的会议", configuration: AIConfiguration()); meeting.groupID = child
        let taskURL = directory.appendingPathComponent("tasks.store"), meetingURL = directory.appendingPathComponent("meetings.store")
        do {
            try CoreDataTaskRepository(url: taskURL).save([task])
            try CoreDataMeetingRepository(url: meetingURL).save(meeting)
        }
        let taskRepo = try CoreDataTaskRepository(url: taskURL), meetingRepo = try CoreDataMeetingRepository(url: meetingURL)
        #expect(try taskRepo.load() == [task])
        #expect(try meetingRepo.list() == [meeting])
        try groups.delete(id: parent)
        #expect(groups.groups.isEmpty)
        #expect(try taskRepo.load() == [task])
        #expect(try meetingRepo.list() == [meeting])
        #expect(GroupContentFilter.tasks(try taskRepo.load(), scope: .ungrouped, groups: groups.groups, search: "", status: nil).map(\.id) == [task.id])
        #expect(GroupContentFilter.meetings(try meetingRepo.list(), scope: .ungrouped, groups: groups.groups, search: "").map(\.id) == [meeting.id])
    }
    @Test func brokenGroupFileDoesNotDestroyTaskMembership() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let groups = GroupStore(url: url), id = try groups.create(name: "客户")
        let store = TaskStore(repository: MemoryRepository(), groups: groups)
        var task = TaskItem(title: "待办"); task.groupID = id; try store.upsert(task)
        let bad = Data("damaged".utf8); try bad.write(to: url)
        #expect(throws: (any Error).self) { try groups.reload() }
        try store.snooze(id: task.id, until: Date().addingTimeInterval(600))
        try store.complete(id: task.id, at: Date())
        #expect(store.items.first?.groupID == id)
        #expect(throws: (any Error).self) { try store.moveToGroup(id: task.id, groupID: nil) }
        #expect(try Data(contentsOf: url) == bad)
    }
    @Test func meetingMovesPersistWithoutChangingEvidenceOrFingerprint() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let groups = GroupStore(url: url), group = try groups.create(name: "客户")
        let repo = try CoreDataMeetingRepository(inMemory: true)
        let speech = TestRecognizer()
        let controller = MeetingSessionController(repository: repo, credentials: TestCredentials(), groups: groups, factory: { _, _ in speech }, captureFactory: { _ in [(.microphone, TestCapture())] })
        var setup = MeetingSetup(title: "会议", configuration: AIConfiguration()); setup.groupID = group
        try await controller.start(setup)
        let id = try #require(controller.meeting?.id)
        #expect(controller.meeting?.groupID == group)
        #expect(throws: (any Error).self) { try controller.moveToGroup(id: id, groupID: nil) }
        await controller.stop()
        let old = try #require(controller.meeting)
        let fingerprint = MinutesSnapshot(meeting: old, segments: []).fingerprint
        try controller.moveToGroup(id: id, groupID: nil)
        #expect(controller.meeting?.groupID == nil)
        #expect(controller.meeting?.state == old.state)
        #expect(MinutesSnapshot(meeting: try #require(controller.meeting), segments: []).fingerprint == fingerprint)
        #expect(try repo.list().first?.groupID == nil)
    }
}
