import Foundation
import Testing
@testable import OfficeCore

struct TranscriptExportTests {
    private func segment(_ meeting: MeetingSession, sequence: Int, start: Double, text: String?) -> TranscriptSegment {
        var result = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: sequence))
        result.sourceStartSeconds = start; result.sourceEndSeconds = start + 20; result.finalText = text
        return result
    }
    @Test func testOnlyFinalizedCurrentMeetingInTimelineOrder() throws {
        let meeting = MeetingSession(title: "测试会议", configuration: AIConfiguration())
        var first = segment(meeting, sequence: 0, start: 1, text: "最初的原文")
        first.translatedText = "最初の原文"; first.translationState = .completed
        let last = segment(meeting, sequence: 2, start: 7205, text: "最后的原文")
        var partial = segment(meeting, sequence: 1, start: 30, text: nil); partial.partialText = "未定稿不能导出"
        let other = segment(MeetingSession(title: "其他会议", configuration: AIConfiguration()), sequence: 0, start: 0, text: "其他会议不能导出")
        let text = try TranscriptExportRenderer.render(meeting: meeting, segments: [last, partial, other, first], format: .plainText)
        #expect(text.contains("00:00:01 – 00:00:21 · 音频文件"))
        #expect(text.contains("02:00:05"))
        #expect(text.contains("最初の原文"))
        #expect(text.contains("已定稿片段：2"))
        #expect(!text.contains("未定稿不能导出") && !text.contains("其他会议不能导出"))
        #expect(text.range(of: "最初的原文")!.lowerBound < text.range(of: "最后的原文")!.lowerBound)
    }
    @Test func testOnlyTranscriptionDoesNotExportOldTranslation() throws {
        var meeting = MeetingSession(title: "仅转写", configuration: AIConfiguration()); meeting.configuration.translationEnabled = false
        var item = segment(meeting, sequence: 0, start: 0, text: "已校对的原文")
        item.translatedText = "旧译文不能导出"
        let text = try TranscriptExportRenderer.render(meeting: meeting, segments: [item], format: .plainText)
        #expect(text.contains("已校对的原文"))
        #expect(!text.contains("译文"))
    }
    @Test func testUnfinishedTranslationIsExplicitlyMarked() throws {
        let meeting = MeetingSession(title: "翻译状态", configuration: AIConfiguration())
        var item = segment(meeting, sequence: 0, start: 0, text: "真实原文")
        item.translatedText = "一部分译文"; item.translationState = .processing
        let text = try TranscriptExportRenderer.render(meeting: meeting, segments: [item], format: .plainText)
        #expect(text.contains("翻译中，尚未完成")); #expect(text.contains("一部分译文"))
        item.translatedText = ""; item.translationState = .failed
        let failed = try TranscriptExportRenderer.render(meeting: meeting, segments: [item], format: .plainText)
        #expect(failed.contains("翻译失败")); #expect(failed.contains("暂无译文"))
    }
    @Test func testMarkdownEscapesSourceMarkup() throws {
        let meeting = MeetingSession(title: "标题 [链接]", configuration: AIConfiguration())
        let item = segment(meeting, sequence: 0, start: 0, text: "# 原文\n[内容](https://example.com) **重点**")
        let markdown = try TranscriptExportRenderer.render(meeting: meeting, segments: [item], format: .markdown)
        #expect(markdown.hasPrefix("# 标题 \\[链接\\]"))
        #expect(markdown.contains("\\# 原文\n\\[内容\\]\\(https://example\\.com\\)"))
        #expect(markdown.contains("## 00:00:00"))
    }
    @Test func testLongMeetingPreservesAllTextAndTail() throws {
        let meeting = MeetingSession(title: "长会议", configuration: AIConfiguration())
        let items = (0..<500).map { segment(meeting, sequence: $0, start: Double($0 * 30), text: "原文第\($0)段结束") }
        let text = try TranscriptExportRenderer.render(meeting: meeting, segments: items, format: .plainText)
        #expect(text.contains("已定稿片段：500"))
        for item in items { #expect(text.contains(item.finalText!)) }
        #expect(text.contains("04:09:30"))
    }
    @Test func testEmptyOrPartialTranscriptCannotBeExported() throws {
        let meeting = MeetingSession(title: "空会议", configuration: AIConfiguration())
        #expect(throws: (any Error).self) { try TranscriptExportRenderer.render(meeting: meeting, segments: [], format: .plainText) }
        #expect(throws: (any Error).self) { try TranscriptExportRenderer.render(meeting: meeting, segments: [segment(meeting, sequence: 0, start: 0, text: nil)], format: .markdown) }
    }
}
