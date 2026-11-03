import Foundation
import Testing
@testable import OfficeCore

struct MeetingDeadlineTests {
    @Test func testCrossMidnightAndJapaneseAndMissingDate() throws {
        let formatter = ISO8601DateFormatter()
        let reference = try #require(formatter.date(from: "2026-11-03T23:59:00+08:00"))
        let one = MeetingDeadlineResolver.resolve("明天下午三点", reference: reference, evidenceOffset: 0, timeZoneID: "Asia/Shanghai")
        let two = MeetingDeadlineResolver.resolve("明天下午三点", reference: reference, evidenceOffset: 120, timeZoneID: "Asia/Shanghai")
        #expect(one.dueAt == formatter.date(from: "2026-11-04T15:00:00+08:00"))
        #expect(two.dueAt == formatter.date(from: "2026-11-05T15:00:00+08:00"))
        #expect(MeetingDeadlineResolver.resolve("明日の午後3時", reference: reference, evidenceOffset: 0, timeZoneID: "Asia/Shanghai").dueAt == one.dueAt)
        #expect(MeetingDeadlineResolver.resolve("明天下午三点", reference: nil, evidenceOffset: 0, timeZoneID: "Asia/Shanghai").dueAt == nil)
        #expect(MeetingDeadlineResolver.resolve("明天下午", reference: reference, evidenceOffset: 0, timeZoneID: "Asia/Shanghai").dueAt == nil)
    }
}
