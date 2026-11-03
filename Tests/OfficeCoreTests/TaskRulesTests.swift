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
}
