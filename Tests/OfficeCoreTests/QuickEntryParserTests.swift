import Foundation
import Testing
@testable import OfficeCore

struct QuickEntryParserTests {
    let reference = date("2026-11-02T22:00:00+08:00")
    @Test func testTomorrowThreePM() {
        let result = QuickEntryParser.parse("明天下午三点交周报", reference: reference, timeZoneID: "Asia/Shanghai")
        #expect(result.dueAt == date("2026-11-03T15:00:00+08:00"))
        #expect(result.title == "交周报")
        #expect(!result.needsClarification)
    }
    @Test func testAfterMidnightUsesReferenceDay() {
        let result = QuickEntryParser.parse("明天09:30开会", reference: date("2026-11-03T00:01:00+08:00"), timeZoneID: "Asia/Shanghai")
        #expect(result.dueAt == date("2026-11-04T09:30:00+08:00"))
    }
    @Test func testAmbiguousAfternoonNotInvented() {
        let result = QuickEntryParser.parse("明天下午联系客户", reference: reference, timeZoneID: "Asia/Shanghai")
        #expect(result.dueAt == nil); #expect(result.needsClarification)
        #expect(result.dueText == "明天下午联系客户")
    }
    @Test func testInvalidClockNotNormalized() {
        let result = QuickEntryParser.parse("明天25:90提交", reference: reference, timeZoneID: "Asia/Shanghai")
        #expect(result.dueAt == nil); #expect(result.needsClarification)
    }
    @Test func testOriginalTextSurvivesUnknownDate() {
        let result = QuickEntryParser.parse("周五尽快回复客户", reference: reference, timeZoneID: "Asia/Shanghai")
        #expect(result.title == "周五尽快回复客户"); #expect(result.dueAt == nil)
        #expect(result.needsClarification)
    }
    @Test func testExplicitNextWeekAndHalfHour() {
        let result = QuickEntryParser.parse("下周五上午九点半交方案", reference: reference, timeZoneID: "Asia/Shanghai")
        #expect(result.dueAt == date("2026-11-13T09:30:00+08:00"))
    }
    @Test func testPlainTextHasNoInventedTime() {
        let result = QuickEntryParser.parse("整理文件", reference: reference, timeZoneID: "Asia/Shanghai")
        #expect(result.dueAt == nil); #expect(!result.needsClarification)
    }
}
