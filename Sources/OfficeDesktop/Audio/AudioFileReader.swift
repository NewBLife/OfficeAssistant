import Foundation
import AVFoundation
import OfficeCore

public enum AudioFileReader {
    public static func frames(url: URL, startFrame: Int64 = 0) -> AsyncThrowingStream<PCMFrame, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let task = Task.detached {
                let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
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
                } catch { continuation.finish(throwing: error is CancellationError ? error : OfficeError.invalid("无法解码这个音频文件，请使用 WAV、M4A、MP3 或 AIFF。")) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
