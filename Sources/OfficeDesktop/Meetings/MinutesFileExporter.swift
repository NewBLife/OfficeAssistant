import Foundation
import AppKit
import UniformTypeIdentifiers
import OfficeCore

@MainActor public protocol MinutesSaveDestinationChoosing {
    func choose(suggestedName: String, format: MinutesExportFormat) async throws -> URL?
}
@MainActor public struct NativeMinutesDestination: MinutesSaveDestinationChoosing {
    public init() {}
    public func choose(suggestedName: String, format: MinutesExportFormat) async throws -> URL? {
        let panel = NSSavePanel(); panel.title = "导出会议纪要"; panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]; panel.canCreateDirectories = true
        let result = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        return result == .OK ? panel.url : nil
    }
}
@MainActor public final class MinutesFileExporter {
    private let destination: any MinutesSaveDestinationChoosing
    public init(destination: (any MinutesSaveDestinationChoosing)? = nil) { self.destination = destination ?? NativeMinutesDestination() }
    public func export(text: String, suggestedName: String, format: MinutesExportFormat) async throws -> URL? {
        let safe = String(suggestedName.filter { !"/\\:".contains($0) && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(100))
        guard let url = try await destination.choose(suggestedName: (safe.isEmpty ? "会议纪要" : safe) + "." + format.fileExtension, format: format) else { return nil }
        try write(text, to: url); return url
    }
    func write(_ text: String, to url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try Data(text.utf8).write(to: url, options: .atomic) }
        catch { throw OfficeError.invalid("纪要未能保存，请检查保存位置和磁盘空间。原有文件保持不变。") }
    }
}
