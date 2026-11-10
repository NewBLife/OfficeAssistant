import Foundation
import Testing
@testable import OfficeCore

@Suite struct GroupContentFilterTests {
    @Test func meetingSectionsFollowGroupOrderAndKeepNewestFirst() {
        let parent = OfficeCore.WorkGroup(name: "客户")
        let child = OfficeCore.WorkGroup(name: "项目", parentID: parent.id)
        let other = OfficeCore.WorkGroup(name: "内部")
        let groups = [parent, child, other]
        var older = MeetingSession(title: "早会", configuration: AIConfiguration())
        older.groupID = child.id; older.startedAt = Date(timeIntervalSince1970: 100)
        var newer = MeetingSession(title: "晚会", configuration: AIConfiguration())
        newer.groupID = child.id; newer.startedAt = Date(timeIntervalSince1970: 200)
        var direct = MeetingSession(title: "客户会议", configuration: AIConfiguration())
        direct.groupID = parent.id
        let ungrouped = MeetingSession(title: "自由会议", configuration: AIConfiguration())
        let sections = GroupContentFilter.meetingSections([older, ungrouped, newer, direct], scope: .all, groups: groups, search: "")
        #expect(sections.map(\.title) == ["客户", "客户 → 项目", "未分组"])
        #expect(sections[1].meetings.map(\.id) == [newer.id, older.id])
        #expect(sections[2].meetings.map(\.id) == [ungrouped.id])
        #expect(GroupContentFilter.meetingSections([older, ungrouped, newer, direct], scope: .group(parent.id), groups: groups, search: "晚会").map(\.title) == ["客户 → 项目"])
        #expect(GroupContentFilter.meetingSections([older, ungrouped, newer, direct], scope: .ungrouped, groups: groups, search: "").map(\.title) == ["未分组"])
    }
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
