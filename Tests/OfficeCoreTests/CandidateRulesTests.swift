import Foundation
import Testing
@testable import OfficeCore

struct CandidateRulesTests {
    @Test func testStableIDsAcceptedAndRepeatedDifferentSource() {
        let meetingID = UUID()
        let ref = EvidenceReference(segmentID: SegmentID(meetingID: meetingID, source: .file, sequence: 0), revision: 0, quote: "发送报价", startUTF16: 0, lengthUTF16: 4)
        var old = ActionCandidate(meetingID: meetingID, titleZH: "发送报价", evidence: [ref]); old.owner = "张三"
        var same = old; same.id = UUID()
        #expect(CandidateRules.reconcile(existing: [old], proposed: [same], linkedTasks: []).map(\.id) == [old.id])
        old.reviewState = .accepted; old.acceptedTaskID = UUID()
        #expect(CandidateRules.reconcile(existing: [old], proposed: [same], linkedTasks: []) == [old])
        same.evidence[0].segmentID = SegmentID(meetingID: meetingID, source: .file, sequence: 1)
        let repeated = CandidateRules.reconcile(existing: [old], proposed: [same], linkedTasks: [])
        #expect(repeated.count == 2); #expect(repeated[1].clarifications.contains(.possibleDuplicate))
        var edited = old; edited.titleZH = "完全改写后的验收事项"
        same.evidence = old.evidence
        let regenerated = CandidateRules.reconcile(existing: [edited], proposed: [same], linkedTasks: [], replaceProposals: true)
        #expect(regenerated.count == 2)
        #expect(regenerated.first { $0.id == same.id }?.clarifications.contains(.possibleDuplicate) == true)
    }
}
