import Foundation
import Testing
@testable import OfficeCore

@Suite struct GroupContentFilterTests {
    @Test func filtersUseSameScopeSearchAndStatus() {
        let parent = OfficeCore.WorkGroup(name: "客户"), child = OfficeCore.WorkGroup(name: "项目")
        let groups = [parent, OfficeCore.WorkGroup(id: child.id, name: child.name, parentID: parent.id)]
        var direct = TaskItem(title: "合同"); direct.groupID = parent.id
        var nested = TaskItem(title: "报价", status: .completed); nested.groupID = child.id
        var stale = TaskItem(title: "旧组"); stale.groupID = UUID()
        let tasks = [direct, nested, stale]
        #expect(GroupContentFilter.tasks(tasks, scope: .group(parent.id), groups: groups, search: "", status: nil).count == 2)
        #expect(GroupContentFilter.tasks(tasks, scope: .group(child.id), groups: groups, search: "报价", status: .completed).map(\.id) == [nested.id])
        #expect(GroupContentFilter.tasks(tasks, scope: .group(parent.id), groups: groups, search: "报价", status: .pending).isEmpty)
        #expect(GroupContentFilter.tasks(tasks, scope: .ungrouped, groups: groups, search: "", status: nil).map(\.id) == [stale.id])
        var meeting = MeetingSession(title: "报价讨论", configuration: AIConfiguration()); meeting.groupID = child.id
        #expect(GroupContentFilter.meetings([meeting], scope: .group(parent.id), groups: groups, search: "报价").map(\.id) == [meeting.id])
        #expect(GroupContentFilter.meetings([meeting], scope: .ungrouped, groups: groups, search: "").isEmpty)
        #expect(GroupContentFilter.meetings([meeting], scope: .group(parent.id), groups: [], search: "").isEmpty)
    }
}
