import Foundation
import CoreData
import OfficeCore

@MainActor public final class CoreDataTaskRepository: TaskRepository {
    let coordinator: NSPersistentStoreCoordinator
    let context: NSManagedObjectContext

    public init(url: URL? = nil, inMemory: Bool = false) throws {
        let entity = NSEntityDescription()
        entity.name = "TaskRecord"; entity.managedObjectClassName = NSStringFromClass(TaskRecord.self)
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let result = NSAttributeDescription(); result.name = name; result.attributeType = type; result.isOptional = false
            return result
        }
        entity.properties = [attribute("id", .UUIDAttributeType), attribute("schemaVersion", .integer64AttributeType), attribute("payload", .binaryDataAttributeType)]
        entity.uniquenessConstraints = [["id"]]
        let model = NSManagedObjectModel(); model.entities = [entity]
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        var storageURL = url
        if !inMemory && storageURL == nil {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("OfficeAssistant", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            storageURL = folder.appendingPathComponent("tasks.store")
        }
        try coordinator.addPersistentStore(ofType: inMemory ? NSInMemoryStoreType : NSSQLiteStoreType,
                                           configurationName: nil, at: inMemory ? nil : storageURL,
                                           options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator; context.undoManager = nil
    }
    private func records() throws -> [TaskRecord] { try context.fetch(NSFetchRequest<TaskRecord>(entityName: "TaskRecord")) }
    public func load() throws -> [TaskItem] {
        try records().map { record in
            guard record.schemaVersion == 1 else { throw OfficeError.invalid("数据版本不受支持，原始记录已保留。请勿清空数据库。") }
            let item = try JSONDecoder().decode(TaskItem.self, from: record.payload)
            guard item.id == record.id else { throw OfficeError.invalid("待办标识不一致，原始记录已保留。") }
            try TaskRules.validate(item)
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func save(_ items: [TaskItem]) throws {
        _ = try load()
        guard Set(items.map(\.id)).count == items.count else { throw OfficeError.invalid("重复的待办标识。") }
        let encoded = try items.map { item -> (TaskItem, Data) in
            try TaskRules.validate(item)
            return (item, try JSONEncoder().encode(item))
        }
        let existing = try records(); let desiredIDs = Set(items.map(\.id))
        do {
            let recordsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for (item, data) in encoded {
                if let record = recordsByID[item.id] { record.payload = data }
                else { _ = TaskRecord(context: context, id: item.id, payload: data) }
            }
            for record in existing where !desiredIDs.contains(record.id) { context.delete(record) }
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
