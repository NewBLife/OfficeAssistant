import Foundation

public struct AudioStreamingPart: Sendable {
    public var pcm: Data; public var startSeconds: Double; public var utterance: AudioUtterance?
}
public struct AudioSegmenter {
    private var pending = Data(); private var buffer = Data(); private var preRoll = Data()
    private var voicedSeconds = 0.0; private var sentCount = 0
    private var leadingOverlap = 0.0; private var nextOverlap = 0.0
    private let overlapBytes: Int
    private var silence = 0.0; private var active = false; private var start = 0.0; private var cursor = 0.0
    private let meetingID: UUID; private let source: AudioSourceID
    public private(set) var streamingParts: [AudioStreamingPart] = []
    public private(set) var streamingPCM = Data()
    public private(set) var streamingStart = 0.0
    public var bufferedSeconds: Double { Double(buffer.count + pending.count + preRoll.count) / 48000 }
    public private(set) var nextSequence: Int
    public init(meetingID: UUID, source: AudioSourceID, nextSequence: Int = 0, overlapSeconds: Double = 0) { self.meetingID = meetingID; self.source = source; self.nextSequence = nextSequence; self.overlapBytes = Int(min(0.1, max(0, overlapSeconds)) * 48000) / 2 * 2 }
    public mutating func append(_ frame: PCMFrame) -> [AudioUtterance] {
        streamingParts = []; streamingPCM = Data(); streamingStart = frame.startSeconds
        var part = Data(); var partStart = frame.startSeconds
        if pending.isEmpty { cursor = frame.startSeconds }
        pending.append(frame.samples); var results: [AudioUtterance] = []
        while pending.count >= 960 {
            let chunk = Data(pending.prefix(960)); pending.removeFirst(960)
            let energy: Double = chunk.withUnsafeBytes { raw in
                var sum = 0.0
                for offset in stride(from: 0, to: raw.count, by: 2) { let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768; sum += sample * sample }
                return sqrt(sum / 480)
            }
            let voiced = energy > pow(10, -45.0 / 20)
            if !active && voiced {
                active = true; buffer = preRoll; start = max(0, cursor - Double(preRoll.count) / 48000)
                leadingOverlap = nextOverlap; nextOverlap = 0; preRoll = Data()
            }
            if active {
                buffer.append(chunk); if voiced { voicedSeconds += 0.02 }
                if voicedSeconds >= 0.199 {
                    let fresh = Data(buffer.dropFirst(sentCount))
                    let freshStart = start + Double(sentCount) / 48000
                    if part.isEmpty { partStart = freshStart }; part.append(fresh)
                    if streamingPCM.isEmpty { streamingStart = freshStart }; streamingPCM.append(fresh)
                    sentCount = buffer.count
                }
                silence = voiced ? 0 : silence + 0.02
                if buffer.count >= 960000 || silence >= 0.6 {
                    let overlap = buffer.count >= 960000 ? Data(buffer.suffix(overlapBytes)) : Data()
                    if let utterance = finish() {
                        results.append(utterance); streamingParts.append(AudioStreamingPart(pcm: part, startSeconds: partStart, utterance: utterance)); part = Data()
                    }
                    preRoll = overlap; nextOverlap = Double(overlap.count) / 48000
                }
            } else {
                preRoll.append(chunk)
                if preRoll.count > 9600 { preRoll.removeFirst(preRoll.count - 9600) }
            }
            cursor += 0.02
        }
        if !part.isEmpty { streamingParts.append(AudioStreamingPart(pcm: part, startSeconds: partStart, utterance: nil)) }
        return results
    }
    public mutating func finish() -> AudioUtterance? {
        defer { buffer = Data(); preRoll = Data(); active = false; silence = 0; voicedSeconds = 0; sentCount = 0; leadingOverlap = 0; nextOverlap = 0 }
        guard voicedSeconds >= 0.199, buffer.count >= 9600 else { return nil }
        var utterance = AudioUtterance(id: SegmentID(meetingID: meetingID, source: source, sequence: nextSequence), startSeconds: start, pcm: buffer)
        utterance.leadingOverlapSeconds = leadingOverlap
        nextSequence += 1; return utterance
    }
}
public struct AudioBacklog {
    public private(set) var items: [AudioUtterance] = []
    public var durationSeconds: Double { items.reduce(0) { $0 + $1.duration } }
    public init() {}
    public mutating func enqueue(_ item: AudioUtterance) throws {
        if items.contains(where: { $0.id == item.id }) { return }
        guard durationSeconds + item.duration <= 60.001 else { throw OfficeError.invalid("待处理音频已达到 60 秒，已暂停采集。") }
        items.append(item)
    }
    public mutating func remove(_ id: SegmentID) { items.removeAll { $0.id == id } }
    public mutating func dequeue() -> AudioUtterance? { items.isEmpty ? nil : items.removeFirst() }
}
