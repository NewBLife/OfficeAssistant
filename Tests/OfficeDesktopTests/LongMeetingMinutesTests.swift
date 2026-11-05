import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

@MainActor @Suite struct LongMeetingMinutesTests {
    private func snapshot(starts: [Double], characters: Int = 200) -> MinutesSnapshot {
        let meeting = MeetingSession(title: "长会议", configuration: AIConfiguration())
        return MinutesSnapshot(meeting: meeting, segments: starts.enumerated().map { index, start in
            var segment = TranscriptSegment(id: SegmentID(meetingID: meeting.id, source: .file, sequence: index))
            segment.sourceStartSeconds = start; segment.sourceEndSeconds = start + 30
            segment.finalText = String(repeating: "会", count: characters - 1) + "。"
            return segment
        })
    }
    private func payload(_ request: URLRequest) throws -> [[String: String]] {
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let text = try #require(messages.last?["content"] as? String)
        let input = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try #require(input["segments"] as? [[String: String]])
    }
    private func response(_ request: URLRequest) throws -> Data {
        let source = try #require(try payload(request).last)
        let key = try #require(source["segmentKey"])
        let quote = String(try #require(source["text"]).suffix(5))
        let root: [String: Any] = [
            "overviewZH": key, "overviewJA": NSNull(), "topics": [],
            "decisions": [["textZH": key, "textJA": NSNull(), "evidence": [["segmentKey": key, "quote": quote]]]],
            "openQuestions": [], "actions": []
        ]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
    }
    @Test func testTwoHourMeetingPreservesEverySegmentAndReportsProgress() async throws {
        let input = snapshot(starts: (0..<240).map { Double($0) * 30 })
        let transport = FixtureMinutesTransport { try self.response($0) }
        var progress: [(Int, Int)] = []
        let result = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: input, options: MinutesOptions()) {
            progress.append(($0, $1))
        }
        #expect(transport.requests.count == 4)
        let submitted = try transport.requests.flatMap { try payload($0) }
        #expect(submitted.map { $0["segmentKey"]! } == input.segments.map { "file:\($0.id.sequence)" })
        #expect(result.document.overviewZH.contains("file:239"))
        #expect(result.document.decisions.last?.evidence.first?.sourceStartSeconds == 7170)
        #expect(result.document.sourceFingerprint == input.fingerprint)
        #expect(progress.map { $0.0 } == [0, 1, 2, 3, 4])
        #expect(progress.allSatisfy { $0.1 == 4 })
        #expect(MinutesProcessingPolicy.jobTimeout(chunkCount: 4) > 600)
        #expect(transport.requests.allSatisfy { $0.timeoutInterval == 180 })
    }
    @Test func testTwoHourBoundarySplitsSparseTranscriptAndKeepsEvidence() async throws {
        let input = snapshot(starts: [0, 7199, 7200, 14399, 14400])
        let chunks = try MinutesGenerator.chunks(input)
        #expect(chunks.map { $0.segments.map(\.sourceStartSeconds) } == [[0, 7199], [7200, 14399], [14400]])
        let transport = FixtureMinutesTransport { try self.response($0) }
        let result = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: input, options: MinutesOptions())
        #expect(transport.requests.count == 3)
        #expect(result.document.decisions.map { $0.evidence[0].sourceStartSeconds } == [7199, 14399, 14400])
        #expect(result.document.overviewZH.contains("file:4"))
    }
    @Test func testLongTranscriptIsSplitInsteadOfRejectedAt240000Characters() throws {
        let input = snapshot(starts: (0..<25).map { Double($0) * 600 }, characters: 10001)
        let chunks = try MinutesGenerator.chunks(input)
        #expect(chunks.flatMap(\.segments).map(\.text).joined() == input.segments.map(\.text).joined())
        #expect(chunks.allSatisfy { $0.segments.reduce(0) { $0 + $1.text.count } <= 12000 })
        #expect(chunks.allSatisfy { Set($0.segments.map { floor($0.sourceStartSeconds / 7200) }).count == 1 })
    }
    @Test func testOversizedSingleSegmentRetainsTailAndKnownActions() throws {
        var input = snapshot(starts: [0], characters: 25001)
        input.knownActions = [ActionCandidate(meetingID: input.meeting.id, titleZH: "已知安排", evidence: [])]
        let chunks = try MinutesGenerator.chunks(input)
        #expect(chunks.count == 3)
        #expect(chunks.flatMap(\.segments).map(\.text).joined() == input.segments[0].text)
        #expect(chunks.allSatisfy { $0.knownActions == input.knownActions })
    }
    @Test func testTimeoutRetriesOnlyFailedChunk() async throws {
        let input = snapshot(starts: [0, 7200])
        var keys: [String] = []
        let transport = FixtureMinutesTransport { request in
            keys.append(try #require(try self.payload(request).first?["segmentKey"]))
            if keys.count == 2 { throw URLError(.timedOut) }
            return try self.response(request)
        }
        let result = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: input, options: MinutesOptions())
        #expect(keys == ["file:0", "file:1", "file:1"])
        #expect(result.document.decisions.count == 2)
    }
    @Test(arguments: [408, 429, 503]) func testTransientHTTPFailureRetriesOnce(status: Int) async throws {
        var attempts = 0
        let transport = FixtureMinutesTransport { request in
            attempts += 1
            if attempts == 1 { throw ProviderHTTPError(status: status, retryAfter: 0) }
            return try self.response(request)
        }
        _ = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: snapshot(starts: [0]), options: MinutesOptions())
        #expect(attempts == 2)
    }
    @Test(arguments: ["envelope", "content", "evidence", "permission"]) func testFailuresHaveSpecificMessagesAndStop(mode: String) async throws {
        let transport = FixtureMinutesTransport { request in
            if mode == "permission" { throw ProviderHTTPError(status: 403) }
            if mode == "envelope" { return Data("not json".utf8) }
            let content = mode == "content" ? "{}" : "{\"overviewZH\":\"纪要\",\"topics\":[],\"decisions\":[{\"textZH\":\"错误引用\",\"evidence\":[{\"segmentKey\":\"file:0\",\"quote\":\"不存在\"}]}],\"openQuestions\":[],\"actions\":[]}"
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        }
        var message = ""
        do {
            _ = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: snapshot(starts: [0]), options: MinutesOptions())
            Issue.record("Invalid result was accepted")
        } catch { message = ProviderNetwork.safeError(error) }
        #expect(message.contains("第 1/1 段"))
        #expect(!message.contains("网络"))
        #expect(transport.requests.count == (mode == "evidence" ? MinutesProcessingPolicy.evidenceCorrections + 1 : 1))
        #expect(message.contains(mode == "permission" ? "403" : mode == "evidence" ? "引用" : "格式"))
    }
    @Test func testLaterChunkFailurePreservesPreviousVersion() async throws {
        let input = snapshot(starts: [0, 7200])
        let repo = try CoreDataMeetingRepository(inMemory: true)
        try repo.save(input.meeting)
        for segment in input.segments { try repo.upsert(segment) }
        var previous = MinutesDocument(meetingID: input.meeting.id, meetingTitle: input.meeting.title, options: MinutesOptions())
        previous.overviewZH = "已校对版本"; previous.editedByUser = true
        try repo.save(document: previous, candidates: [])
        var attempts = 0
        let transport = FixtureMinutesTransport { request in
            attempts += 1
            if attempts > 1 { throw ProviderHTTPError(status: 503, retryAfter: 0) }
            return try self.response(request)
        }
        let service = MinutesCoordinator(meetings: repo, notes: repo, generator: MinutesGenerator(credentials: TestCredentials(), transport: transport))
        await #expect(throws: (any Error).self) { try await service.generate(meetingID: input.meeting.id, options: MinutesOptions()) }
        #expect(attempts == 3)
        #expect(service.completedChunks == 1 && service.totalChunks == 2)
        #expect(service.currentJob?.status == .failed)
        #expect(service.errorMessage?.contains("第 2/2 段") == true)
        #expect(try repo.documents(meetingID: input.meeting.id) == [previous])
    }
    @Test func testCancellationIsNotRetriedOrMisreportedAsNetworkFailure() async throws {
        let transport = FixtureMinutesTransport { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await MinutesGenerator(credentials: TestCredentials(), transport: transport).generate(snapshot: snapshot(starts: [0]), options: MinutesOptions())
        }
        #expect(transport.requests.count == 1)
    }
}
