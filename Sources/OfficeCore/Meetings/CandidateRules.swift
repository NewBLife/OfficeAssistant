import Foundation

public enum CandidateRules {
    public static func normalized(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }
    private static func anchors(_ item: ActionCandidate) -> Set<String> { Set(item.evidence.map { "\($0.segmentID.id):\(normalized($0.quote))" }) }
    private static func grams(_ text: String) -> Set<String> {
        let chars = Array(normalized(text)); if chars.count < 2 { return Set(chars.map(String.init)) }
        return Set(zip(chars, chars.dropFirst()).map { String($0) + String($1) })
    }
    public static func reconcile(existing: [ActionCandidate], proposed: [ActionCandidate], linkedTasks: [TaskItem], replaceProposals: Bool = false) -> [ActionCandidate] {
        var result = existing
        var retained = Set(existing.filter { $0.reviewState != .proposed }.map(\.id))
        for var item in proposed {
            if let old = result.first(where: { $0.meetingID == item.meetingID && normalized($0.titleZH) == normalized(item.titleZH) && $0.owner == item.owner && $0.dueText == item.dueText && anchors($0) == anchors(item) }) {
                retained.insert(old.id)
                if old.reviewState == .proposed { item.id = old.id; result = result.map { $0.id == old.id ? item : $0 } }
                continue
            }
            let sources = Set(item.evidence.map(\.segmentID)); let own = grams(item.titleZH)
            let overlaps = result.contains { old in
                // Edited task/candidate titles may no longer resemble the generated title.
                // Identical quoted evidence still warrants review before creating another task.
                if old.meetingID == item.meetingID && !anchors(item).isEmpty && anchors(old) == anchors(item) { return true }
                if normalized(old.titleZH) == normalized(item.titleZH) && old.owner == item.owner && old.dueText == item.dueText { return true }
                guard !sources.isDisjoint(with: Set(old.evidence.map(\.segmentID))) else { return false }
                let other = grams(old.titleZH); let union = own.union(other)
                return !union.isEmpty && Double(own.intersection(other).count) / Double(union.count) >= 0.7
            }
            let sameTask = linkedTasks.contains { task in (task.meetingLinks ?? []).contains { $0.meetingID == item.meetingID && !$0.evidence.isEmpty && !sources.isDisjoint(with: Set($0.evidence.map(\.segmentID))) } && normalized(task.title) == normalized(item.titleZH) }
            if overlaps || sameTask { if !item.clarifications.contains(.possibleDuplicate) { item.clarifications.append(.possibleDuplicate) } }
            result.append(item)
            retained.insert(item.id)
        }
        return replaceProposals ? result.filter { retained.contains($0.id) } : result
    }
}
