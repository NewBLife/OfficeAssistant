import Foundation
import CryptoKit
import OfficeCore

public extension MinutesSnapshot {
    var fingerprint: String {
        struct Source: Encodable { var id: UUID; var title: String; var participants: String; var start: Date; var segments: [Part] }
        struct Part: Encodable { var id: SegmentID; var revision: Int; var text: String; var start: Double; var end: Double }
        let value = Source(id: meeting.id, title: meeting.title, participants: meeting.participantsNote, start: meeting.startedAt, segments: segments.map { Part(id: $0.id, revision: $0.revision, text: $0.text, start: $0.sourceStartSeconds, end: $0.sourceEndSeconds) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(value)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "invalid"
    }
}
@MainActor public protocol MinutesGenerating {
    func generate(snapshot: MinutesSnapshot, options: MinutesOptions) async throws -> MinutesGenerationResult
}
private struct EvidencePayload: Decodable { var segmentKey: String; var quote: String }
private struct PointPayload: Decodable { var textZH: String; var textJA: String?; var evidence: [EvidencePayload] }
private struct ActionPayload: Decodable { var titleZH: String; var titleJA: String?; var owner: String?; var dueText: String?; var intent: String; var evidence: [EvidencePayload] }
private struct MinutesPayload: Decodable { var overviewZH: String; var overviewJA: String?; var topics: [PointPayload]; var decisions: [PointPayload]; var openQuestions: [PointPayload]; var actions: [ActionPayload] }

@MainActor public final class MinutesGenerator: MinutesGenerating {
    private let credentials: any CredentialStore; private let transport: any ProviderTransport
    public init(credentials: any CredentialStore, transport: any ProviderTransport = URLSessionProviderTransport()) { self.credentials = credentials; self.transport = transport }
    public func request(snapshot: MinutesSnapshot, options: MinutesOptions) throws -> URLRequest {
        try options.validate()
        guard let base = options.provider.baseURL else { throw OfficeError.invalid("纪要服务不支持文字生成。") }
        let payload: [String: Any] = ["title": String(snapshot.meeting.title.prefix(500)), "participantsNote": String(snapshot.meeting.participantsNote.prefix(2000)), "outputLanguage": options.language.rawValue,
            "referenceDate": options.referenceDate.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(), "timeZoneID": options.timeZoneID,
            "segments": snapshot.segments.map { ["segmentKey": "\($0.id.source.rawValue):\($0.id.sequence)", "text": $0.text] },
            "knownActions": snapshot.knownActions.filter { $0.meetingID == snapshot.meeting.id }.prefix(100).map { ["title": $0.titleZH, "reviewState": $0.reviewState.rawValue] }]
        var body: [String: Any] = ["model": options.model, "stream": false, "messages": [["role": "system", "content": MinutesPrompt.system], ["role": "user", "content": String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]]]
        if options.provider == .openai {
            body["max_completion_tokens"] = 6000
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "meeting_minutes", "strict": true, "schema": MinutesPrompt.schema]]
        } else {
            body["max_tokens"] = 6000; body["response_format"] = ["type": "json_object"]
            if options.provider == .deepseek { body["thinking"] = ["type": "disabled"] }
            if options.provider == .siliconflow { body["enable_thinking"] = false }
        }
        var request = try jsonRequest(url: base.appendingPathComponent("chat/completions"), body: body)
        request.setValue("Bearer \(String(decoding: try credentials.read(options.provider), as: UTF8.self))", forHTTPHeaderField: "Authorization")
        return request
    }
    public static func chunks(_ snapshot: MinutesSnapshot) throws -> [MinutesSnapshot] {
        guard snapshot.segments.reduce(0, { $0 + $1.text.count }) <= 240000 else { throw OfficeError.invalid("转写超过24万字，请分场生成纪要。") }
        var groups: [[TranscriptSegment]] = []; var current: [TranscriptSegment] = []; var count = 0
        for item in snapshot.segments {
            var rest = item.text[...]
            while !rest.isEmpty {
                let piece = String(rest.prefix(12000)); rest = rest.dropFirst(piece.count)
                if count + piece.count > 12000 && !current.isEmpty { groups.append(current); current = []; count = 0 }
                var copy = item; copy.finalText = piece; current.append(copy); count += piece.count
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.map { var chunk = MinutesSnapshot(meeting: snapshot.meeting, segments: $0); chunk.knownActions = snapshot.knownActions; return chunk }
    }
    public func generate(snapshot: MinutesSnapshot, options: MinutesOptions) async throws -> MinutesGenerationResult {
        let chunks = try Self.chunks(snapshot)
        guard !chunks.isEmpty else { throw OfficeError.invalid("没有已定稿原文，暂时无法生成纪要。") }
        let deadline = Date().addingTimeInterval(600)
        var results: [MinutesGenerationResult] = []
        for chunk in chunks {
            try Task.checkCancellation(); guard Date() < deadline else { throw OfficeError.invalid("纪要处理超时，请稍后重试。") }
            let raw = try await transport.data(for: request(snapshot: chunk, options: options)); try Task.checkCancellation()
            guard Date() < deadline else { throw OfficeError.invalid("纪要处理超时，旧版本已保留。") }
            guard raw.count <= 2 * 1024 * 1024, let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let choice = (root["choices"] as? [[String: Any]])?.first, choice["finish_reason"] as? String == "stop",
                  let message = choice["message"] as? [String: Any], message["refusal"] == nil || message["refusal"] is NSNull,
                  let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OfficeError.invalid("纪要未完整返回或被拒绝，旧记录已保留。") }
            // Validate against the exact submitted chunk, then map quote positions to the full original.
            _ = try Self.decodeContent(Data(content.utf8), snapshot: chunk, options: options)
            results.append(try Self.decodeContent(Data(content.utf8), snapshot: snapshot, options: options))
        }
        guard var result = results.first else { throw OfficeError.invalid("纪要结果为空。") }
        for next in results.dropFirst() {
            if !next.document.overviewZH.isEmpty { result.document.overviewZH += "\n" + next.document.overviewZH }
            if let ja = next.document.overviewJA { result.document.overviewJA = [result.document.overviewJA, ja].compactMap { $0 }.joined(separator: "\n") }
            result.document.topics += next.document.topics; result.document.decisions += next.document.decisions; result.document.openQuestions += next.document.openQuestions
            result.candidates = CandidateRules.reconcile(existing: result.candidates, proposed: next.candidates, linkedTasks: [])
        }
        func unique(_ values: [MinutesPoint]) -> [MinutesPoint] {
            var seen: Set<String> = []; return values.filter { seen.insert(CandidateRules.normalized($0.textZH) + $0.evidence.map(\.id).joined()).inserted }
        }
        result.document.topics = unique(result.document.topics); result.document.decisions = unique(result.document.decisions); result.document.openQuestions = unique(result.document.openQuestions)
        guard result.candidates.count <= 100 else { throw OfficeError.invalid("本场行动项超过100条，请拆分会议后再生成，旧记录已保留。") }
        // Separate chunks cannot prove an earlier commitment remains valid later in the meeting.
        // Require individual whole-meeting review rather than offering these for batch addition.
        if chunks.count > 1 {
            for index in result.candidates.indices {
                for flag in [CandidateClarification.commitment, .crossChunkReview] where !result.candidates[index].clarifications.contains(flag) { result.candidates[index].clarifications.append(flag) }
            }
        }
        result.document.sourceFingerprint = snapshot.fingerprint
        return result
    }
    public static func decodeContent(_ data: Data, snapshot: MinutesSnapshot, options: MinutesOptions) throws -> MinutesGenerationResult {
        let root = try JSONDecoder().decode(MinutesPayload.self, from: data)
        func bilingual(_ zh: String, _ ja: String?, max: Int) throws {
            guard !zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, zh.count <= max, (ja?.count ?? 0) <= max,
                  options.language != .chineseJapanese || !(ja ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OfficeError.invalid("纪要语言或内容不完整，请重新生成。") }
        }
        func refs(_ values: [EvidencePayload]) throws -> [EvidenceReference] {
            guard !values.isEmpty, values.count <= 50 else { throw OfficeError.invalid("纪要缺少有效原文依据。") }
            return try values.map { value in
                guard !value.quote.isEmpty, value.quote.count <= 12000, let segment = snapshot.segments.first(where: { "\($0.id.source.rawValue):\($0.id.sequence)" == value.segmentKey && $0.id.meetingID == snapshot.meeting.id && $0.finalText != nil && $0.text.contains(value.quote) }) else { throw OfficeError.invalid("纪要引用与本次原文不符，旧记录已保留。") }
                let range = (segment.text as NSString).range(of: value.quote)
                return EvidenceReference(segmentID: segment.id, revision: segment.revision, quote: value.quote, startUTF16: range.location, lengthUTF16: range.length, sourceStartSeconds: segment.sourceStartSeconds)
            }
        }
        func points(_ values: [PointPayload]) throws -> [MinutesPoint] {
            guard values.count <= 100 else { throw OfficeError.invalid("纪要条目过多。") }
            return try values.map { try bilingual($0.textZH, $0.textJA, max: 4000); return MinutesPoint(textZH: $0.textZH, textJA: $0.textJA, evidence: try refs($0.evidence)) }
        }
        try bilingual(root.overviewZH, root.overviewJA, max: 12000)
        var document = MinutesDocument(meetingID: snapshot.meeting.id, meetingTitle: snapshot.meeting.title, options: options)
        document.participantsNote = snapshot.meeting.participantsNote; document.sourceFingerprint = snapshot.fingerprint
        document.overviewZH = root.overviewZH; document.overviewJA = root.overviewJA
        document.topics = try points(root.topics); document.decisions = try points(root.decisions); document.openQuestions = try points(root.openQuestions)
        guard root.actions.count <= 100 else { throw OfficeError.invalid("行动项超过100条，请分场处理。") }
        var candidates: [ActionCandidate] = []
        for value in root.actions {
            guard ["commitment", "assignment", "uncertain", "question", "hypothetical", "negated", "completed"].contains(value.intent) else { throw OfficeError.invalid("行动项类型不受支持。") }
            guard ["commitment", "assignment", "uncertain"].contains(value.intent) else { continue }
            try bilingual(value.titleZH, value.titleJA, max: 200)
            let evidence = try refs(value.evidence); let original = evidence.map(\.quote).joined(separator: "\n")
            var item = ActionCandidate(meetingID: snapshot.meeting.id, titleZH: value.titleZH, evidence: evidence)
            item.titleJA = value.titleJA; item.timeZoneID = options.timeZoneID
            let pronouns = ["我", "我们", "你", "你们", "私", "私たち", "こちら", "弊社", "当社", "未指定", "不明"]
            if let owner = value.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty, !pronouns.contains(owner), original.contains(owner) { item.owner = owner }
            if item.owner == nil { item.clarifications.append(.owner) }
            if let due = value.dueText, !due.isEmpty, original.contains(due) {
                item.dueText = due
                let resolved = MeetingDeadlineResolver.resolve(due, reference: options.referenceDate, evidenceOffset: evidence.map(\.sourceStartSeconds).min() ?? 0, timeZoneID: options.timeZoneID)
                item.dueAt = resolved.dueAt
                if resolved.needsClarification { item.clarifications.append(resolved.missingMeetingDate ? .meetingDate : .deadline) }
            } else if value.dueText != nil { item.clarifications.append(.deadline) }
            if value.intent == "uncertain" { item.clarifications.append(.commitment) }
            candidates.append(item)
        }
        return MinutesGenerationResult(document: document, candidates: CandidateRules.reconcile(existing: [], proposed: candidates, linkedTasks: []))
    }
}
