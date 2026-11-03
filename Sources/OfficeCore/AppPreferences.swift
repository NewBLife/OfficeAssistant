import Foundation

public struct AppPreferences: Codable, Equatable, Sendable {
    public var displayName = ""
    public var timeZoneID = "Asia/Shanghai"
    public var dailySummaryEnabled = true
    public var summaryHour = 9
    public var summaryMinute = 0
    public init() {}
    public func validate() throws {
        guard TimeZone(identifier: timeZoneID) != nil, (0...23).contains(summaryHour), (0...59).contains(summaryMinute) else {
            throw OfficeError.invalid("请填写有效的时区和汇总时间。")
        }
    }
}
