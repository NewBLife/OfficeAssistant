import OfficeCore

@MainActor public protocol TaskRepository {
    func load() throws -> [TaskItem]
    func save(_ items: [TaskItem]) throws
}
