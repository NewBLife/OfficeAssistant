import Foundation
import Testing
@testable import OfficeDesktop

@MainActor @Suite struct TaskEditorDefaultsTests {
    @Test(arguments: [
        ("Asia/Shanghai", "2026-11-05T13:00:00Z"),
        ("America/Los_Angeles", "2026-11-06T05:00:00Z")
    ])
    func newTaskDeadlineDefaultsToNinePMInTaskTimeZone(_ timeZoneID: String, _ expectedISO8601: String) throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-05T09:00:00Z")!
        let expected = try #require(ISO8601DateFormatter().date(from: expectedISO8601))
        let deadline = try #require(TaskEditorView.defaultDeadline(now: now, timeZoneID: timeZoneID))
        #expect(deadline == expected)
    }

    @Test func invalidTimeZoneHasNoDefaultDeadline() {
        #expect(TaskEditorView.defaultDeadline(now: Date(), timeZoneID: "Invalid/Zone") == nil)
    }
}
