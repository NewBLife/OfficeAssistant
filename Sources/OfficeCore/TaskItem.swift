import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case pending, inProgress, completed
    public var label: String { switch self { case .pending: "待处理"; case .inProgress: "进行中"; case .completed: "已完成" } }
}
public enum RepeatRule: String, Codable, CaseIterable, Sendable {
    case none, daily, weekdays, weekly
    public var label: String { switch self { case .none: "不重复"; case .daily: "每天"; case .weekdays: "工作日"; case .weekly: "每周" } }
}
public struct TaskItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var owner: String?
    public var status: TaskStatus
    public var createdAt: Date
    public var completedAt: Date?
    public var dueAt: Date?
    public var dueText: String?
    public var timeZoneID: String
    public var repeatRule: RepeatRule
    public var seriesID: UUID
    public var nextOccurrenceID: UUID?
    public var snoozedUntil: Date?
    public var meetingLinks: [TaskMeetingLink]?
    public var meetingActionReceipts: [MeetingActionReceipt]?

    public init(id: UUID = UUID(), title: String, notes: String = "", owner: String? = nil,
                status: TaskStatus = .pending, createdAt: Date = Date(), dueAt: Date? = nil,
                dueText: String? = nil, timeZoneID: String = "Asia/Shanghai", repeatRule: RepeatRule = .none) {
        self.id = id; self.title = title; self.notes = notes; self.owner = owner
        self.status = status; self.createdAt = createdAt; self.dueAt = dueAt
        self.dueText = dueText; self.timeZoneID = timeZoneID; self.repeatRule = repeatRule
        self.seriesID = id
    }
}
public enum OfficeError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}
