import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import ScreenCaptureKit
import CoreMedia
import OfficeCore

public struct MicrophoneDevice: Identifiable, Hashable {
    public var id: UInt32; public var name: String
    public static func available() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var name = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: CFString = "麦克风" as CFString; var valueSize = UInt32(MemoryLayout<CFString>.size)
            _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &name, 0, nil, &valueSize, UnsafeMutableRawPointer($0)) }
            return MicrophoneDevice(id: id, name: value as String)
        }
    }
}
public struct SystemAudioSource: Identifiable, Hashable {
    public var id: String; public var name: String; public var appPID: Int32?; public var displayID: UInt32
    public static func available() async throws -> [SystemAudioSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { return [] }
        let apps = content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier && !$0.applicationName.isEmpty }
        return apps.sorted { $0.applicationName < $1.applicationName }.map { SystemAudioSource(id: "app.\($0.processID)", name: $0.applicationName, appPID: $0.processID, displayID: display.displayID) }
            + content.displays.map { SystemAudioSource(id: "display.\($0.displayID)", name: "显示器 \($0.displayID) 的系统声音", appPID: nil, displayID: $0.displayID) }
    }
}
@MainActor public protocol AudioCapture: AnyObject {
    func start() async throws -> AsyncThrowingStream<PCMFrame, Error>
    func stop() async
}
public final class MicrophoneCapture: AudioCapture {
    private let engine = AVAudioEngine(); private let deviceID: UInt32?
    @MainActor private var lifecycle = UUID()
    private var continuation: AsyncThrowingStream<PCMFrame, Error>.Continuation?
    private var observer: NSObjectProtocol?; private var installed = false
    private let converter = PCMConversionStream()
    private let lock = NSLock(); private var enabled = false; private var sequence = 0; private var cursor = 0.0
    public init(deviceID: UInt32?) { self.deviceID = deviceID }
    @MainActor public func start() async throws -> AsyncThrowingStream<PCMFrame, Error> {
        let token = lifecycle
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw OfficeError.invalid("麦克风访问未获允许，请在系统隐私设置中开启。") }
        guard token == lifecycle else { throw CancellationError() }
        if let deviceID, let unit = engine.inputNode.audioUnit {
            var id = deviceID
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<UInt32>.size)) == noErr else { throw OfficeError.invalid("选定的麦克风不可用。") }
        }
        let pair = AsyncThrowingStream<PCMFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation = pair.continuation
        lock.withLock { enabled = true }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw OfficeError.invalid("麦克风没有可用的音频输入。") }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            guard self.enabled else { return }
            do {
                let data = try self.converter.convert(buffer)
                let frame = PCMFrame(source: .microphone, sequence: self.sequence, startSeconds: self.cursor, samples: data)
                self.sequence += 1; self.cursor += frame.duration
                if case .dropped = pair.continuation.yield(frame) { pair.continuation.finish(throwing: OfficeError.invalid("音频处理速度不足，已暂停，请稍后继续。")) }
            } catch { pair.continuation.finish(throwing: OfficeError.invalid("麦克风音频转换失败。")) }
        }
        installed = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in pair.continuation.finish(throwing: OfficeError.invalid("音频设备配置已变化，请重新选择麦克风。")) }
        try engine.start(); return pair.stream
    }
    @MainActor public func stop() async {
        lifecycle = UUID()
        lock.withLock { enabled = false }
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        engine.stop(); if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        continuation?.finish(); continuation = nil
    }
}
public final class SystemAudioCapture: NSObject, AudioCapture, SCStreamOutput, SCStreamDelegate {
    private let source: SystemAudioSource; private var stream: SCStream?
    @MainActor private var lifecycle = UUID()
    private var continuation: AsyncThrowingStream<PCMFrame, Error>.Continuation?
    private let queue = DispatchQueue(label: "office.system-audio")
    private let converter = PCMConversionStream()
    private let lock = NSLock(); private var enabled = false; private var sequence = 0; private var cursor = 0.0
    public init(source: SystemAudioSource) { self.source = source }
    @MainActor public func start() async throws -> AsyncThrowingStream<PCMFrame, Error> {
        let token = lifecycle
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard token == lifecycle else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == source.displayID }) else { throw OfficeError.invalid("所选显示器已不可用，请重新选择。") }
        let filter: SCContentFilter
        if let pid = source.appPID {
            guard let app = content.applications.first(where: { $0.processID == pid }) else { throw OfficeError.invalid("所选会议软件已退出，请重新选择。") }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else { filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []) }
        let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 24000; config.channelCount = 1; config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 60)
        let pair = AsyncThrowingStream<PCMFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(64)); continuation = pair.continuation
        lock.withLock { enabled = true }
        let stream = SCStream(filter: filter, configuration: config, delegate: self); self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        guard token == lifecycle else { try? await stream.stopCapture(); throw CancellationError() }
        return pair.stream
    }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock(); defer { lock.unlock() }; guard enabled, type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
            let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr else { return }
        do {
            let pcm = try self.converter.convert(buffer)
            let frame = PCMFrame(source: .system, sequence: sequence, startSeconds: cursor, samples: pcm); sequence += 1; cursor += frame.duration
            if case .dropped = continuation?.yield(frame) { continuation?.finish(throwing: OfficeError.invalid("会议音频处理速度不足，已暂停。")) }
        } catch { continuation?.finish(throwing: OfficeError.invalid("会议音频格式无法转换。")) }
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) { continuation?.finish(throwing: OfficeError.invalid("会议音源已中断，请检查共享权限和所选软件。")) }
    @MainActor public func stop() async {
        lifecycle = UUID()
        lock.withLock { enabled = false }
        if let stream { try? await stream.stopCapture() }; stream = nil; continuation?.finish(); continuation = nil
    }
}
