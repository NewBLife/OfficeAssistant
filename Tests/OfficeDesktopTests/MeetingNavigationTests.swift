import Foundation
import Testing
import OfficeCore

struct MeetingNavigationTests {
    @Test func testOtherActiveMeetingCannotBeReplaced() throws {
        let active = UUID(); let other = UUID()
        try MeetingNavigationPolicy.validate(target: active, available: [active, other], activeMeetingID: active)
        #expect(throws: (any Error).self) { try MeetingNavigationPolicy.validate(target: other, available: [active, other], activeMeetingID: active) }
        #expect(throws: (any Error).self) { try MeetingNavigationPolicy.validate(target: UUID(), available: [active], activeMeetingID: nil) }
    }
}
