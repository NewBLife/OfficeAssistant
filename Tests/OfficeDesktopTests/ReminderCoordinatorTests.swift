import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor final class FakeNotifications: NotificationClient {
    var auth: NotificationAuthorization = .authorized
    var requests: [String: ReminderRequest] = [:]
    var pauseNextAdd = false
    var failPausedAdd = false
    var addCount = 0
    var delivered: Set<String> = []
    var continuation: CheckedContinuation<Void, Never>?
    func authorization() async -> NotificationAuthorization { auth }
    func requestAuthorization() async throws -> Bool { auth == .authorized }
    func pendingIDs() async -> Set<String> { Set(requests.keys) }
    func deliveredIDs() async -> Set<String> { delivered }
    func remove(ids: [String]) { for id in ids { requests.removeValue(forKey: id); delivered.remove(id) } }
    func add(_ request: ReminderRequest) async throws {
        if pauseNextAdd {
            pauseNextAdd = false
            await withCheckedContinuation { continuation = $0 }
            if failPausedAdd { throw OfficeError.invalid("模拟请求失败") }
        }
        addCount += 1
        requests[request.id] = request
    }
}
@MainActor @Suite struct ReminderCoordinatorTests {
    @Test func testOldGenerationErrorDoesNotAbandonLatest() async throws {
        let client = FakeNotifications()
        let coordinator = ReminderCoordinator(client: client)
        var prefs = AppPreferences(); prefs.dailySummaryEnabled = false
        let item = TaskItem(title: "任务", dueAt: Date().addingTimeInterval(120))
        try await coordinator.reconcile(tasks: [item], preferences: prefs, now: Date())
        client.pauseNextAdd = true; client.failPausedAdd = true
        var edited = item; edited.title = "修改标题"
        let old = Task { try await coordinator.reconcile(tasks: [edited], preferences: prefs, now: Date()) }
        while client.continuation == nil { await Task.yield() }
        try await coordinator.reconcile(tasks: [], preferences: prefs, now: Date())
        client.continuation?.resume()
        try await old.value
        #expect(client.requests.isEmpty)
    }
    @Test func testDeliveredOverdueNotificationSurvivesRefresh() async throws {
        let client = FakeNotifications(); let coordinator = ReminderCoordinator(client: client)
        var prefs = AppPreferences(); prefs.dailySummaryEnabled = false
        let now = Date(); let item = TaskItem(title: "任务", dueAt: now.addingTimeInterval(60))
        let id = "office.task.\(item.id.uuidString)"
        try await coordinator.reconcile(tasks: [item], preferences: prefs, now: now)
        client.requests.removeValue(forKey: id); client.delivered.insert(id)
        try await coordinator.reconcile(tasks: [item], preferences: prefs, now: now.addingTimeInterval(90))
        #expect(client.delivered.contains(id))
        var done = item; done.status = .completed
        try await coordinator.reconcile(tasks: [done], preferences: prefs, now: now.addingTimeInterval(100))
        #expect(!client.delivered.contains(id))
    }
    @Test func testUnchangedPlanIsNotRescheduled() async throws {
        let client = FakeNotifications(); let coordinator = ReminderCoordinator(client: client)
        let item = TaskItem(title: "任务", dueAt: Date().addingTimeInterval(120))
        try await coordinator.reconcile(tasks: [item], preferences: AppPreferences(), now: Date())
        let count = client.addCount
        try await coordinator.reconcile(tasks: [item], preferences: AppPreferences(), now: Date())
        #expect(client.addCount == count)
    }
    @Test func testChangingOverdueDeadlineClearsOldDeliveredNotification() async throws {
        let client = FakeNotifications(); let coordinator = ReminderCoordinator(client: client)
        var prefs = AppPreferences(); prefs.dailySummaryEnabled = false
        let now = Date(); var item = TaskItem(title: "任务", dueAt: now.addingTimeInterval(60))
        let id = "office.task.\(item.id.uuidString)"
        try await coordinator.reconcile(tasks: [item], preferences: prefs, now: now)
        client.requests.removeValue(forKey: id); client.delivered.insert(id)
        try await coordinator.reconcile(tasks: [item], preferences: prefs, now: now.addingTimeInterval(90))
        item.dueAt = now.addingTimeInterval(30)
        try await coordinator.reconcile(tasks: [item], preferences: prefs, now: now.addingTimeInterval(100))
        #expect(!client.delivered.contains(id))
    }
    @Test func testEditCancelsOldRequest() async throws {
        let client = FakeNotifications(); let coordinator = ReminderCoordinator(client: client)
        var item = TaskItem(title: "报价", dueAt: Date().addingTimeInterval(60))
        try await coordinator.reconcile(tasks: [item], preferences: AppPreferences(), now: Date())
        item.status = .completed
        try await coordinator.reconcile(tasks: [item], preferences: AppPreferences(), now: Date())
        #expect(client.requests["office.task.\(item.id.uuidString)"] == nil)
    }
    @Test func testDeniedDoesNotMutateTasks() async throws {
        let client = FakeNotifications(); client.auth = .denied
        let item = TaskItem(title: "任务", dueAt: Date().addingTimeInterval(60))
        try await ReminderCoordinator(client: client).reconcile(tasks: [item], preferences: AppPreferences(), now: Date())
        #expect(client.requests.isEmpty); #expect(item.status == .pending)
    }
    @Test func testLatestReconcileWins() async throws {
        let client = FakeNotifications(); client.pauseNextAdd = true
        let coordinator = ReminderCoordinator(client: client)
        var prefs = AppPreferences(); prefs.dailySummaryEnabled = false
        let item = TaskItem(title: "任务", dueAt: Date().addingTimeInterval(60))
        let first = Task { try await coordinator.reconcile(tasks: [item], preferences: prefs, now: Date()) }
        while client.continuation == nil { await Task.yield() }
        var done = item; done.status = .completed
        try await coordinator.reconcile(tasks: [done], preferences: prefs, now: Date())
        client.continuation?.resume(); try await first.value
        #expect(client.requests.isEmpty)
    }
    @Test func testOtherApplicationsRequestsPreserved() async throws {
        let client = FakeNotifications()
        client.requests["unrelated"] = ReminderRequest(id: "unrelated", taskID: nil, title: "", body: "", trigger: .once(Date()))
        try await ReminderCoordinator(client: client).reconcile(tasks: [], preferences: AppPreferences(), now: Date())
        #expect(client.requests["unrelated"] != nil)
    }
}
