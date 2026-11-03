import Foundation

public enum AudioSourceID: String, Codable, CaseIterable, Sendable { case microphone, system, file
    public var label: String { switch self { case .microphone: "麦克风"; case .system: "会议声音"; case .file: "音频文件" } }
}
public struct SegmentID: Codable, Hashable, Sendable, Identifiable {
    public var meetingID: UUID; public var source: AudioSourceID; public var sequence: Int
    public var id: String { "\(meetingID).\(source.rawValue).\(sequence)" }
    public init(meetingID: UUID, source: AudioSourceID, sequence: Int) { self.meetingID = meetingID; self.source = source; self.sequence = sequence }
}
public enum MeetingState: String, Codable, Sendable { case ready, recording, paused, finishing, completed, interrupted, failed
    public var label: String { switch self { case .ready: "准备开始"; case .recording: "正在记录"; case .paused: "已暂停"; case .finishing: "正在收尾"; case .completed: "已结束"; case .interrupted: "记录已中断"; case .failed: "需要处理" } }
}
public struct RemoteTask: Codable, Equatable, Sendable {
    public var taskID: String; public var source: AudioSourceID; public var needsStop: Bool
    public init(taskID: String, source: AudioSourceID, needsStop: Bool = true) { self.taskID = taskID; self.source = source; self.needsStop = needsStop }
}
public struct AudioImportIdentity: Codable, Equatable, Sendable {
    public var size: UInt64; public var edgeSHA256: String
    public init(size: UInt64, edgeSHA256: String) { self.size = size; self.edgeSHA256 = edgeSHA256 }
}
public struct MeetingSession: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID(); public var title: String; public var participantsNote = ""
    public var startedAt = Date(); public var endedAt: Date?; public var state: MeetingState = .ready
    public var configuration: AIConfiguration; public var retainAudio = false; public var remoteTasks: [RemoteTask] = []
    public var audioFiles: [String] = []; public var importOffset: Int64 = 0
    public var importIdentity: AudioImportIdentity?
    public init(title: String, configuration: AIConfiguration) { self.title = title; self.configuration = configuration }
}
public enum TranslationState: String, Codable, Sendable { case waiting, processing, completed, failed }
public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: SegmentID; public var revision = 0
    public var sourceStartSeconds = 0.0; public var sourceEndSeconds = 0.0
    public var providerItemID: String?; public var partialText = ""; public var finalText: String?
    public var translatedText = ""; public var translationState: TranslationState = .waiting
    public var translationModel: String?
    public var errorMessage: String?; public var recognitionSeconds: Double?; public var translationSeconds: Double?
    public var text: String { finalText ?? partialText }
    public init(id: SegmentID) { self.id = id }
}
public struct TranscriptEvent: Sendable {
    public enum Kind: Sendable { case partial, final, translation, translationPartial, failure }
    public var id: SegmentID; public var kind: Kind; public var text: String; public var revision: Int
    public var providerItemID: String?; public var startSeconds: Double; public var endSeconds: Double
    public init(id: SegmentID, kind: Kind, text: String, revision: Int = 0, providerItemID: String? = nil, startSeconds: Double = 0, endSeconds: Double = 0) {
        self.id = id; self.kind = kind; self.text = text; self.revision = revision; self.providerItemID = providerItemID
        self.startSeconds = startSeconds; self.endSeconds = endSeconds
    }
}
public struct PCMFrame: Sendable {
    public var source: AudioSourceID; public var sequence: Int; public var startSeconds: Double; public var samples: Data
    public var duration: Double { Double(samples.count) / 48000 }
    public init(source: AudioSourceID, sequence: Int, startSeconds: Double, samples: Data) { self.source = source; self.sequence = sequence; self.startSeconds = startSeconds; self.samples = samples }
}
public struct AudioUtterance: Sendable {
    public var id: SegmentID; public var startSeconds: Double; public var pcm: Data
    public var leadingOverlapSeconds = 0.0
    public var duration: Double { Double(pcm.count) / 48000 }
    public init(id: SegmentID, startSeconds: Double, pcm: Data) { self.id = id; self.startSeconds = startSeconds; self.pcm = pcm }
}
