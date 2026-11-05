import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct MinutesEvidenceResolverTests {
    private func snapshot(_ texts: [String]) -> MinutesSnapshot {
        let meeting = MeetingSession(title: "引用校验", configuration: AIConfiguration())
        return MinutesSnapshot(meeting: meeting, segments: texts.enumerated().map { index, text in
            var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: index))
            segment.sourceStartSeconds = Double(index * 30); segment.revision = 3; segment.finalText = text
            return segment
        })
    }
    private func content(key: String, quote: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "overviewZH": "讨论报价", "topics": [], "openQuestions": [], "actions": [],
            "decisions": [["textZH": "报价安排", "evidence": [["segmentKey": key, "quote": quote]]]]
        ])
    }
    @Test func testFormattingRepairStoresActualSourceTextAndUTF16Offsets() throws {
        let input = snapshot(["👩‍💻前言：张三说明，明天 发送报价。后文"])
        let result = try MinutesGenerator.decodeContent(content(key: "file:0", quote: "张三说明明天发送报价"), snapshot: input, options: MinutesOptions())
        let reference = try #require(result.document.decisions.first?.evidence.first)
        #expect(reference.quote == "张三说明，明天 发送报价")
        #expect(reference.revision == 3)
        let range = NSRange(location: reference.startUTF16, length: reference.lengthUTF16)
        #expect((input.segments[0].text as NSString).substring(with: range) == reference.quote)
        #expect(reference.startUTF16 == (input.segments[0].text as NSString).range(of: reference.quote).location)
    }
    @Test func testWrongIDIsRepairedOnlyForUniqueLongQuoteInSubmittedChunk() throws {
        let input = snapshot(["原片段只讨论行程", "张三说明明天发送正式报价"])
        let result = try MinutesGenerator.decodeContent(content(key: "file:0", quote: input.segments[1].text), snapshot: input, options: MinutesOptions())
        #expect(result.document.decisions[0].evidence[0].segmentID == input.segments[1].id)
        #expect(result.document.decisions[0].evidence[0].sourceStartSeconds == 30)
        let duplicate = snapshot(["张三说明明天发送正式报价", "张三说明明天发送正式报价"])
        #expect(throws: MinutesEvidenceMismatch.self) {
            try MinutesGenerator.decodeContent(content(key: "file:99", quote: duplicate.segments[0].text), snapshot: duplicate, options: MinutesOptions())
        }
    }
    @Test(arguments: [
        ["投资金额确定为1.5万元", "投资金额确定为15万元"],
        ["投资金额确定为1 , 500万元", "投资金额确定为1500万元"],
        ["张三明确说明不需要发送报价", "张三明确说明需要发送报价"],
        ["网址确定为example.com", "网址确定为examplecom"],
        ["张三说明明天发送报价", "张三说明明天发送合同"]
    ]) func testNumbersWordsAndNegationCannotBeRepaired(pair: [String]) throws {
        let input = snapshot([pair[0]])
        #expect(throws: MinutesEvidenceMismatch.self) {
            try MinutesGenerator.decodeContent(content(key: "file:0", quote: pair[1]), snapshot: input, options: MinutesOptions())
        }
    }
    @Test func testCannotBorrowEvidenceFromOutsideSubmittedChunk() throws {
        let full = snapshot(["这里只讨论行程", "张三说明明天发送正式报价"])
        let chunk = MinutesSnapshot(meeting: full.meeting, segments: [full.segments[0]])
        #expect(throws: MinutesEvidenceMismatch.self) {
            try MinutesGenerator.decodeContent(content(key: "file:1", quote: full.segments[1].text), snapshot: chunk, options: MinutesOptions(), sourceSnapshot: full)
        }
    }
    @Test func testChunkEvidenceMapsBackToOriginalSourceAfterFormattingRepair() throws {
        let full = snapshot(["前面的讨论。张三说明，明天 发送报价。"])
        var fragment = full.segments[0]; fragment.finalText = "张三说明，明天 发送报价。"
        let chunk = MinutesSnapshot(meeting: full.meeting, segments: [fragment])
        let result = try MinutesGenerator.decodeContent(content(key: "file:0", quote: "张三说明明天发送报价"), snapshot: chunk, options: MinutesOptions(), sourceSnapshot: full)
        let reference = try #require(result.document.decisions.first?.evidence.first)
        #expect(reference.startUTF16 == (full.segments[0].text as NSString).range(of: "张三说明").location)
        #expect((full.segments[0].text as NSString).substring(with: NSRange(location: reference.startUTF16, length: reference.lengthUTF16)) == reference.quote)
    }
    @Test func testCorrectionIncludesFailedEvidenceAndPreviousResponse() async throws {
        let input = snapshot(["张三说明明天发送正式报价"])
        var calls = 0
        let transport = FixtureMinutesTransport { _ in
            calls += 1
            let value = try self.content(key: "file:0", quote: calls == 1 ? "张三说明明天发送正式合同" : input.segments[0].text)
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": String(decoding: value, as: UTF8.self)]]]])
        }
        _ = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: input, options: MinutesOptions())
        #expect(calls == 2)
        let request = try #require(transport.requests.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 4)
        #expect(messages[2]["role"] == "assistant")
        let feedbackText = try #require(messages.last?["content"])
        let feedback = try #require(try JSONSerialization.jsonObject(with: Data(feedbackText.utf8)) as? [String: Any])
        let invalid = try #require(feedback["invalidEvidence"] as? [[String: String]])
        #expect(invalid == [["segmentKey": "file:0", "quote": "张三说明明天发送正式合同", "sourceText": input.segments[0].text]])
    }
    @Test func testCorrectionReceivesAllInvalidCitationsAtOnce() async throws {
        let input = snapshot(["所以机器人也是我们将来推广的产品", "现在来说我们有四个产品线"])
        var calls = 0
        let transport = FixtureMinutesTransport { _ in
            calls += 1
            let quotes = calls == 1 ? ["那机器人也是我们将来推广的产品", "现在基本来说我们有四个产品线"] : input.segments.map(\.text)
            let root: [String: Any] = ["overviewZH": "产品讨论", "topics": [], "openQuestions": [], "actions": [], "decisions": quotes.enumerated().map { index, quote in
                ["textZH": "讨论产品", "evidence": [["segmentKey": "file:\(index)", "quote": quote]]] as [String: Any]
            }]
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)]]]])
        }
        let result = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: input, options: MinutesOptions())
        #expect(calls == 2)
        #expect(result.document.decisions.count == 2)
        let data = try #require(transport.requests.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        let feedbackText = try #require(messages.last?["content"])
        let feedback = try #require(try JSONSerialization.jsonObject(with: Data(feedbackText.utf8)) as? [String: Any])
        let invalid = try #require(feedback["invalidEvidence"] as? [[String: String]])
        #expect(invalid.count == 2)
        #expect(invalid.map { $0["sourceText"]! } == input.segments.map(\.text))
    }
}
