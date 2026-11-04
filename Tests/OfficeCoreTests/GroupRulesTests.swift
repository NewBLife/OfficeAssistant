import Foundation
import Testing
@testable import OfficeCore

@Suite struct GroupRulesTests {
    @Test func hierarchyAndScopes() throws {
        let parent = OfficeCore.WorkGroup(name: "客户 A"), other = OfficeCore.WorkGroup(name: "客户 B")
        let child = OfficeCore.WorkGroup(name: "项目一", parentID: parent.id)
        let groups = [parent, child, other]
        try GroupRules.validate(groups)
        #expect(GroupRules.matches(parent.id, scope: .group(parent.id), groups: groups))
        #expect(GroupRules.matches(child.id, scope: .group(parent.id), groups: groups))
        #expect(!GroupRules.matches(other.id, scope: .group(parent.id), groups: groups))
        #expect(!GroupRules.matches(parent.id, scope: .group(child.id), groups: groups))
        #expect(GroupRules.matches(nil, scope: .ungrouped, groups: groups))
        #expect(GroupRules.matches(UUID(), scope: .ungrouped, groups: groups))
        #expect(GroupRules.path(child.id, groups: groups) == "客户 A → 项目一")
        #expect(GroupRules.path(UUID(), groups: groups) == "未分组")
    }
    @Test func invalidTreesAndNames() throws {
        let a = OfficeCore.WorkGroup(name: "A"), b = OfficeCore.WorkGroup(name: "B")
        let child = OfficeCore.WorkGroup(name: "项目", parentID: a.id)
        let invalid: [[OfficeCore.WorkGroup]] = [
            [OfficeCore.WorkGroup(name: " ")], [OfficeCore.WorkGroup(name: String(repeating: "字", count: 81))],
            [OfficeCore.WorkGroup(name: "坏\n名字")], [OfficeCore.WorkGroup(name: "全部内容")], [OfficeCore.WorkGroup(name: "未分组")],
            [a, OfficeCore.WorkGroup(name: " a ")], [a, a], [OfficeCore.WorkGroup(name: "孤儿", parentID: UUID())],
            [OfficeCore.WorkGroup(id: a.id, name: "A", parentID: a.id)],
            [OfficeCore.WorkGroup(id: a.id, name: "A", parentID: b.id), OfficeCore.WorkGroup(id: b.id, name: "B", parentID: a.id)],
            [a, child, OfficeCore.WorkGroup(name: "第三层", parentID: child.id)]
        ]
        for groups in invalid { #expect(throws: (any Error).self) { try GroupRules.validate(groups) } }
        try GroupRules.validate([a, b, child, OfficeCore.WorkGroup(name: "项目", parentID: b.id)])
        try GroupRules.validate([OfficeCore.WorkGroup(name: String(repeating: "字", count: 80))])
    }
    @Test func oldPayloadsHaveNoGroup() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let task = TaskItem(title: "旧待办")
        let meeting = MeetingSession(title: "旧会议", configuration: AIConfiguration())
        func oldData<T: Encodable>(_ value: T) throws -> Data {
            var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
            json.removeValue(forKey: "groupID")
            return try JSONSerialization.data(withJSONObject: json)
        }
        #expect(try decoder.decode(TaskItem.self, from: oldData(task)).groupID == nil)
        #expect(try decoder.decode(MeetingSession.self, from: oldData(meeting)).groupID == nil)
    }
}
