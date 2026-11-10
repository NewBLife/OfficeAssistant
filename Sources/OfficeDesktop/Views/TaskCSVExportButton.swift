import SwiftUI
import OfficeCore

@MainActor struct TaskCSVExportButton: View {
    let items: [TaskItem]
    let groups: [OfficeCore.WorkGroup]?
    let displayTimeZoneID: String
    let suggestedName: String
    @State private var exporting = false
    @State private var error: String?

    var body: some View {
        Button {
            do {
                let csv = try TaskCSVRenderer.render(items: items, groups: groups, displayTimeZoneID: displayTimeZoneID)
                exporting = true
                Task {
                    defer { exporting = false }
                    do { _ = try await TaskCSVFileExporter().export(csv: csv, suggestedName: suggestedName) }
                    catch { self.error = error.localizedDescription }
                }
            } catch { self.error = error.localizedDescription }
        } label: { Label("导出待办", systemImage: "square.and.arrow.up") }
            .disabled(exporting || items.isEmpty)
            .alert("待办导出未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
    }
}
