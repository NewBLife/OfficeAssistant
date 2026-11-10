import Foundation
import Testing
@testable import OfficeCore

struct TaskCSVRendererTests {
    @Test func exportsColumnsEscapedTextAndLocalTimes() throws {
        let parent = WorkGroup(name: "客户")
        let child = WorkGroup(name: "项目", parentID: parent.id)
        var item = TaskItem(title: "=SUM(1,2)", notes: "第一行,\n\"第二行\"", owner: "张三",
                            createdAt: ISO8601DateFormatter().date(from: "2026-11-09T23:00:00Z")!,
                            dueAt: ISO8601DateFormatter().date(from: "2026-11-10T13:00:00Z")!,
                            repeatRule: .monthly, monthlyDay: 31)
        item.groupID = child.id
        let output = try TaskCSVRenderer.render(items: [item], groups: [parent, child], displayTimeZoneID: "Asia/Shanghai")
        #expect(output.hasPrefix("\"标题\",\"备注\",\"负责人\",\"状态\",\"截止时间\",\"时区\",\"重复\",\"分组\",\"创建时间\",\"完成时间\"\r\n"))
        #expect(output.contains("\"'=SUM(1,2)\",\"第一行,\n\"\"第二行\"\"\""))
        #expect(output.contains("\"2026-11-10 21:00\",\"Asia/Shanghai\",\"每月 31 号\",\"客户 → 项目\",\"2026-11-10 07:00\""))
        #expect(output.hasSuffix("\"\"\r\n"))
    }
    @Test func unresolvedDueTextAndInvalidZone() throws {
        let item = TaskItem(title: "跟进", dueText: "下周", timeZoneID: "Asia/Shanghai")
        let output = try TaskCSVRenderer.render(items: [item], groups: [], displayTimeZoneID: "Asia/Shanghai")
        #expect(output.contains("\"下周\",\"Asia/Shanghai\""))
        let noGroups = try TaskCSVRenderer.render(items: [item], groups: nil, displayTimeZoneID: "Asia/Shanghai")
        #expect(noGroups.contains("\"分组暂时不可用\""))
        #expect(throws: (any Error).self) {
            try TaskCSVRenderer.render(items: [item], groups: [], displayTimeZoneID: "Invalid/Zone")
        }
    }
}
