import Foundation

public enum GroupRules {
    public static func validate(_ groups: [WorkGroup]) throws {
        guard Set(groups.map(\.id)).count == groups.count else { throw OfficeError.invalid("分组标识重复。") }
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var names: [UUID?: Set<String>] = [:]
        for group in groups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80,
                  !group.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !["全部内容", "未分组"].contains(name) else { throw OfficeError.invalid("分组名称须为 1–80 个字符，不能包含控制字符或使用保留名称。") }
            let key = name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names[group.parentID, default: []].insert(key).inserted else { throw OfficeError.invalid("同一级下已存在这个分组名称。") }
            if let parentID = group.parentID {
                guard parentID != group.id, let parent = byID[parentID], parent.parentID == nil else {
                    throw OfficeError.invalid("分组最多支持两层，请选择一级分组作为上级。有子分组的一级分组需先移出子分组。")
                }
            }
        }
    }
    public static func effectiveGroupID(_ id: UUID?, groups: [WorkGroup]) -> UUID? {
        guard let id, groups.contains(where: { $0.id == id }) else { return nil }; return id
    }
    public static func matches(_ id: UUID?, scope: GroupScope, groups: [WorkGroup]) -> Bool {
        let effective = effectiveGroupID(id, groups: groups)
        switch scope {
        case .all: return true
        case .ungrouped: return effective == nil
        case .group(let target):
            guard groups.contains(where: { $0.id == target }), let effective else { return false }
            return effective == target || groups.contains { $0.id == effective && $0.parentID == target }
        }
    }
    public static func path(_ id: UUID?, groups: [WorkGroup]) -> String {
        guard let group = groups.first(where: { $0.id == id }) else { return "未分组" }
        if let parent = groups.first(where: { $0.id == group.parentID }) { return parent.name + " → " + group.name }
        return group.name
    }
    public static func ordered(_ groups: [WorkGroup]) -> [WorkGroup] {
        groups.filter { $0.parentID == nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .flatMap { parent in [parent] + groups.filter { $0.parentID == parent.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }
}
