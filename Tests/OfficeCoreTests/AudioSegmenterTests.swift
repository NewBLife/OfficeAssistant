import Foundation
import Testing
@testable import OfficeCore

struct AudioSegmenterTests {
    @Test func testSilenceDoesNotCreateUtterance() {
        var segmenter = AudioSegmenter(meetingID: UUID(), source: .microphone)
        let values = segmenter.append(PCMFrame(source: .microphone, sequence: 0, startSeconds: 0, samples: Data(count: 48000)))
        #expect(values.isEmpty); #expect(segmenter.finish() == nil)
    }
    @Test func testForcedSplitAtTwentySeconds() {
        var segmenter = AudioSegmenter(meetingID: UUID(), source: .microphone)
        let values = segmenter.append(PCMFrame(source: .microphone, sequence: 0, startSeconds: 0, samples: Data(repeating: 64, count: 48000 * 21)))
        #expect(values.count == 1); #expect(values[0].duration <= 20.01)
        #expect(segmenter.finish()?.id.sequence == 1)
    }
    @Test func testBacklogBoundedAcrossSources() throws {
        var queue = AudioBacklog(); let id = UUID()
        try queue.enqueue(AudioUtterance(id: SegmentID(meetingID: id, source: .microphone, sequence: 0), startSeconds: 0, pcm: Data(count: 48000 * 31)))
        #expect(throws: (any Error).self) { try queue.enqueue(AudioUtterance(id: SegmentID(meetingID: id, source: .system, sequence: 0), startSeconds: 0, pcm: Data(count: 48000 * 31))) }
        #expect(queue.durationSeconds == 31)
    }
    @Test func testStreamingCommitSplitsLargeFramesAtUtteranceBoundary() {
        var segmenter = AudioSegmenter(meetingID: UUID(), source: .microphone)
        var pcm = Data()
        for n in 0..<24000 { var value = Int16(n % 2 == 0 ? 5000 : -5000).littleEndian; withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) } }
        pcm.append(Data(count: 33600))
        let result = segmenter.append(PCMFrame(source: .microphone, sequence: 0, startSeconds: 0, samples: pcm))
        #expect(result.count == 1)
        let committed = segmenter.streamingParts.filter { $0.utterance != nil }
        #expect(committed.count == 1); #expect(committed.first?.pcm.count == result.first?.pcm.count)
    }
    @Test func testBriefNoiseIsNotUploaded() {
        var segmenter = AudioSegmenter(meetingID: UUID(), source: .microphone)
        var data = Data(repeating: 64, count: 4800); data.append(Data(count: 48000))
        let result = segmenter.append(PCMFrame(source: .microphone, sequence: 0, startSeconds: 0, samples: data))
        #expect(result.isEmpty); #expect(segmenter.streamingPCM.isEmpty)
    }
    @Test func testSegmentedForcedSplitRetainsExplicitOverlap() {
        var segmenter = AudioSegmenter(meetingID: UUID(), source: .file, overlapSeconds: 0.1)
        let result = segmenter.append(PCMFrame(source: .file, sequence: 0, startSeconds: 0, samples: Data(repeating: 64, count: 48000 * 21)))
        let tail = segmenter.finish()
        #expect(result.count == 1); #expect(tail?.leadingOverlapSeconds == 0.1)
        #expect(abs((tail?.startSeconds ?? 0) - 19.9) < 0.001)
    }
}
