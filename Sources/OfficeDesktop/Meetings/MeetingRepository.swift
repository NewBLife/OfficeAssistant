import Foundation
import CoreData
import OfficeCore

@MainActor public protocol MeetingRepository {
    func list() throws -> [MeetingSession]
    func save(_ meeting: MeetingSession) throws
    func segments(meetingID: UUID) throws -> [TranscriptSegment]
    func upsert(_ segment: TranscriptSegment) throws
}
@objc(OfficeMeetingBlob) final class MeetingBlob: NSManagedObject {
    @NSManaged var key: String
    @NSManaged var version: Int64
    @NSManaged var payload: Data
}
@MainActor public final class CoreDataMeetingRepository: MeetingRepository {
    let context: NSManagedObjectContext
    public init(url: URL? = nil, inMemory: Bool = false) throws {
        let entity = NSEntityDescription(); entity.name = "MeetingBlob"; entity.managedObjectClassName = NSStringFromClass(MeetingBlob.self)
        func attr(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let result = NSAttributeDescription(); result.name = name; result.attributeType = type; result.isOptional = false; return result
        }
        entity.properties = [attr("key", .stringAttributeType), attr("version", .integer64AttributeType), attr("payload", .binaryDataAttributeType)]; entity.uniquenessConstraints = [["key"]]
        let model = NSManagedObjectModel(); model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        var target = url
        if target == nil && !inMemory {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OfficeAssistant")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            target = folder.appendingPathComponent("meetings.store")
        }
        try coordinator.addPersistentStore(ofType: inMemory ? NSInMemoryStoreType : NSSQLiteStoreType, configurationName: nil, at: target)
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator; context.undoManager = nil
    }
    func records(prefix: String) throws -> [MeetingBlob] {
        let request = NSFetchRequest<MeetingBlob>(entityName: "MeetingBlob"); request.predicate = NSPredicate(format: "key BEGINSWITH %@", prefix)
        let records = try context.fetch(request)
        guard records.allSatisfy({ $0.version == 1 }) else { throw OfficeError.invalid("会议数据版本暂不支持，原记录已保留。") }
        return records
    }
    func stage<T: Codable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let existing = try records(prefix: key).first { $0.key == key }
        if let existing { _ = try JSONDecoder().decode(T.self, from: existing.payload) }
        let object = existing ?? MeetingBlob(entity: NSEntityDescription.entity(forEntityName: "MeetingBlob", in: context)!, insertInto: context)
        object.key = key; object.version = 1; object.payload = data
    }
    private func put<T: Codable>(_ value: T, key: String) throws {
        do { try stage(value, key: key); try context.save() } catch { context.rollback(); throw error }
    }
    public func list() throws -> [MeetingSession] {
        try records(prefix: "m.").map { try JSONDecoder().decode(MeetingSession.self, from: $0.payload) }.sorted { $0.startedAt > $1.startedAt }
    }
    public func save(_ meeting: MeetingSession) throws { try put(meeting, key: "m.\(meeting.id)") }
    public func segments(meetingID: UUID) throws -> [TranscriptSegment] {
        try records(prefix: "s.\(meetingID).").map { try JSONDecoder().decode(TranscriptSegment.self, from: $0.payload) }.sorted { $0.sourceStartSeconds < $1.sourceStartSeconds }
    }
    public func upsert(_ segment: TranscriptSegment) throws { try put(segment, key: "s.\(segment.id.id)") }
}
