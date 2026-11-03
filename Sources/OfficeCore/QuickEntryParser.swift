import Foundation

public struct QuickEntrySuggestion {
    public let title: String
    public let dueAt: Date?
    public let dueText: String?
    public let needsClarification: Bool
}
public enum QuickEntryParser {
    public static func parse(_ input: String, reference: Date, timeZoneID: String) -> QuickEntrySuggestion {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = "[0-9零〇一二三四五六七八九十两]"
        let pattern = "(今天|明天|后天|(?:本周|这周|下周)(?:周|星期)?[一二三四五六日天])\\s*(上午|下午|晚上|中午|早上|凌晨)?\\s*(\(digits){1,3})(?:(?:点|时)(半|\(digits){1,3}分?)?|[:：]([0-9]{1,2}))"
        let regex = try! NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(text.startIndex..., in: text)
        let uncertain = text.range(of: "今天|明天|后天|周[一二三四五六日天]|星期|[0-9]+月|尽快|下午|上午|晚上", options: .regularExpression) != nil
        func unresolved() -> QuickEntrySuggestion {
            QuickEntrySuggestion(title: text, dueAt: nil, dueText: uncertain ? text : nil, needsClarification: uncertain)
        }
        guard let match = regex.firstMatch(in: text, range: fullRange), let zone = TimeZone(identifier: timeZoneID) else { return unresolved() }
        func capture(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
        guard var hour = number(capture(3)) else { return unresolved() }
        let minuteText = capture(4).replacingOccurrences(of: "分", with: "")
        let minute = minuteText == "半" ? 30 : number(minuteText.isEmpty ? (capture(5).isEmpty ? "0" : capture(5)) : minuteText)
        guard let minute, (0...23).contains(hour), (0...59).contains(minute) else { return unresolved() }
        switch capture(2) {
        case "下午", "晚上": if (1...11).contains(hour) { hour += 12 }
        case "中午": if (1...2).contains(hour) { hour += 12 }
        case "上午", "早上", "凌晨": if hour >= 12 { return unresolved() }
        default: break
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; calendar.firstWeekday = 2
        let dayText = capture(1)
        var day = calendar.startOfDay(for: reference)
        if dayText == "明天" || dayText == "后天" {
            day = calendar.date(byAdding: .day, value: dayText == "明天" ? 1 : 2, to: day)!
        } else if dayText != "今天" {
            let weekday = ["一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6][String(dayText.suffix(1))]!
            let todayIndex = (calendar.component(.weekday, from: day) + 5) % 7
            day = calendar.date(byAdding: .day, value: weekday - todayIndex + (dayText.hasPrefix("下周") ? 7 : 0), to: day)!
        }
        guard let due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
              calendar.component(.hour, from: due) == hour, calendar.component(.minute, from: due) == minute else { return unresolved() }
        let range = Range(match.range, in: text)!
        let remainder = text.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return QuickEntrySuggestion(title: remainder.isEmpty ? text : remainder, dueAt: due, dueText: String(text[range]), needsClarification: false)
    }
    private static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let values: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text.count == 1 { return text == "十" ? 10 : text.first.flatMap { values[$0] } }
        let parts = text.split(separator: "十", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let tens = parts[0].isEmpty ? 1 : (parts[0].count == 1 ? parts[0].first.flatMap { values[$0] } : nil)
        let ones = parts[1].isEmpty ? 0 : (parts[1].count == 1 ? parts[1].first.flatMap { values[$0] } : nil)
        guard let tens, let ones else { return nil }; return tens * 10 + ones
    }
}
