import Foundation

public struct DeadlineResolution: Sendable {
    public var dueAt: Date?; public var needsClarification: Bool; public var missingMeetingDate: Bool
}
public enum MeetingDeadlineResolver {
    public static func resolve(_ text: String?, reference: Date?, evidenceOffset: Double, timeZoneID: String) -> DeadlineResolution {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .init(dueAt: nil, needsClarification: false, missingMeetingDate: false) }
        guard let reference, evidenceOffset.isFinite, evidenceOffset >= 0 else { return .init(dueAt: nil, needsClarification: true, missingMeetingDate: true) }
        var value = text
        for (ja, zh) in [("明後日", "后天"), ("明日", "明天"), ("今日", "今天"), ("午後", "下午"), ("午前", "上午")] { value = value.replacingOccurrences(of: ja, with: zh) }
        for (ja, zh) in zip(["月", "火", "水", "木", "金", "土", "日"], ["一", "二", "三", "四", "五", "六", "日"]) {
            for suffix in ["曜日", "曜"] {
                for middle in ["", "の"] {
                    value = value.replacingOccurrences(of: "来週\(middle)\(ja)\(suffix)", with: "下周\(zh)")
                    value = value.replacingOccurrences(of: "今週\(middle)\(ja)\(suffix)", with: "本周\(zh)")
                }
            }
        }
        value = value.replacingOccurrences(of: "の", with: "").replacingOccurrences(of: "時", with: "点")
        let result = QuickEntryParser.parse(value, reference: reference.addingTimeInterval(evidenceOffset), timeZoneID: timeZoneID)
        return .init(dueAt: result.dueAt, needsClarification: result.dueAt == nil, missingMeetingDate: false)
    }
}
