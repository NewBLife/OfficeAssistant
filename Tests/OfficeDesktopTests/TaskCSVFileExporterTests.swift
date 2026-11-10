import Foundation
import Testing
@testable import OfficeDesktop

@MainActor private struct FixedTaskCSVSaveDestination: TaskCSVSaveDestinationChoosing {
    let url: URL?
    func choose(suggestedName: String) async -> URL? { url }
}

@MainActor struct TaskCSVFileExporterTests {
    @Test func writesExcelCompatibleUTF8AndHandlesCancellation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = "\"标题\"\r\n\"中文待办\"\r\n"
        let written = try await TaskCSVFileExporter(destination: FixedTaskCSVSaveDestination(url: url)).export(csv: csv, suggestedName: "待办")
        #expect(written == url)
        #expect(try Data(contentsOf: url) == Data(("\u{FEFF}" + csv).utf8))
        let cancelled = try await TaskCSVFileExporter(destination: FixedTaskCSVSaveDestination(url: nil)).export(csv: csv, suggestedName: "待办")
        #expect(cancelled == nil)
    }
}
