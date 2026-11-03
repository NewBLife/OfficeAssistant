import Foundation
import OfficeCore

public final class AudioArchive {
    public let relativeName: String
    private let handle: FileHandle
    private var count = 0
    private var closed = false
    public init(meetingID: UUID, source: AudioSourceID) throws {
        relativeName = "\(meetingID)-\(source.rawValue)-\(UUID()).wav"
        let folder = try Self.folder()
        let url = folder.appendingPathComponent(relativeName)
        guard FileManager.default.createFile(atPath: url.path, contents: PCMCodec.wav(Data())) else { throw OfficeError.invalid("无法创建本机录音文件。") }
        handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
    }
    public static func folder() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OfficeAssistant/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder
    }
    public func append(_ data: Data) throws {
        guard !closed else { return }
        // Keep individual WAV chunks under the RIFF 32-bit size limit.
        guard count + data.count < 4_000_000_000 else { throw OfficeError.invalid("单个录音文件已接近格式上限，请结束后新建会议。") }
        try handle.write(contentsOf: data); count += data.count
    }
    public func close() throws {
        guard !closed else { return }; closed = true
        try handle.seek(toOffset: 4); var size = UInt32(count + 36).littleEndian
        try withUnsafeBytes(of: &size) { try handle.write(contentsOf: Data($0)) }
        try handle.seek(toOffset: 40); var length = UInt32(count).littleEndian
        try withUnsafeBytes(of: &length) { try handle.write(contentsOf: Data($0)) }
        try handle.synchronize(); try handle.close()
    }
    deinit { try? close() }
}
