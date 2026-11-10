import Foundation

public struct MeetingGroupSection: Identifiable {
    public let groupID: UUID?
    public let title: String
    public let meetings: [MeetingSession]
    public var id: String { groupID?.uuidString ?? "ungrouped" }
}

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
    public static func meetingSections(_ values: [MeetingSession], scope: GroupScope, groups: [WorkGroup], search: String) -> [MeetingGroupSection] {
        let filtered = meetings(values, scope: scope, groups: groups, search: search)
        let grouped = Dictionary(grouping: filtered) { GroupRules.effectiveGroupID($0.groupID, groups: groups) }
        var sections = GroupRules.ordered(groups).compactMap { group -> MeetingGroupSection? in
            guard let items = grouped[group.id], !items.isEmpty else { return nil }
            return MeetingGroupSection(groupID: group.id, title: GroupRules.path(group.id, groups: groups), meetings: items)
        }
        if let items = grouped[nil], !items.isEmpty {
            sections.append(MeetingGroupSection(groupID: nil, title: "未分组", meetings: items))
        }
        return sections
    }
}
