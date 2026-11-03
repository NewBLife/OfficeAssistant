import Foundation
import Testing
@testable import OfficeCore

struct TranscriptReducerTests {
    @Test func testFinalBeatsLatePartialAndDuplicates() {
        let id = SegmentID(meetingID: UUID(), source: .microphone, sequence: 0)
        var values: [TranscriptSegment] = []
        values = TranscriptReducer.apply(.init(id: id, kind: .final, text: "確定"), to: values)
        values = TranscriptReducer.apply(.init(id: id, kind: .partial, text: "古い"), to: values)
        values = TranscriptReducer.apply(.init(id: id, kind: .final, text: "確定"), to: values)
        #expect(values.count == 1); #expect(values[0].finalText == "確定")
    }
    @Test func testOldTranslationRevisionIgnored() {
        let id = SegmentID(meetingID: UUID(), source: .system, sequence: 0)
        var values = TranscriptReducer.apply(.init(id: id, kind: .final, text: "新原文", revision: 2), to: [])
        values = TranscriptReducer.apply(.init(id: id, kind: .translation, text: "旧翻译", revision: 1), to: values)
        #expect(values[0].translatedText.isEmpty)
    }
    @Test func testSourcesNeverShareIdentity() {
        let meeting = UUID()
        let one = SegmentID(meetingID: meeting, source: .microphone, sequence: 0)
        let two = SegmentID(meetingID: meeting, source: .system, sequence: 0)
        let values = TranscriptReducer.apply(.init(id: two, kind: .final, text: "two"), to: TranscriptReducer.apply(.init(id: one, kind: .final, text: "one"), to: []))
        #expect(values.count == 2)
    }
}
