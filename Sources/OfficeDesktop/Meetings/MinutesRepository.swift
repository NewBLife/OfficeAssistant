import Foundation
import CoreData
import OfficeCore

@MainActor public protocol MinutesRepository {
    func documents(meetingID: UUID) throws -> [MinutesDocument]
    func candidates(meetingID: UUID) throws -> [ActionCandidate]
    func save(document: MinutesDocument, candidates: [ActionCandidate]) throws
    func saveCandidates(_ candidates: [ActionCandidate], meetingID: UUID) throws
    func jobs(meetingID: UUID?) throws -> [MinutesJobRecord]
    func saveJob(_ job: MinutesJobRecord) throws
}
extension CoreDataMeetingRepository: MinutesRepository {
    public func documents(meetingID: UUID) throws -> [MinutesDocument] {
        try records(prefix: "n.\(meetingID).").map { try JSONDecoder().decode(MinutesDocument.self, from: $0.payload) }.sorted { $0.revision > $1.revision }
    }
    public func candidates(meetingID: UUID) throws -> [ActionCandidate] {
        try records(prefix: "a.\(meetingID).").map { try JSONDecoder().decode(ActionCandidate.self, from: $0.payload) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func stageCandidates(_ values: [ActionCandidate], meetingID: UUID) throws {
        guard values.allSatisfy({ $0.meetingID == meetingID }), Set(values.map(\.id)).count == values.count else { throw OfficeError.invalid("行动项来源不一致或重复，原记录已保留。") }
        let old = try candidates(meetingID: meetingID); let desired = Set(values.map(\.id))
        for item in values { try stage(item, key: "a.\(meetingID).\(item.id)") }
        for item in old where !desired.contains(item.id) { for record in try records(prefix: "a.\(meetingID).\(item.id)") { context.delete(record) } }
    }
    public func save(document: MinutesDocument, candidates: [ActionCandidate]) throws {
        do {
            if let old = try documents(meetingID: document.meetingID).first(where: { $0.id == document.id }), old != document { throw OfficeError.invalid("纪要历史版本不可覆盖，请保存为新版本。") }
            try stage(document, key: "n.\(document.meetingID).\(document.id)")
            try stageCandidates(candidates, meetingID: document.meetingID); try context.save()
        } catch { context.rollback(); throw error }
    }
    public func saveCandidates(_ candidates: [ActionCandidate], meetingID: UUID) throws {
        do { try stageCandidates(candidates, meetingID: meetingID); try context.save() } catch { context.rollback(); throw error }
    }
    public func jobs(meetingID: UUID? = nil) throws -> [MinutesJobRecord] {
        try records(prefix: meetingID.map { "j.\($0)." } ?? "j.").map { try JSONDecoder().decode(MinutesJobRecord.self, from: $0.payload) }.sorted { $0.startedAt > $1.startedAt }
    }
    public func saveJob(_ job: MinutesJobRecord) throws {
        do { try stage(job, key: "j.\(job.meetingID).\(job.id)"); try context.save() } catch { context.rollback(); throw error }
    }
}
