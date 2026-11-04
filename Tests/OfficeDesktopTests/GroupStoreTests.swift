import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct GroupStoreTests {
    func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("groups.json")
    }
    @Test func roundTripRenameMoveDelete() throws {
        let url = try temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = GroupStore(url: url)
        #expect(store.isLoaded && store.groups.isEmpty)
        let a = try store.create(name: "  客户 A "), b = try store.create(name: "客户 B")
        let child = try store.create(name: "项目一", parentID: a)
        #expect(throws: (any Error).self) { try store.move(id: a, parentID: b) }
        #expect(throws: (any Error).self) { try store.create(name: "第三层", parentID: child) }
        try store.rename(id: child, name: "项目二")
        try store.move(id: child, parentID: b)
        #expect(GroupRules.path(child, groups: store.groups) == "客户 B → 项目二")
        #expect(GroupStore(url: url).groups == store.groups)
        try store.delete(id: b)
        #expect(store.groups.map(\.id) == [a])
        #expect(try store.normalized(child) == nil)
        #expect(GroupStore(url: url).groups == store.groups)
    }
    @Test func corruptedUnknownVersionAndWriteFailurePreserveData() throws {
        let url = try temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for original in [Data("broken".utf8), Data("{\"version\":99,\"groups\":[]}".utf8)] {
            try original.write(to: url)
            let store = GroupStore(url: url)
            #expect(!store.isLoaded)
            #expect(throws: (any Error).self) { try store.create(name: "不能覆盖") }
            #expect(try Data(contentsOf: url) == original)
            try Data("{\"version\":1,\"groups\":[]}".utf8).write(to: url)
            try store.reload(); #expect(store.isLoaded)
        }
        let store = GroupStore(url: url, write: { _, _ in throw OfficeError.invalid("磁盘不可写") })
        let bytes = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try store.create(name: "失败") }
        #expect(store.groups.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
    }
}
