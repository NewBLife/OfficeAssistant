import Foundation

public enum TranscriptReducer {
    public static func apply(_ event: TranscriptEvent, to values: [TranscriptSegment]) -> [TranscriptSegment] {
        var result = values
        let index = result.firstIndex { $0.id == event.id }
        var item = index.map { result[$0] } ?? TranscriptSegment(id: event.id)
        guard event.revision >= item.revision else { return result }
        if event.revision > item.revision {
            item.revision = event.revision; item.finalText = nil; item.partialText = ""
            item.translatedText = ""; item.translationState = .waiting; item.errorMessage = nil
        }
        switch event.kind {
        case .partial: if item.finalText == nil { item.partialText = event.text }
        case .final:
            // A final is immutable within a revision; corrections use a new revision.
            if item.finalText != nil { return result }
            item.finalText = event.text; item.partialText = ""; item.errorMessage = nil
        case .translation: item.translatedText = event.text; item.translationState = .completed; item.errorMessage = nil
        case .translationPartial: item.translatedText = event.text; item.translationState = .processing
        case .failure: item.errorMessage = event.text; item.translationState = .failed
        }
        item.providerItemID = event.providerItemID ?? item.providerItemID
        if event.endSeconds > 0 { item.sourceStartSeconds = event.startSeconds; item.sourceEndSeconds = event.endSeconds }
        if let index { result[index] = item } else { result.append(item) }
        return result.sorted {
            if $0.sourceStartSeconds != $1.sourceStartSeconds { return $0.sourceStartSeconds < $1.sourceStartSeconds }
            if $0.id.source != $1.id.source { return $0.id.source.rawValue < $1.id.source.rawValue }
            return $0.id.sequence < $1.id.sequence
        }
    }
}
