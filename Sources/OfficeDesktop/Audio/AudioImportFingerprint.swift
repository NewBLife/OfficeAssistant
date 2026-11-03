import Foundation
import CryptoKit
import OfficeCore

public enum AudioImportFingerprint {
    // Compare size and both edges without loading a long recording into memory.
    public static func read(_ url: URL) throws -> AudioImportIdentity {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        var edges = try file.read(upToCount: 65536) ?? Data()
        try file.seek(toOffset: size > 65536 ? size - 65536 : 0)
        edges.append(try file.read(upToCount: 65536) ?? Data())
        return AudioImportIdentity(size: size, edgeSHA256: SHA256.hash(data: edges).map { String(format: "%02x", $0) }.joined())
    }
}
