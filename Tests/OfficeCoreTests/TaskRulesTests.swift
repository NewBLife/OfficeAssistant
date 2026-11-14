import Testing
import Foundation
@testable import OfficeCore

func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
func task(_ due: String? = nil, rule: RepeatRule = .none) -> TaskItem {
    TaskItem(title: "提交周报", dueAt: due.map(date), repeatRule: rule)
}

struct TaskRulesTests {
    @Test func testWeekdaysFridayToMonday() throws {
        let next = try TaskRules.complete(task("2026-11-06T17:00:00+08:00", rule: .weekdays), at: date("2026-11-06T17:01:00+08:00")).next
        #expect(next?.dueAt == date("2026-11-09T17:00:00+08:00"))
    }
    @Test func testDailyAcrossMonthEnd() throws {
        let next = try TaskRules.complete(task("2026-11-30T09:00:00+08:00", rule: .daily), at: date("2026-11-30T09:00:00+08:00")).next
        #expect(next?.dueAt == date("2026-12-01T09:00:00+08:00"))
    }
    @Test func testDailyAcrossDST() throws {
        var item = task("2026-10-31T09:00:00-04:00", rule: .daily)
        item.timeZoneID = "America/New_York"
        let next = try TaskRules.complete(item, at: item.dueAt!).next
        #expect(next?.dueAt == date("2026-11-01T09:00:00-05:00"))
    }
    @Test func testMonthlyDayRecoversAfterShortMonth() throws {
        var item = task("2027-01-31T09:00:00+08:00", rule: .monthly)
        item.monthlyDay = 31
        let february = try #require(TaskRules.complete(item, at: item.dueAt!).next)
        #expect(february.dueAt == date("2027-02-28T09:00:00+08:00"))
        #expect(february.monthlyDay == 31)
        let march = try #require(TaskRules.complete(february, at: february.dueAt!).next)
        #expect(march.dueAt == date("2027-03-31T09:00:00+08:00"))
    }
    @Test func testMonthlyDayCanDifferFromInitialDueDate() throws {
        var item = task("2026-11-09T21:00:00+08:00", rule: .monthly)
        item.monthlyDay = 15
        let next = try TaskRules.complete(item, at: item.dueAt!).next
        #expect(next?.dueAt == date("2026-11-15T21:00:00+08:00"))
    }
    @Test func testOverdueMonthlySkipsMissedOccurrences() throws {
        var item = task("2026-01-31T09:00:00+08:00", rule: .monthly)
        item.monthlyDay = 31
        let next = try TaskRules.complete(item, at: date("2026-03-31T10:00:00+08:00")).next
        #expect(next?.dueAt == date("2026-04-30T09:00:00+08:00"))
    }
    @Test func testInvalidMonthlyDayRejected() {
        var item = task("2026-11-09T09:00:00+08:00", rule: .monthly)
        item.monthlyDay = 32
        #expect(throws: (any Error).self) { try TaskRules.validate(item) }
    }
    @Test func testOldTaskPayloadWithoutMonthlyDayDecodes() throws {
        let item = task("2026-11-09T09:00:00+08:00", rule: .weekly)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        payload.removeValue(forKey: "monthlyDay")
        let restored = try JSONDecoder().decode(TaskItem.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(restored == item)
    }
    @Test func testRepeatedCompletionIsNoOp() throws {
        let first = try TaskRules.complete(task("2026-11-02T09:00:00+08:00", rule: .daily), at: date("2026-11-02T10:00:00+08:00"))
        let second = try TaskRules.complete(first.completed, at: date("2026-11-02T10:01:00+08:00"))
        #expect(second.next == nil)
        #expect(first.completed == second.completed)
    }
    @Test func testBlankTitleRejected() {
        var item = task(); item.title = " \n "
        #expect(throws: (any Error).self) { try TaskRules.validate(item) }
    }
    @Test func testMissingDueWithRepeatRejected() {
        #expect(throws: (any Error).self) { try TaskRules.validate(task(rule: .daily)) }
    }
    @Test func testUnknownTimeZoneRejected() {
        var item = task(); item.timeZoneID = "invalid/zone"
        #expect(throws: (any Error).self) { try TaskRules.validate(item) }
    }
    @Test func testOverdueRecurrenceSkipsMissedOccurrences() throws {
        let next = try TaskRules.complete(task("2026-10-02T09:00:00+08:00", rule: .daily), at: date("2026-11-02T10:00:00+08:00")).next
        #expect(next?.dueAt == date("2026-11-03T09:00:00+08:00"))
    }
    @Test func testDisplayTimeZoneDoesNotMutateTask() {
        let item = task("2026-11-03T00:30:00+08:00")
        #expect(TaskRules.isTodayOrOverdue(item, now: date("2026-11-02T15:00:00Z"), displayTimeZoneID: "America/New_York"))
        #expect(!(TaskRules.isTodayOrOverdue(item, now: date("2026-11-02T15:00:00Z"), displayTimeZoneID: "Asia/Shanghai")))
        #expect(item.timeZoneID == "Asia/Shanghai")
    }
    @Test func testFutureUsesDisplayTimeZoneDayBoundary() {
        let item = task("2026-11-03T00:30:00+08:00")
        let now = date("2026-11-02T15:00:00Z")
        #expect(TaskRules.isFuture(item, now: now, displayTimeZoneID: "Asia/Shanghai"))
        #expect(!TaskRules.isFuture(item, now: now, displayTimeZoneID: "America/New_York"))
        #expect(TaskRules.isDue(item, on: date("2026-11-03T12:00:00+08:00"), displayTimeZoneID: "Asia/Shanghai"))
        #expect(TaskRules.isDue(item, on: date("2026-11-02T12:00:00-05:00"), displayTimeZoneID: "America/New_York"))
    }
    @Test func testFutureExcludesCompletedAndUndatedTasks() {
        let now = date("2026-11-02T09:00:00+08:00")
        var completed = task("2026-11-03T09:00:00+08:00")
        completed.status = .completed
        #expect(!TaskRules.isFuture(completed, now: now, displayTimeZoneID: "Asia/Shanghai"))
        #expect(!TaskRules.isFuture(task(), now: now, displayTimeZoneID: "Asia/Shanghai"))
        #expect(!TaskRules.isDue(task(), on: now, displayTimeZoneID: "Asia/Shanghai"))
    }
}
