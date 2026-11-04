import Foundation
import AppKit
import OfficeCore

/// Copies archived audio without modifying the recording or the original import.
public struct MeetingAudioFiles: Sendable {
    private let root: URL
    public init(root: URL) { self.root = root }
    public init() throws { root = try AudioArchive.folder() }
    private func file(_ name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw OfficeError.invalid("录音文件路径无效。")
        }
        let url = root.appendingPathComponent(name)
        guard !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else {
            throw OfficeError.invalid("录音文件路径无效。")
        }
        return url
    }
    public func retainImport(_ original: URL, meetingID: UUID) throws -> String {
        let access = original.startAccessingSecurityScopedResource()
        defer { if access { original.stopAccessingSecurityScopedResource() } }
        let name = "\(meetingID)-file-\(UUID()).\(original.pathExtension.isEmpty ? "audio" : original.pathExtension)"
        try FileManager.default.copyItem(at: original, to: file(name)); return name
    }
    @discardableResult public func export(_ names: [String], title: String, to directory: URL) throws -> URL {
        guard !names.isEmpty else { throw OfficeError.invalid("这场会议未保留原始音频，无法导出。") }
        let sources = try names.map { try file($0) }
        guard sources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw OfficeError.invalid("部分本机录音文件已丢失，无法完整导出。")
        }
        let safe = String(title.filter { !"/\\:".contains($0) && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(80))
        let target = directory.appendingPathComponent("\(safe.isEmpty ? "会议音频" : safe)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        do {
            for source in sources { try FileManager.default.copyItem(at: source, to: target.appendingPathComponent(source.lastPathComponent)) }
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        return target
    }
    public func remove(_ names: [String]) throws {
        let urls = try names.map { try file($0) }
        for url in urls where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor enum MeetingAudioExporter {
    static func export(_ meeting: MeetingSession) async throws {
        let panel = NSOpenPanel(); panel.title = "选择音频导出位置"
        panel.prompt = "导出音频"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        let result = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard result == .OK, let directory = panel.url else { return }
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        do {
            let files = try MeetingAudioFiles()
            let folder = try await Task.detached {
                try files.export(meeting.audioFiles, title: meeting.title, to: directory)
            }.value
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch let error as OfficeError { throw error }
        catch { throw OfficeError.invalid("音频导出失败，请检查保存位置和磁盘空间。") }
    }
}
