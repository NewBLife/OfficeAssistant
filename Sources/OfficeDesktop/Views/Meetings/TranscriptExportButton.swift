import SwiftUI
import OfficeCore

@MainActor struct TranscriptExportButton: View {
    let meeting: MeetingSession
    let segments: [TranscriptSegment]
    let timeZoneID: String
    @State private var exporting = false
    @State private var error: String?

    var body: some View {
        Menu {
            ForEach(MinutesExportFormat.allCases) { format in
                Button(LocalizedStringKey(format.label)) { export(format) }
            }
        } label: { Label("导出转写", systemImage: "square.and.arrow.up") }
            .fixedSize()
            .disabled(exporting || !segments.contains { $0.id.meetingID == meeting.id && !($0.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .alert("转写导出未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func export(_ format: MinutesExportFormat) {
        // Render a consistent snapshot before showing the save panel, even while recording.
        do {
            let text = try TranscriptExportRenderer.render(meeting: meeting, segments: segments, format: format, timeZoneID: timeZoneID)
            let filename = meeting.title + "-会议转写"
            exporting = true
            Task {
                defer { exporting = false }
                do { _ = try await MinutesFileExporter(kind: .transcript).export(text: text, suggestedName: filename, format: format) }
                catch { self.error = ProviderNetwork.safeError(error) }
            }
        } catch { self.error = ProviderNetwork.safeError(error) }
    }
}
