import Foundation

public struct WorkGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

public enum GroupScope: Hashable, Sendable {
    case all, ungrouped, group(UUID)
    public var defaultGroupID: UUID? { if case let .group(id) = self { id } else { nil } }
}
