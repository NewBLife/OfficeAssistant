import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

final class FixtureMinutesTransport: ProviderTransport {
    var requests: [URLRequest] = []
    var respond: (URLRequest) throws -> Data
    init(_ respond: @escaping (URLRequest) throws -> Data) { self.respond = respond }
    func data(for request: URLRequest) async throws -> Data { requests.append(request); return try respond(request) }
    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
}
@MainActor @Suite struct MinutesProtocolTests {
    func snapshot() -> MinutesSnapshot {
        let meeting = MeetingSession(title: "测试", configuration: AIConfiguration())
        var final = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)); final.finalText = "张三发送报价"
        var partial = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 1)); partial.partialText = "临时字幕不能发送"
        var other = TranscriptSegment(id: SegmentID(meetingID: UUID(), source: .file, sequence: 0)); other.finalText = "其他会议不能发送"
        return MinutesSnapshot(meeting: meeting, segments: [final, partial, other])
    }
    @Test(arguments: [AIProvider.openai, .deepseek, .siliconflow]) func testOnlySelectedCredentialAndFinalSource(_ provider: AIProvider) throws {
        let service = MinutesGenerator(credentials: TestCredentials(), transport: TestTransport())
        let request = try service.request(snapshot: snapshot(), options: MinutesOptions(provider: provider, model: provider.defaultTextModel))
        #expect(request.url?.host == provider.baseURL?.host)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["response_format"] != nil)
        #expect((body[provider == .openai ? "max_completion_tokens" : "max_tokens"] as? Int) == 6000)
        let raw = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!raw.contains("临时字幕不能发送")); #expect(!raw.contains("其他会议不能发送")); #expect(!raw.contains("fake-openai")); #expect(body["tools"] == nil)
    }
    @Test(arguments: ["negated", "completed", "question", "hypothetical"]) func testNonActionsExcluded(_ intent: String) throws {
        let snap = snapshot()
        let root: [String: Any] = ["overviewZH": "记录", "overviewJA": NSNull(), "topics": [], "decisions": [], "openQuestions": [], "actions": [["titleZH": "发送报价", "titleJA": NSNull(), "owner": NSNull(), "dueText": NSNull(), "intent": intent, "evidence": [["segmentKey": "file:0", "quote": snap.segments[0].text]]]]]
        #expect(try MinutesGenerator.decodeContent(JSONSerialization.data(withJSONObject: root), snapshot: snap, options: MinutesOptions()).candidates.isEmpty)
    }
    @Test func testLongTranscriptPreservesTailAndNoAuthRetry() async throws {
        let meeting = MeetingSession(title: "长会议", configuration: AIConfiguration())
        let segments = (0..<3).map { n in var item = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: n)); item.finalText = String(repeating: "あ", count: 11990) + "TAIL\(n)"; return item }
        let transport = FixtureMinutesTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let payload = try JSONSerialization.jsonObject(with: Data((messages[1]["content"] as! String).utf8)) as! [String: Any]
            let segment = (payload["segments"] as! [[String: String]])[0]
            let quote = String(segment["text"]!.suffix(7))
            let root: [String: Any] = ["overviewZH": quote, "overviewJA": NSNull(), "topics": [], "decisions": [["textZH": quote, "textJA": NSNull(), "evidence": [["segmentKey": segment["segmentKey"]!, "quote": quote]]]], "openQuestions": [], "actions": []]
            let content = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        }
        let result = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: MinutesSnapshot(meeting: meeting, segments: segments), options: MinutesOptions())
        #expect(transport.requests.count == 3); #expect(result.document.overviewZH.contains("TAIL2")); #expect(result.document.decisions.count == 3)
        let failing = FixtureMinutesTransport { _ in throw ProviderHTTPError(status: 403) }
        do { _ = try await MinutesGenerator(credentials: TestCredentials(), transport: failing).generate(snapshot: snapshot(), options: MinutesOptions()); Issue.record("权限失败应停止") } catch {}
        #expect(failing.requests.count == 1)
    }
    @Test(arguments: ["length", "blank", "refusal"]) func testIncompleteResultsFail(_ mode: String) async throws {
        let transport = FixtureMinutesTransport { _ in
            try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": mode == "length" ? "length" : "stop", "message": mode == "refusal" ? ["refusal": "不处理"] : ["content": "  "]]]])
        }
        do { _ = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: snapshot(), options: MinutesOptions()); Issue.record("不完整结果不应成功") } catch {}
        #expect(transport.requests.count == 1)
    }
    @Test func testEvidenceMismatchRetriesWithCorrectionAndKeepsStrictValidation() async throws {
        let snap = snapshot()
        var responses = 0
        let transport = FixtureMinutesTransport { _ in
            responses += 1
            let quote = responses == 1 ? "错误引文" : snap.segments[0].text
            let root: [String: Any] = ["overviewZH": "记录", "overviewJA": NSNull(), "topics": [], "decisions": [["textZH": "报价", "textJA": NSNull(), "evidence": [["segmentKey": "file:0", "quote": quote]]]], "openQuestions": [], "actions": []]
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)]]]])
        }
        let result = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: snap, options: MinutesOptions())
        #expect(transport.requests.count == 2)
        #expect(result.document.decisions.first?.evidence.first?.quote == snap.segments[0].text)
        let retryBody = try #require(try JSONSerialization.jsonObject(with: transport.requests[1].httpBody!) as? [String: Any])
        let messages = try #require(retryBody["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("上次输出的原文引文校验失败") == true)
    }
}

extension MinutesProtocolTests {
    @Test func testLaterCancellationCannotLeaveBatchAddableChunkAction() async throws {
        let meeting = MeetingSession(title: "跨段取消", configuration: AIConfiguration())
        var first = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)); first.finalText = "张三发送报价" + String(repeating: "。", count: 11994)
        var last = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 1)); last.finalText = "刚才安排取消，张三不用发送报价"
        let transport = FixtureMinutesTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let payload = try JSONSerialization.jsonObject(with: Data((messages[1]["content"] as! String).utf8)) as! [String: Any]
            let source = (payload["segments"] as! [[String: String]])[0]
            let intent = source["segmentKey"] == "file:0" ? "assignment" : "negated"
            let quote = intent == "assignment" ? "张三发送报价" : last.text
            let root: [String: Any] = ["overviewZH": "测试", "overviewJA": NSNull(), "topics": [], "decisions": [], "openQuestions": [], "actions": [["titleZH": "发送报价", "titleJA": NSNull(), "owner": "张三", "dueText": NSNull(), "intent": intent, "evidence": [["segmentKey": source["segmentKey"]!, "quote": quote]]]]]
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)]]]])
        }
        let result = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: MinutesSnapshot(meeting: meeting, segments: [first, last]), options: MinutesOptions())
        #expect(transport.requests.count == 2)
        #expect(result.candidates.allSatisfy { $0.clarifications.contains(.commitment) && $0.clarifications.contains(.crossChunkReview) })
    }
}
