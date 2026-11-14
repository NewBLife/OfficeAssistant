import Foundation

public enum MinutesLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese, chineseJapanese
    public var id: Self { self }
    public var label: String { self == .chinese ? "中文" : "中日双语" }
}
public struct MinutesOptions: Codable, Equatable, Sendable {
    public var provider: AIProvider; public var model: String; public var language: MinutesLanguage
    public var timeZoneID: String; public var referenceDate: Date?
    public init(provider: AIProvider = .openai, model: String = "gpt-5.4-mini", language: MinutesLanguage = .chinese, timeZoneID: String = "Asia/Shanghai", referenceDate: Date? = nil) {
        self.provider = provider; self.model = model; self.language = language; self.timeZoneID = timeZoneID; self.referenceDate = referenceDate
    }
    public func validate() throws {
        guard provider.supportsTranslation, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, TimeZone(identifier: timeZoneID) != nil else { throw OfficeError.invalid("请选择有效的纪要服务、模型和时区。") }
    }
}
public struct EvidenceReference: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var segmentID: SegmentID; public var revision: Int; public var quote: String
    public var startUTF16: Int; public var lengthUTF16: Int; public var sourceStartSeconds: Double
    public var id: String { "\(segmentID.id).\(revision).\(startUTF16).\(lengthUTF16)" }
    public init(segmentID: SegmentID, revision: Int, quote: String, startUTF16: Int, lengthUTF16: Int, sourceStartSeconds: Double = 0) {
        self.segmentID = segmentID; self.revision = revision; self.quote = quote; self.startUTF16 = startUTF16; self.lengthUTF16 = lengthUTF16; self.sourceStartSeconds = sourceStartSeconds
    }
}
public struct MinutesPoint: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID(); public var textZH: String; public var textJA: String?; public var evidence: [EvidenceReference]
    public init(textZH: String, textJA: String? = nil, evidence: [EvidenceReference] = []) { self.textZH = textZH; self.textJA = textJA; self.evidence = evidence }
}
public struct MinutesDocument: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID(); public var meetingID: UUID; public var meetingTitle: String; public var participantsNote = ""
    public var revision = 0; public var createdAt = Date(); public var sourceFingerprint = ""; public var options: MinutesOptions
    public var overviewZH = ""; public var overviewJA: String?; public var topics: [MinutesPoint] = []
    public var decisions: [MinutesPoint] = []; public var openQuestions: [MinutesPoint] = []; public var editedByUser = false
    public var supplementalMemo = ""
    public init(meetingID: UUID, meetingTitle: String, options: MinutesOptions) { self.meetingID = meetingID; self.meetingTitle = meetingTitle; self.options = options }
    private enum CodingKeys: String, CodingKey {
        case id, meetingID, meetingTitle, participantsNote, revision, createdAt, sourceFingerprint, options
        case overviewZH, overviewJA, topics, decisions, openQuestions, editedByUser, supplementalMemo
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        meetingTitle = try container.decode(String.self, forKey: .meetingTitle)
        participantsNote = try container.decodeIfPresent(String.self, forKey: .participantsNote) ?? ""
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sourceFingerprint = try container.decodeIfPresent(String.self, forKey: .sourceFingerprint) ?? ""
        options = try container.decode(MinutesOptions.self, forKey: .options)
        overviewZH = try container.decodeIfPresent(String.self, forKey: .overviewZH) ?? ""
        overviewJA = try container.decodeIfPresent(String.self, forKey: .overviewJA)
        topics = try container.decodeIfPresent([MinutesPoint].self, forKey: .topics) ?? []
        decisions = try container.decodeIfPresent([MinutesPoint].self, forKey: .decisions) ?? []
        openQuestions = try container.decodeIfPresent([MinutesPoint].self, forKey: .openQuestions) ?? []
        editedByUser = try container.decodeIfPresent(Bool.self, forKey: .editedByUser) ?? false
        supplementalMemo = try container.decodeIfPresent(String.self, forKey: .supplementalMemo) ?? ""
    }
}
public enum CandidateClarification: String, Codable, CaseIterable, Sendable {
    case owner, deadline, commitment, meetingDate, possibleDuplicate, sourceChanged, crossChunkReview
    public var label: String { switch self {
    case .owner: "负责人待确认"; case .deadline: "时间待确认"; case .commitment: "承诺待确认"
    case .meetingDate: "实际会议日期待确认"; case .possibleDuplicate: "可能重复"; case .sourceChanged: "原文已变化"
    case .crossChunkReview: "需核对全场后续取消或变更"
    } }
}
public enum CandidateReviewState: String, Codable, Sendable { case proposed, ignored, accepted }
public struct ActionCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID(); public var meetingID: UUID; public var titleZH: String; public var titleJA: String?
    public var owner: String?; public var dueText: String?; public var dueAt: Date?; public var timeZoneID = "Asia/Shanghai"
    public var evidence: [EvidenceReference]; public var clarifications: [CandidateClarification] = []
    public var reviewState: CandidateReviewState = .proposed; public var acceptedTaskID: UUID?
    public init(meetingID: UUID, titleZH: String, evidence: [EvidenceReference]) { self.meetingID = meetingID; self.titleZH = titleZH; self.evidence = evidence }
}
public struct TaskMeetingLink: Codable, Equatable, Sendable, Identifiable {
    public var meetingID: UUID; public var meetingTitleSnapshot: String; public var candidateID: UUID?; public var evidence: [EvidenceReference]
    public var id: String { "\(meetingID).\(candidateID?.uuidString ?? "manual")" }
    public init(meetingID: UUID, meetingTitleSnapshot: String, candidateID: UUID? = nil, evidence: [EvidenceReference] = []) { self.meetingID = meetingID; self.meetingTitleSnapshot = meetingTitleSnapshot; self.candidateID = candidateID; self.evidence = evidence }
}
public struct MeetingActionReceipt: Codable, Equatable, Sendable {
    public var meetingID: UUID; public var candidateID: UUID; public var joinedAt: Date
    public init(meetingID: UUID, candidateID: UUID, joinedAt: Date) { self.meetingID = meetingID; self.candidateID = candidateID; self.joinedAt = joinedAt }
}
public struct MinutesSnapshot: Codable, Equatable, Sendable {
    public var meeting: MeetingSession; public var segments: [TranscriptSegment]
    public var knownActions: [ActionCandidate] = []
    public init(meeting: MeetingSession, segments: [TranscriptSegment]) {
        self.meeting = meeting
        self.segments = segments.filter { $0.id.meetingID == meeting.id && !($0.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted {
            if $0.sourceStartSeconds != $1.sourceStartSeconds { return $0.sourceStartSeconds < $1.sourceStartSeconds }
            return $0.id.id < $1.id.id
        }
    }
}
public enum MinutesJobStatus: String, Codable, Sendable { case running, completed, failed, cancelled, stale, interrupted }
public struct MinutesJobRecord: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID(); public var meetingID: UUID; public var options: MinutesOptions; public var sourceFingerprint: String
    public var startedAt = Date(); public var status: MinutesJobStatus = .running; public var errorMessage: String?
    public init(meetingID: UUID, options: MinutesOptions, sourceFingerprint: String) { self.meetingID = meetingID; self.options = options; self.sourceFingerprint = sourceFingerprint }
}
public struct MinutesGenerationResult: Sendable {
    public var document: MinutesDocument; public var candidates: [ActionCandidate]
    public init(document: MinutesDocument, candidates: [ActionCandidate]) { self.document = document; self.candidates = candidates }
}
