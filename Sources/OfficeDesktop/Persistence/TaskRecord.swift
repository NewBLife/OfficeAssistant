import Foundation
import CoreData

@objc(OfficeTaskRecord) final class TaskRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var schemaVersion: Int64
    @NSManaged var payload: Data
    convenience init(context: NSManagedObjectContext, id: UUID, schemaVersion: Int = 1, payload: Data) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "TaskRecord", in: context)!, insertInto: context)
        self.id = id; self.schemaVersion = Int64(schemaVersion); self.payload = payload
    }
}
