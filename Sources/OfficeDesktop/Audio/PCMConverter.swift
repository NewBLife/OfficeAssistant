import AVFoundation
import OfficeCore

public enum PCMCodec {
    public static func buffer(_ data: Data, rate: Double = 24000) throws -> AVAudioPCMBuffer {
        guard data.count % 2 == 0, let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)) else { throw OfficeError.invalid("音频格式无效。") }
        buffer.frameLength = buffer.frameCapacity
        if let pointer = buffer.mutableAudioBufferList.pointee.mBuffers.mData { data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count) }
        return buffer
    }
    public static func convert(_ input: AVAudioPCMBuffer, rate: Double = 24000) throws -> Data {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * rate / input.format.sampleRate)) + 32) else { throw OfficeError.invalid("无法转换此音频格式。") }
        converter.primeMethod = .none
        var used = false; var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if used { state.pointee = .endOfStream; return nil }
            used = true; state.pointee = .haveData; return input
        }
        guard status != .error, failure == nil, let data = output.audioBufferList.pointee.mBuffers.mData else { throw OfficeError.invalid("音频转换失败。") }
        return Data(bytes: data, count: min(Int(output.frameLength), Int((Double(input.frameLength) * rate / input.format.sampleRate).rounded())) * 2)
    }
    public static func sixteenK(_ data: Data) throws -> Data { try convert(buffer(data), rate: 16000) }
    public static func wav(_ pcm: Data, rate: UInt32 = 24000) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(pcm.count) + 36); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16); text("data"); u32(UInt32(pcm.count)); data.append(pcm); return data
    }
}

// AVAudioConverter retains filter state across live buffers; flush only at file EOF.
public final class PCMConversionStream {
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var rate: Double = 24000
    private var expected = 0.0
    private var produced = 0
    public init() {}
    public func convert(_ input: AVAudioPCMBuffer, rate targetRate: Double = 24000) throws -> Data {
        var prefix = Data()
        if format != input.format || rate != targetRate {
            prefix = try finish()
            guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetRate, channels: 1, interleaved: true), let next = AVAudioConverter(from: input.format, to: target) else { throw OfficeError.invalid("无法转换音频流。") }
            converter = next; next.primeMethod = .none; format = input.format; rate = targetRate; expected = 0; produced = 0
        }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * rate / input.format.sampleRate)) + 64) else { throw OfficeError.invalid("无法分配音频缓冲。") }
        var supplied = false; var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard result != .error, error == nil else { throw OfficeError.invalid("音频流转换失败。") }
        expected += Double(input.frameLength) * rate / input.format.sampleRate
        produced += Int(output.frameLength)
        if let pointer = output.audioBufferList.pointee.mBuffers.mData { prefix.append(Data(bytes: pointer, count: Int(output.frameLength) * 2)) }
        return prefix
    }
    public func finish() throws -> Data {
        defer { converter = nil; format = nil; expected = 0; produced = 0 }
        guard let converter else { return Data() }
        let remaining = max(0, Int(expected.rounded()) - produced)
        guard remaining > 0, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(remaining + 64)) else { return Data() }
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
        guard result != .error, error == nil else { throw OfficeError.invalid("音频流收尾失败。") }
        guard let pointer = output.audioBufferList.pointee.mBuffers.mData else { return Data() }
        return Data(bytes: pointer, count: min(remaining, Int(output.frameLength)) * 2)
    }
}
