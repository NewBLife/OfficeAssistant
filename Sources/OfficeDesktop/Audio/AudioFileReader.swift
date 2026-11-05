import Foundation
import AVFoundation
import OfficeCore

public enum AudioFileReader {
    /// Validate locally before opening a recognition connection or creating a meeting.
    public static func validate(url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if ["m4a", "mp4", "m4b"].contains(url.pathExtension.lowercased()) {
            try validateContainer(url: url)
        }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate > 0, file.length > 0 else {
                throw OfficeError.invalid("音频文件没有可读取的音频内容。")
            }
        } catch let error as OfficeError { throw error }
        catch { throw OfficeError.invalid("无法读取这个音频文件，文件可能已损坏或使用了不支持的编码。") }
    }

    private static func validateContainer(url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        var offset: UInt64 = 0
        var hasIndex = false
        let incomplete = OfficeError.invalid("音频文件不完整或已损坏，请重新下载或从录音来源重新导出 M4A 文件。")
        func integer(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
        while offset < length {
            guard length - offset >= 8 else { throw incomplete }
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 8), header.count == 8 else { throw incomplete }
            var size = integer(header.prefix(4))
            var headerSize: UInt64 = 8
            if size == 1 {
                guard let extended = try file.read(upToCount: 8), extended.count == 8 else { throw incomplete }
                size = integer(extended); headerSize = 16
            } else if size == 0 { size = length - offset }
            guard size >= headerSize, size <= length - offset else { throw incomplete }
            if String(data: header.suffix(4), encoding: .ascii) == "moov" { hasIndex = true }
            offset += size
        }
        guard hasIndex else { throw incomplete }
    }

    public static func frames(url: URL, startFrame: Int64 = 0) -> AsyncThrowingStream<PCMFrame, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let task = Task.detached {
                let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    try validate(url: url)
                    let file = try AVAudioFile(forReading: url)
                    guard file.processingFormat.sampleRate > 0, startFrame >= 0, Double(startFrame) / 24000 * file.processingFormat.sampleRate <= Double(file.length) else { throw OfficeError.invalid("音频文件或恢复位置无效。") }
                    file.framePosition = Int64(Double(startFrame) / 24000 * file.processingFormat.sampleRate)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw OfficeError.invalid("无法读取音频格式。") }
                    let converter = PCMConversionStream()
                    var sequence = 0; var seconds = Double(startFrame) / 24000
                    while file.framePosition < file.length {
                        try Task.checkCancellation(); try file.read(into: buffer)
                        guard buffer.frameLength > 0 else { break }
                        let data = try converter.convert(buffer)
                        let frame = PCMFrame(source: .file, sequence: sequence, startSeconds: seconds, samples: data)
                        var enqueued = false
                        while !enqueued {
                            try Task.checkCancellation()
                            switch continuation.yield(frame) {
                            case .enqueued: enqueued = true
                            case .dropped: try await Task.sleep(for: .milliseconds(10))
                            case .terminated: return
                            @unknown default: return
                            }
                        }
                        seconds += frame.duration; sequence += 1
                    }
                    let tail = try converter.finish()
                    if !tail.isEmpty {
                        let frame = PCMFrame(source: .file, sequence: sequence, startSeconds: seconds, samples: tail)
                        var sent = false
                        while !sent {
                            try Task.checkCancellation()
                            switch continuation.yield(frame) {
                            case .enqueued: sent = true
                            case .dropped: try await Task.sleep(for: .milliseconds(10))
                            case .terminated: return
                            @unknown default: return
                            }
                        }
                    }
                    continuation.finish()
                } catch let error as CancellationError { continuation.finish(throwing: error) }
                catch let error as OfficeError { continuation.finish(throwing: error) }
                catch { continuation.finish(throwing: OfficeError.invalid("音频解码失败，文件可能已损坏或使用了不支持的编码。")) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
