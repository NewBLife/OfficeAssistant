import Foundation
import CoreData
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct PersistenceTests {
    @Test func testRoundTripAfterReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.store")
        let item = TaskItem(title: "保留这条任务", notes: "记录负责人", owner: "小王", dueAt: Date())
        do { let repo = try CoreDataTaskRepository(url: url); try repo.save([item]) }
        let reopened = try CoreDataTaskRepository(url: url)
        #expect(try reopened.load() == [item])
    }
    @Test(arguments: [0, 99]) func testCorruptOrUnknownSchemaPreserved(version: Int) throws {
        let repo = try CoreDataTaskRepository(inMemory: true)
        _ = TaskRecord(context: repo.context, id: UUID(), schemaVersion: version == 0 ? 1 : version, payload: Data("invalid".utf8))
        try repo.context.save()
        #expect(throws: (any Error).self) { try repo.load() }
        #expect(try repo.context.fetch(NSFetchRequest<TaskRecord>(entityName: "TaskRecord")).count == 1)
    }
    @Test func testPreferencesPersistAndDefaults() throws {
        let name = "OfficeTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PreferencesStore(defaults: defaults)
        #expect(store.value.summaryHour == 9)
        #expect(store.value.timeZoneID == "Asia/Shanghai")
        var prefs = store.value; prefs.displayName = "田中"; prefs.summaryHour = 8
        try store.save(prefs)
        store.setInterfaceLanguage(.japanese)
        let reopened = PreferencesStore(defaults: defaults)
        #expect(reopened.value == prefs)
        #expect(reopened.interfaceLanguage == .japanese)
        #expect(reopened.interfaceLanguage.locale.identifier == "ja")
    }
}

@MainActor final class MemoryRepository: TaskRepository {
    var values: [TaskItem] = []; var failSave = false
    func load() throws -> [TaskItem] { values }
    func save(_ items: [TaskItem]) throws {
        if failSave { throw OfficeError.invalid("模拟磁盘失败") }; values = items
    }
}
@MainActor @Suite struct TaskStoreTests {
    @Test func testStaleEditorPreservesNewSnooze() throws {
        let store = TaskStore(repository: MemoryRepository())
        let item = TaskItem(title: "报价", dueAt: Date().addingTimeInterval(60))
        try store.upsert(item)
        var draft = item; draft.title = "新报价标题"
        let snoozedUntil = Date().addingTimeInterval(600)
        try store.snooze(id: item.id, until: snoozedUntil)
        try store.upsert(draft)
        #expect(store.items.first?.snoozedUntil == snoozedUntil)
    }
    @Test func testFailedSaveLeavesSnapshotUnchanged() throws {
        let repo = MemoryRepository(); let store = TaskStore(repository: repo); try store.reload()
        let item = TaskItem(title: "旧任务"); try store.upsert(item)
        repo.failSave = true
        #expect(throws: (any Error).self) { try store.delete(id: item.id) }
        #expect(store.items == [item])
    }
    @Test func testDuplicateCompletionCreatesOneNextOccurrence() throws {
        let repo = MemoryRepository(); let store = TaskStore(repository: repo)
        let item = TaskItem(title: "日报", dueAt: Date(), repeatRule: .daily)
        try store.upsert(item); try store.complete(id: item.id, at: Date()); try store.complete(id: item.id, at: Date())
        #expect(store.items.count == 2)
        #expect(store.items.filter { $0.status != .completed }.count == 1)
    }
    @Test func testReopenUnmodifiedNext() throws {
        let store = TaskStore(repository: MemoryRepository())
        let item = TaskItem(title: "日报", dueAt: Date(), repeatRule: .daily)
        try store.upsert(item); try store.complete(id: item.id, at: Date()); try store.reopen(id: item.id)
        #expect(store.items.count == 1); #expect(store.items.first?.status == .pending)
    }
    @Test func testReopenEditedNextRejected() throws {
        let store = TaskStore(repository: MemoryRepository())
        let item = TaskItem(title: "日报", dueAt: Date(), repeatRule: .daily)
        try store.upsert(item); try store.complete(id: item.id, at: Date())
        var next = store.items.first { $0.status == .pending }!; next.title = "已经改过"
        try store.upsert(next)
        #expect(throws: (any Error).self) { try store.reopen(id: item.id) }
        #expect(store.items.count == 2)
    }
    @Test func testReplayedSnoozeOnCompletedTaskIgnored() throws {
        let store = TaskStore(repository: MemoryRepository()); let item = TaskItem(title: "提交")
        try store.upsert(item); try store.complete(id: item.id, at: Date())
        try store.snooze(id: item.id, until: Date().addingTimeInterval(600))
        #expect(store.items.first?.snoozedUntil == nil)
    }
}
