import Foundation
import Testing
@testable import OfficeCore

struct ReminderPlannerTests {
    let now = date("2026-11-03T09:00:00+08:00")
    @Test func testCompletedAndUndatedTasksNotScheduled() {
        var done = task("2026-11-03T10:00:00+08:00"); done.status = .completed
        let plan = ReminderPlanner.plan(tasks: [task(), done], preferences: AppPreferences(), now: now)
        #expect(plan.requests.count == 1)
        #expect(plan.requests.first?.id == "office.summary")
    }
    @Test func testPastDueListedButNotBurstScheduled() {
        let late = task("2026-11-02T09:00:00+08:00")
        let plan = ReminderPlanner.plan(tasks: [late], preferences: AppPreferences(), now: now)
        #expect(plan.overdueTaskIDs == [late.id])
        #expect(plan.requests.allSatisfy { $0.taskID == nil })
    }
    @Test func testDailySummaryDefaultsToNineShanghai() {
        let plan = ReminderPlanner.plan(tasks: [], preferences: AppPreferences(), now: now)
        #expect(plan.requests.first?.trigger == .daily(hour: 9, minute: 0, timeZoneID: "Asia/Shanghai"))
    }
    @Test func testNearestFortyEightPlusOneSummary() {
        let items = (1...80).reversed().map { TaskItem(title: "事项\($0)", dueAt: now.addingTimeInterval(Double($0 * 60))) }
        let plan = ReminderPlanner.plan(tasks: items, preferences: AppPreferences(), now: now)
        #expect(plan.requests.count == 49)
        #expect(plan.requests.filter { $0.taskID != nil }.last?.trigger == .once(now.addingTimeInterval(48 * 60)))
    }
    @Test func testSnoozeTenMinutes() {
        var item = task("2026-11-02T09:00:00+08:00"); item.snoozedUntil = now.addingTimeInterval(600)
        let plan = ReminderPlanner.plan(tasks: [item], preferences: AppPreferences(), now: now)
        #expect(plan.requests.first { $0.taskID == item.id }?.trigger == .once(now.addingTimeInterval(600)))
        #expect(plan.overdueTaskIDs.isEmpty)
    }
}
