import AppKit
import Foundation
import UniformTypeIdentifiers
import OfficeCore

@MainActor protocol TaskCSVSaveDestinationChoosing {
    func choose(suggestedName: String) async -> URL?
}

@MainActor struct NativeTaskCSVSaveDestination: TaskCSVSaveDestinationChoosing {
    func choose(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出待办"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        panel.canCreateDirectories = true
        let result = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        return result == .OK ? panel.url : nil
    }
}

@MainActor final class TaskCSVFileExporter {
    private let destination: any TaskCSVSaveDestinationChoosing
    init(destination: (any TaskCSVSaveDestinationChoosing)? = nil) {
        self.destination = destination ?? NativeTaskCSVSaveDestination()
    }
    func export(csv: String, suggestedName: String) async throws -> URL? {
        let safe = String(suggestedName.filter { !"/\\:".contains($0) && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(100))
        guard let url = await destination.choose(suggestedName: (safe.isEmpty ? "待办" : safe) + ".csv") else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try Data(("\u{FEFF}" + csv).utf8).write(to: url, options: .atomic) }
        catch { throw OfficeError.invalid("待办导出失败，请检查保存位置和磁盘空间。原有文件保持不变。") }
        return url
    }
}
