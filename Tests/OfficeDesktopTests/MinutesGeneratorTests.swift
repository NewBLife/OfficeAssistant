import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct MinutesGeneratorTests {
    @Test func testValidEvidenceAndUnknownOwner() throws {
        let meeting = MeetingSession(title: "样例", configuration: AIConfiguration())
        var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: 0)); segment.finalText = "我明天下午三点发送报价。"
        let snapshot = MinutesSnapshot(meeting: meeting, segments: [segment])
        let object: [String: Any] = ["overviewZH": "安排报价", "overviewJA": NSNull(), "topics": [], "decisions": [], "openQuestions": [], "actions": [["titleZH": "发送报价", "titleJA": NSNull(), "owner": "我", "dueText": "明天下午三点", "intent": "commitment", "evidence": [["segmentKey": "file:0", "quote": segment.text]]]]]
        let value = try MinutesGenerator.decodeContent(JSONSerialization.data(withJSONObject: object), snapshot: snapshot, options: MinutesOptions())
        #expect(value.candidates.count == 1); #expect(value.candidates[0].owner == nil); #expect(value.candidates[0].dueAt == nil)
        #expect(value.candidates[0].evidence.first?.segmentID == segment.id)
        var wrong = object; wrong["actions"] = [["titleZH": "伪造", "titleJA": NSNull(), "owner": NSNull(), "dueText": NSNull(), "intent": "assignment", "evidence": [["segmentKey": "file:9", "quote": "不存在"]]]]
        #expect(throws: (any Error).self) { try MinutesGenerator.decodeContent(JSONSerialization.data(withJSONObject: wrong), snapshot: snapshot, options: MinutesOptions()) }
    }
}
