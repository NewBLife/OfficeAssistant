import Foundation
import OfficeCore

public enum MinutesProcessingPolicy {
    public static let sectionSeconds: TimeInterval = 2 * 60 * 60
    public static let chunkCharacters = 12000
    public static let requestTimeout: TimeInterval = 180
    public static let resourceTimeout: TimeInterval = 240
    public static let evidenceCorrections = 2
    // Initial generation, bounded evidence corrections, and one transient-network retry.
    public static let chunkTimeout: TimeInterval = Double(2 + evidenceCorrections) * resourceTimeout + 30

    public static func jobTimeout(chunkCount: Int) -> TimeInterval {
        Double(max(1, chunkCount)) * chunkTimeout + 30
    }

    public static func chunks(_ snapshot: MinutesSnapshot) throws -> [MinutesSnapshot] {
        var groups: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var count = 0
        var section: Double?
        for item in snapshot.segments {
            guard item.sourceStartSeconds.isFinite, item.sourceStartSeconds >= 0 else {
                throw OfficeError.invalid("原文片段时间无效，无法分段生成纪要。")
            }
            // Keep transcript boundaries and evidence IDs intact at each two-hour boundary.
            let nextSection = floor(item.sourceStartSeconds / sectionSeconds)
            if section != nextSection, !current.isEmpty {
                groups.append(current); current = []; count = 0
            }
            section = nextSection
            var rest = item.text[...]
            while !rest.isEmpty {
                let piece = String(rest.prefix(chunkCharacters)); rest = rest.dropFirst(piece.count)
                if count + piece.count > chunkCharacters && !current.isEmpty {
                    groups.append(current); current = []; count = 0
                }
                var copy = item; copy.finalText = piece; current.append(copy); count += piece.count
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.map {
            var chunk = MinutesSnapshot(meeting: snapshot.meeting, segments: $0)
            chunk.knownActions = snapshot.knownActions
            return chunk
        }
    }
}
