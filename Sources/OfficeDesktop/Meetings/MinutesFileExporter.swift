import Foundation
import AppKit
import UniformTypeIdentifiers
import OfficeCore

public enum MeetingTextExportKind {
    case minutes, transcript
    var title: String { self == .minutes ? "导出会议纪要" : "导出转写" }
    var fallbackName: String { self == .minutes ? "会议纪要" : "会议转写" }
    var failureMessage: String {
        self == .minutes ? "纪要未能保存，请检查保存位置和磁盘空间。原有文件保持不变。" : "转写未能保存，请检查保存位置和磁盘空间。原有文件保持不变。"
    }
}
@MainActor public protocol MinutesSaveDestinationChoosing {
    func choose(suggestedName: String, format: MinutesExportFormat) async throws -> URL?
}
@MainActor public struct NativeMinutesDestination: MinutesSaveDestinationChoosing {
    private let title: String
    public init(title: String = "导出会议纪要") { self.title = title }
    public func choose(suggestedName: String, format: MinutesExportFormat) async throws -> URL? {
        let panel = NSSavePanel(); panel.title = title; panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]; panel.canCreateDirectories = true
        let result = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        return result == .OK ? panel.url : nil
    }
}
@MainActor public final class MinutesFileExporter {
    private let destination: any MinutesSaveDestinationChoosing
    private let kind: MeetingTextExportKind
    public init(destination: (any MinutesSaveDestinationChoosing)? = nil, kind: MeetingTextExportKind = .minutes) {
        self.kind = kind; self.destination = destination ?? NativeMinutesDestination(title: kind.title)
    }
    public func export(text: String, suggestedName: String, format: MinutesExportFormat) async throws -> URL? {
        let safe = String(suggestedName.filter { !"/\\:".contains($0) && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(100))
        guard let url = try await destination.choose(suggestedName: (safe.isEmpty ? kind.fallbackName : safe) + "." + format.fileExtension, format: format) else { return nil }
        try write(text, to: url); return url
    }
    func write(_ text: String, to url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try Data(text.utf8).write(to: url, options: .atomic) }
        catch { throw OfficeError.invalid(kind.failureMessage) }
    }
}
