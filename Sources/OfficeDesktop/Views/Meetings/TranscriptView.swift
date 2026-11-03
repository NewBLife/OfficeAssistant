import SwiftUI
import OfficeCore

@MainActor struct TranscriptView: View {
    let controller: MeetingSessionController
    let settings: AISettingsStore
    var focus: EvidenceReference? = nil
    @State private var editing: TranscriptSegment?
    @State private var error: String?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(controller.segments) { segment in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(segment.id.source.label, systemImage: segment.id.source == .microphone ? "mic" : "waveform")
                        Text(time(segment.sourceStartSeconds)).monospacedDigit()
                        if segment.finalText == nil { Text("识别中").foregroundStyle(.orange) }
                        Spacer()
                        if segment.finalText != nil {
                            Button("编辑原文") { editing = segment }.buttonStyle(.link)
                            if shouldTranslate { Button("重新翻译") { retry(segment.id) }.buttonStyle(.link).help("保留本会议的服务与翻译方向，使用 AI 服务中这家服务当前保存的翻译模型。") }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) { Text("原文").font(.caption).foregroundStyle(.secondary); Text(segment.text.isEmpty ? "等待识别…" : segment.text).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading)
                        if shouldTranslate {
                          Divider()
                          VStack(alignment: .leading, spacing: 6) {
                            Text("译文").font(.caption).foregroundStyle(.secondary)
                            Text(segment.translatedText.isEmpty ? (segment.translationState == .failed ? "翻译失败，可重新翻译" : (segment.finalText == nil ? "等待原文定稿" : "等待翻译…")) : segment.translatedText).foregroundStyle(segment.translatedText.isEmpty ? .secondary : .primary).textSelection(.enabled)
                            if let error = segment.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                            if segment.translationState == .processing { ProgressView().controlSize(.small) }
                          }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(focus?.segmentID == segment.id ? Color.accentColor : Color.clear, lineWidth: 2)).id(segment.id)
            }
        }.sheet(item: $editing) { segment in
            TranscriptOriginalEditor(text: segment.text, translating: shouldTranslate) { text in
                try controller.retryTranslation(segment.id, editedText: text, textModel: currentTextModel)
            }
        }
        .alert(shouldTranslate ? "未能重新翻译" : "未能保存原文", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private var shouldTranslate: Bool { controller.meeting?.configuration.shouldTranslate ?? true }
    private var currentTextModel: String? {
        guard let provider = controller.meeting?.configuration.translationProvider else { return nil }
        return settings.value.textModels[provider.rawValue]
    }
    private func retry(_ id: SegmentID) { do { try controller.retryTranslation(id, textModel: currentTextModel) } catch { self.error = error.localizedDescription } }
    private func time(_ seconds: Double) -> String { let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60) }
}

@MainActor private struct TranscriptOriginalEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var original: String
    @State private var error: String?
    let translating: Bool
    let save: (String) throws -> Void
    init(text: String, translating: Bool, save: @escaping (String) throws -> Void) {
        _original = State(initialValue: text); self.translating = translating; self.save = save
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("校对原文").font(.title2.bold())
            TextEditor(text: $original).frame(minHeight: 160)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button(translating ? "保存并重新翻译" : "保存原文") {
                    do { try save(original); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540)
    }
}
