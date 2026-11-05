import Foundation
import OfficeCore

struct MinutesEvidenceIssue: Hashable {
    let segmentKey: String
    let quote: String
}
struct MinutesEvidenceMismatch: LocalizedError {
    let issues: [MinutesEvidenceIssue]
    var segmentKey: String { issues[0].segmentKey }
    var quote: String { issues[0].quote }
    init(segmentKey: String, quote: String) { issues = [MinutesEvidenceIssue(segmentKey: segmentKey, quote: quote)] }
    init(issues: [MinutesEvidenceIssue]) { self.issues = issues }
    var errorDescription: String? { "纪要引用与本次原文不符，请重新生成。" }
}

enum MinutesEvidenceResolver {
    struct Match {
        let segment: TranscriptSegment
        let quote: String
        let range: NSRange
    }

    static func resolve(segmentKey: String, quote: String, snapshot: MinutesSnapshot) throws -> Match {
        guard !quote.isEmpty, quote.count <= MinutesProcessingPolicy.chunkCharacters else {
            throw MinutesEvidenceMismatch(segmentKey: segmentKey, quote: quote)
        }
        let keyed = snapshot.segments.filter { "\($0.id.source.rawValue):\($0.id.sequence)" == segmentKey }
        // Prefer the supplied ID. Never guess among multiple other source segments.
        if let match = keyed.compactMap({ exact(quote, in: $0) }).first { return match }
        if let match = keyed.compactMap({ formatted(quote, in: $0) }).first { return match }
        let needle = normalized(quote).text
        if needle.count >= 8 {
            let matches = snapshot.segments.compactMap { exact(quote, in: $0) ?? formatted(quote, in: $0) }
            if matches.count == 1 { return matches[0] }
        }
        throw MinutesEvidenceMismatch(segmentKey: segmentKey, quote: quote)
    }

    private static func exact(_ quote: String, in segment: TranscriptSegment) -> Match? {
        let range = (segment.text as NSString).range(of: quote)
        guard range.location != NSNotFound else { return nil }
        return Match(segment: segment, quote: (segment.text as NSString).substring(with: range), range: range)
    }

    private static func formatted(_ quote: String, in segment: TranscriptSegment) -> Match? {
        let source = normalized(segment.text)
        let needle = normalized(quote).text
        // Tiny fragments are too ambiguous to repair safely.
        guard needle.count >= 6 else { return nil }
        let range = (source.text as NSString).range(of: needle)
        guard range.location != NSNotFound, NSMaxRange(range) <= source.ranges.count else { return nil }
        let first = source.ranges[range.location]
        let last = source.ranges[NSMaxRange(range) - 1]
        let original = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        return Match(segment: segment, quote: (segment.text as NSString).substring(with: original), range: original)
    }

    private static func normalized(_ text: String) -> (text: String, ranges: [NSRange]) {
        let characters = Array(text)
        let separators: Set<Character> = Set("，。！？、；：,.!?;:「」『』“”\"（）()")
        var result = ""
        var ranges: [NSRange] = []
        var offset = 0
        for (index, character) in characters.enumerated() {
            let raw = String(character)
            let range = NSRange(location: offset, length: raw.utf16.count)
            offset += range.length
            if character.isWhitespace { continue }
            // Retain punctuation next to digits: 1.5 must never match 15, nor 1,000 match 1000.
            let previous = characters[..<index].last(where: { !$0.isWhitespace })
            let next = characters[(index + 1)...].first(where: { !$0.isWhitespace })
            let besideNumber = previous?.isNumber == true || next?.isNumber == true
            let insideLatinWord = index > 0 && index + 1 < characters.count
                && characters[index - 1].isASCII && characters[index - 1].isLetter
                && characters[index + 1].isASCII && characters[index + 1].isLetter
            if separators.contains(character), !besideNumber, !insideLatinWord { continue }
            let canonical = raw.precomposedStringWithCanonicalMapping
            result += canonical
            ranges.append(contentsOf: repeatElement(range, count: canonical.utf16.count))
        }
        return (result, ranges)
    }
}
