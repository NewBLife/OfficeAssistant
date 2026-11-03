import Foundation

public enum MinutesExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown, plainText
    public var id: Self { self }
    public var label: String { self == .markdown ? "Markdown (.md)" : "纯文本 (.txt)" }
    public var fileExtension: String { self == .markdown ? "md" : "txt" }
}
public enum MinutesExportRenderer {
    public static func render(document: MinutesDocument, candidates: [ActionCandidate], linkedTasks: [TaskItem], language: MinutesLanguage, format: MinutesExportFormat) throws -> String {
        if language == .chineseJapanese && (document.overviewJA ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OfficeError.invalid("当前没有双语纪要，请先生成双语版本；导出不会自动调用翻译。") }
        let markdown = format == .markdown
        func clean(_ text: String) -> String {
            guard markdown else { return text }
            let symbols = "\\`*_{}[]()<>#+-.!|~"
            return text.map { symbols.contains($0) ? "\\\($0)" : String($0) }.joined()
        }
        func heading(_ value: String, level: Int = 2) -> String { markdown ? String(repeating: "#", count: level) + " " + clean(value) : value }
        func date(_ value: Date?) -> String {
            guard let value else { return "未确定" }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: document.options.timeZoneID); formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: value) + " (\(document.options.timeZoneID))"
        }
        func evidence(_ refs: [EvidenceReference]) -> [String] {
            refs.map { ref in
                let seconds = max(0, Int(ref.sourceStartSeconds)); let time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                return "  来源：\(ref.segmentID.source.label) \(time)；\(clean(ref.quote))"
            }
        }
        var lines = [heading(document.meetingTitle, level: 1), "", "会议时间：\(date(document.options.referenceDate))", "参会备注：\(clean(document.participantsNote.isEmpty ? "未填写" : document.participantsNote))", "纪要版本：\(document.revision)\(document.editedByUser ? "（人工校对）" : "")", "", heading("会议概述"), clean(document.overviewZH)]
        if language == .chineseJapanese, let ja = document.overviewJA { lines += [clean(ja)] }
        for (title, values) in [("议题摘要", document.topics), ("明确决定", document.decisions), ("未解决问题", document.openQuestions)] {
            lines += ["", heading(title)]
            if values.isEmpty { lines.append("无已记录内容") }
            for point in values {
                lines.append("\(markdown ? "- " : "• ")\(clean(point.textZH))")
                if language == .chineseJapanese, let ja = point.textJA { lines.append("  " + clean(ja)) }
                lines += evidence(point.evidence)
            }
        }
        lines += ["", heading("行动项")]
        let tasks = linkedTasks.filter { ($0.meetingLinks ?? []).contains { $0.meetingID == document.meetingID } }
        var shown: Set<UUID> = []
        for item in candidates where item.meetingID == document.meetingID && item.reviewState != .ignored {
            let task = tasks.first { ($0.meetingActionReceipts ?? []).contains { $0.meetingID == document.meetingID && $0.candidateID == item.id } }
            if let task { shown.insert(task.id) }
            let title = task?.title ?? item.titleZH
            let status = task?.status.label ?? (item.reviewState == .accepted ? "已加入（任务未关联或已删除）" : "待确认，尚未加入待办")
            let owner = task.map { $0.owner } ?? item.owner
            let dueAt = task.map { $0.dueAt } ?? item.dueAt
            let dueText = task.map { $0.dueText } ?? item.dueText
            lines += ["\(markdown ? "- " : "• ")\(clean(title)) [\(status)]", "  负责人：\(clean(owner ?? "未指定"))；截止：\(date(dueAt))"]
            if let due = dueText { lines.append("  原始时间：" + clean(due)) }
            if language == .chineseJapanese {
                // A task/candidate title is editable independently of the generated Japanese title.
                lines.append("  " + clean(item.titleJA.map { "原始日文（修改后需重新核对）：" + $0 } ?? "此行动项暂无日文版本"))
            }
            lines += evidence(item.evidence)
        }
        for task in tasks where !shown.contains(task.id) {
            lines += ["\(markdown ? "- " : "• ")\(clean(task.title)) [\(task.status.label)]", "  负责人：\(clean(task.owner ?? "未指定"))；截止：\(date(task.dueAt))"]
            lines += evidence((task.meetingLinks ?? []).filter { $0.meetingID == document.meetingID }.flatMap(\.evidence))
        }
        if candidates.filter({ $0.meetingID == document.meetingID && $0.reviewState != .ignored }).isEmpty && tasks.isEmpty { lines.append("无已记录行动项") }
        return lines.joined(separator: "\n") + "\n"
    }
}
