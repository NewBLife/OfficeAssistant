import Foundation
import Testing
@testable import OfficeCore

struct MinutesExportTests {
    @Test func testExportEscapesMarkdownAndDoesNotLeakUnrelatedTasks() throws {
        var doc = MinutesDocument(meetingID: UUID(), meetingTitle: "报价", options: MinutesOptions())
        doc.overviewZH = "金额15万日元 ![x](https://example.com/x) <script>"
        let unrelated = TaskItem(title: "不应出现的私人待办")
        let output = try MinutesExportRenderer.render(document: doc, candidates: [], linkedTasks: [unrelated], language: .chinese, format: .markdown)
        #expect(output.contains("15万日元")); #expect(!output.contains("![x]")); #expect(!output.contains("<script>")); #expect(!output.contains(unrelated.title))
        #expect(output.contains("明确决定")); #expect(output.contains("行动项"))
    }
}

extension MinutesExportTests {
    @Test func testExportUsesCurrentTaskClearedFieldsAndCompletion() throws {
        let meetingID = UUID(); var doc = MinutesDocument(meetingID: meetingID, meetingTitle: "中日会议", options: MinutesOptions(language: .chineseJapanese))
        doc.overviewZH = "测试"; doc.overviewJA = "テスト"
        var candidate = ActionCandidate(meetingID: meetingID, titleZH: "原始事项", evidence: [])
        candidate.owner = "旧负责人"; candidate.dueText = "明天下午三点"; candidate.dueAt = Date(); candidate.titleJA = "元の項目"
        var task = TaskItem(title: "用户修改后事项"); task.status = .completed
        task.meetingLinks = [TaskMeetingLink(meetingID: meetingID, meetingTitleSnapshot: "会议", candidateID: candidate.id)]
        task.meetingActionReceipts = [MeetingActionReceipt(meetingID: meetingID, candidateID: candidate.id, joinedAt: Date())]
        let output = try MinutesExportRenderer.render(document: doc, candidates: [candidate], linkedTasks: [task], language: .chineseJapanese, format: .plainText)
        #expect(output.contains("用户修改后事项 [已完成]")); #expect(output.contains("テスト")); #expect(output.contains("未指定")); #expect(output.contains("未确定"))
        #expect(!output.contains("旧负责人")); #expect(!output.contains("明天下午三点"))
    }
}

extension MinutesExportTests {
    @Test func testEditedBilingualTaskLabelsJapaneseAsOriginal() throws {
        let id = UUID(); var doc = MinutesDocument(meetingID: id, meetingTitle: "报价", options: MinutesOptions(language: .chineseJapanese))
        doc.overviewZH = "报价"; doc.overviewJA = "見積もり"
        var candidate = ActionCandidate(meetingID: id, titleZH: "发送15万日元报价", evidence: []); candidate.titleJA = "15万円の見積もりを送付"
        var task = TaskItem(title: "发送12万日元报价")
        task.meetingLinks = [TaskMeetingLink(meetingID: id, meetingTitleSnapshot: "报价", candidateID: candidate.id)]
        task.meetingActionReceipts = [MeetingActionReceipt(meetingID: id, candidateID: candidate.id, joinedAt: Date())]
        let output = try MinutesExportRenderer.render(document: doc, candidates: [candidate], linkedTasks: [task], language: .chineseJapanese, format: .plainText)
        #expect(output.contains(task.title)); #expect(output.contains("原始日文（修改后需重新核对）：15万円"))
    }
}
