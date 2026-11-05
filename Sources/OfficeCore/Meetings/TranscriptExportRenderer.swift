import Foundation

public enum TranscriptExportRenderer {
    public static func render(meeting: MeetingSession, segments: [TranscriptSegment], format: MinutesExportFormat, timeZoneID: String = "Asia/Shanghai") throws -> String {
        let finalized = MinutesSnapshot(meeting: meeting, segments: segments).segments
        guard !finalized.isEmpty else { throw OfficeError.invalid("没有已定稿的转写内容，暂时无法导出。") }
        guard let zone = TimeZone(identifier: timeZoneID) else { throw OfficeError.invalid("导出时区无效。") }
        let markdown = format == .markdown
        func clean(_ text: String) -> String {
            guard markdown else { return text }
            return text.map { "\\`*_{}[]()<>#+-.!|~".contains($0) ? "\\\($0)" : String($0) }.joined()
        }
        func time(_ seconds: Double) -> String {
            let value = Int(min(Double(Int.max / 2), max(0, seconds.isFinite ? seconds : 0)))
            return String(format: "%02ld:%02ld:%02ld", value / 3600, (value / 60) % 60, value % 60)
        }
        let date = DateFormatter(); date.locale = Locale(identifier: "zh_CN"); date.timeZone = zone; date.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = [(markdown ? "# " : "") + clean(meeting.title) + " · 会议转写", "",
                     "记录创建时间：\(date.string(from: meeting.startedAt)) (\(timeZoneID))",
                     "会议状态：\(meeting.state.label)", "已定稿片段：\(finalized.count)",
                     "导出范围：导出时已定稿的内容，不含识别中的片段。", ""]
        for segment in finalized {
            var stamp = time(segment.sourceStartSeconds)
            if segment.sourceEndSeconds.isFinite, segment.sourceEndSeconds > segment.sourceStartSeconds {
                stamp += " – " + time(segment.sourceEndSeconds)
            }
            lines += [(markdown ? "## " : "") + "\(stamp) · \(segment.id.source.label)", "", "原文：", clean(segment.finalText!), ""]
            if meeting.configuration.shouldTranslate {
                let label: String
                switch segment.translationState {
                case .completed: label = "译文："
                case .waiting: label = "译文（待翻译）："
                case .processing: label = "译文（翻译中，尚未完成）："
                case .failed: label = "译文（翻译失败）："
                }
                let translation = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无译文" : segment.translatedText
                lines += [label, clean(translation), ""]
            }
        }
        return lines.joined(separator: "\n")
    }
}
