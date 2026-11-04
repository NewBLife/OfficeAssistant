import Foundation
import Observation
import OfficeCore

@MainActor @Observable public final class GroupStore {
    public private(set) var groups: [OfficeCore.WorkGroup] = []
    public private(set) var isLoaded = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private let write: (Data, URL) throws -> Void
    private struct Snapshot: Codable { var version: Int; var groups: [OfficeCore.WorkGroup] }
    public init(url: URL? = nil, write: ((Data, URL) throws -> Void)? = nil) {
        self.write = write ?? { try $0.write(to: $1, options: .atomic) }
        do {
            if let url { self.url = url }
            else {
                let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OfficeAssistant", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                self.url = folder.appendingPathComponent("groups.json")
            }
            try reload()
        } catch { isLoaded = false; errorMessage = "分组目录无法读取，原文件已保留。请重试读取或从备份恢复。" }
    }
    public func reload() throws {
        do {
            guard let url else { throw OfficeError.invalid("分组存储位置不可用。") }
            let next: [OfficeCore.WorkGroup]
            do {
                let data = try Data(contentsOf: url)
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                guard snapshot.version == 1 else { throw OfficeError.invalid("分组数据版本不受支持。") }
                try GroupRules.validate(snapshot.groups); next = snapshot.groups
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { next = [] }
            groups = next; isLoaded = true; errorMessage = nil
        } catch {
            isLoaded = false; errorMessage = "分组目录无法读取，原文件已保留。请重试读取或从备份恢复。"; throw error
        }
    }
    private func save(_ next: [OfficeCore.WorkGroup]) throws {
        guard isLoaded, let url else { throw OfficeError.invalid("分组目录尚未读取，已暂停分组修改。") }
        try GroupRules.validate(next)
        do {
            // Check the disk again so externally damaged data is never overwritten.
            let previous = groups
            try reload()
            guard groups == previous else { throw OfficeError.invalid("分组目录已在其他位置更新，请核对最新列表后重试。") }
            let data = try JSONEncoder().encode(Snapshot(version: 1, groups: next))
            try write(data, url); groups = next; errorMessage = nil
        } catch { errorMessage = "分组未能保存，原目录已保留。请检查存储位置后重试。"; throw error }
    }
    public func normalized(_ id: UUID?) throws -> UUID? {
        guard isLoaded else { throw OfficeError.invalid("分组目录暂时不可用。") }
        return GroupRules.effectiveGroupID(id, groups: groups)
    }
    @discardableResult public func create(name: String, parentID: UUID? = nil) throws -> UUID {
        let value = OfficeCore.WorkGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: parentID)
        // Validate the original input as well, before trimming control characters.
        try GroupRules.validate(groups + [OfficeCore.WorkGroup(id: value.id, name: name, parentID: parentID)])
        try save(groups + [value]); return value.id
    }
    public func update(id: UUID, name: String, parentID: UUID?) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw OfficeError.invalid("分组已不存在。") }
        var next = groups; next[index].name = name; next[index].parentID = parentID
        try GroupRules.validate(next)
        next[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); try save(next)
    }
    public func rename(id: UUID, name: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw OfficeError.invalid("分组已不存在。") }
        var next = groups; next[index].name = name; try GroupRules.validate(next)
        next[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); try save(next)
    }
    public func move(id: UUID, parentID: UUID?) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw OfficeError.invalid("分组已不存在。") }
        var next = groups; next[index].parentID = parentID; try save(next)
    }
    public func delete(id: UUID) throws {
        guard groups.contains(where: { $0.id == id }) else { throw OfficeError.invalid("分组已不存在。") }
        try save(groups.filter { $0.id != id && $0.parentID != id })
    }
}
