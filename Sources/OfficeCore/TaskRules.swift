import Foundation

public struct CompletionResult {
    public let completed: TaskItem
    public let next: TaskItem?
}
public enum TaskRules {
    public static func validate(_ item: TaskItem) throws {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfficeError.invalid("请填写待办标题。")
        }
        guard TimeZone(identifier: item.timeZoneID) != nil else { throw OfficeError.invalid("请选择有效时区。") }
        guard item.repeatRule == .none || item.dueAt != nil else { throw OfficeError.invalid("重复任务需要明确的截止时间。") }
    }

    public static func nextDueDate(after due: Date, rule: RepeatRule, timeZoneID: String, now: Date) throws -> Date? {
        guard rule != .none else { return nil }
        guard let zone = TimeZone(identifier: timeZoneID) else { throw OfficeError.invalid("无效时区。") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var next = due
        repeat {
            guard let candidate = calendar.date(byAdding: .day, value: rule == .weekly ? 7 : 1, to: next) else {
                throw OfficeError.invalid("无法计算下一次截止时间。")
            }
            next = candidate
        } while next <= now || (rule == .weekdays && calendar.isDateInWeekend(next))
        return next
    }

    public static func complete(_ item: TaskItem, at now: Date) throws -> CompletionResult {
        try validate(item)
        guard item.status != .completed else { return CompletionResult(completed: item, next: nil) }
        var completed = item
        completed.status = .completed; completed.completedAt = now; completed.snoozedUntil = nil
        var next: TaskItem?
        if let due = item.dueAt, let nextDate = try nextDueDate(after: due, rule: item.repeatRule, timeZoneID: item.timeZoneID, now: now) {
            var new = TaskItem(title: item.title, notes: item.notes, owner: item.owner, createdAt: now,
                               dueAt: nextDate, timeZoneID: item.timeZoneID, repeatRule: item.repeatRule)
            new.seriesID = item.seriesID
            new.meetingLinks = item.meetingLinks; new.meetingActionReceipts = item.meetingActionReceipts
            completed.nextOccurrenceID = new.id; next = new
        }
        return CompletionResult(completed: completed, next: next)
    }

    public static func isTodayOrOverdue(_ item: TaskItem, now: Date, displayTimeZoneID: String) -> Bool {
        guard item.status != .completed, let due = item.dueAt else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: displayTimeZoneID) ?? .current
        return due < (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now)
    }
}
