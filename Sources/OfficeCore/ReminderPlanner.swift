import Foundation

public enum ReminderTrigger: Equatable, Sendable {
    case once(Date)
    case daily(hour: Int, minute: Int, timeZoneID: String)
}
public struct ReminderRequest: Equatable, Sendable {
    public let id: String
    public let taskID: UUID?
    public let title: String
    public let body: String
    public let trigger: ReminderTrigger
    public init(id: String, taskID: UUID?, title: String, body: String, trigger: ReminderTrigger) {
        self.id = id; self.taskID = taskID; self.title = title; self.body = body; self.trigger = trigger
    }
}
public struct ReminderPlan: Sendable {
    public let requests: [ReminderRequest]
    public let overdueTaskIDs: [UUID]
}
public enum ReminderPlanner {
    public static func plan(tasks: [TaskItem], preferences: AppPreferences, now: Date) -> ReminderPlan {
        let timed = tasks.filter { $0.status != .completed }.compactMap { item -> (TaskItem, Date)? in
            guard let when = item.snoozedUntil ?? item.dueAt else { return nil }
            return (item, when)
        }.sorted { $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 < $1.1 }
        var requests = timed.filter { $0.1 > now }.prefix(48).map { item, when in
            ReminderRequest(id: "office.task.\(item.id.uuidString)", taskID: item.id,
                            title: item.title, body: "待办到时间了 · \(item.owner ?? "负责人未指定")", trigger: .once(when))
        }
        if preferences.dailySummaryEnabled {
            requests.append(ReminderRequest(id: "office.summary", taskID: nil, title: "今日待办",
                                            body: "查看今天的待办与逾期事项", trigger: .daily(hour: preferences.summaryHour, minute: preferences.summaryMinute, timeZoneID: preferences.timeZoneID)))
        }
        return ReminderPlan(requests: requests, overdueTaskIDs: timed.filter { $0.1 <= now }.map { $0.0.id })
    }
}
