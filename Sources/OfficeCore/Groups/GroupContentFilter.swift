import Foundation

public enum GroupContentFilter {
    public static func tasks(_ values: [TaskItem], scope: GroupScope, groups: [WorkGroup], search: String, status: TaskStatus?) -> [TaskItem] {
        values.filter {
            GroupRules.matches($0.groupID, scope: scope, groups: groups) && (status == nil || $0.status == status) &&
            (search.isEmpty || "\($0.title) \($0.notes) \($0.owner ?? "")".localizedCaseInsensitiveContains(search))
        }.sorted { ($0.dueAt ?? .distantFuture) == ($1.dueAt ?? .distantFuture) ? $0.createdAt > $1.createdAt : ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }
    public static func meetings(_ values: [MeetingSession], scope: GroupScope, groups: [WorkGroup], search: String) -> [MeetingSession] {
        values.filter { GroupRules.matches($0.groupID, scope: scope, groups: groups) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }.sorted { $0.startedAt > $1.startedAt }
    }
}
