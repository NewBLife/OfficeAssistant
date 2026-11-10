import Foundation

public enum TaskCSVRenderer {
    public static func render(items: [TaskItem], groups: [WorkGroup]?, displayTimeZoneID: String) throws -> String {
        guard let displayZone = TimeZone(identifier: displayTimeZoneID) else {
            throw OfficeError.invalid("导出时区无效。")
        }
        func timestamp(_ value: Date?, zone: TimeZone) -> String {
            guard let value else { return "" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: value)
        }
        func cell(_ value: String) -> String {
            let first = value.first { !$0.isWhitespace }
            let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let headers = ["标题", "备注", "负责人", "状态", "截止时间", "时区", "重复", "分组", "创建时间", "完成时间"]
        var rows = [headers.map(cell).joined(separator: ",")]
        for item in items {
            guard let taskZone = TimeZone(identifier: item.timeZoneID) else {
                throw OfficeError.invalid("待办时区无效，无法导出。")
            }
            let repeatLabel: String
            if item.repeatRule == .monthly, let day = item.monthlyDay { repeatLabel = "每月 \(day) 号" }
            else { repeatLabel = item.repeatRule.label }
            let values = [item.title, item.notes, item.owner ?? "", item.status.label,
                          item.dueAt.map { timestamp($0, zone: taskZone) } ?? item.dueText ?? "",
                          item.timeZoneID, repeatLabel, groups.map { GroupRules.path(item.groupID, groups: $0) } ?? "分组暂时不可用",
                          timestamp(item.createdAt, zone: displayZone), timestamp(item.completedAt, zone: displayZone)]
            rows.append(values.map(cell).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
