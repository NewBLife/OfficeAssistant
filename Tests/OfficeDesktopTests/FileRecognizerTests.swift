import Foundation
import Testing
import OfficeCore
@testable import OfficeDesktop

final class RateLimitTransport: ProviderTransport {
    var statuses: [Int]; var count = 0
    init(_ statuses: [Int]) { self.statuses = statuses }
    func data(for request: URLRequest) async throws -> Data {
        count += 1; let code = statuses.removeFirst()
        if code != 200 { throw ProviderHTTPError(status: code, retryAfter: 0) }
        return Data("{\"text\":\"納期\"}".utf8)
    }
    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
}
@MainActor @Suite struct FileRecognizerTests {
    @Test(arguments: [[429, 200], [429, 429], [401]]) func testRateLimitRetriesOnceAndAuthenticationNeverRetries(_ codes: [Int]) async throws {
        let transport = RateLimitTransport(codes); let service = FileSpeechRecognizer(credentials: TestCredentials(), transport: transport)
        let context = RecognitionContext(meetingID: UUID(), source: .file, configuration: AIConfiguration())
        var finished = false; var success = false
        service.onEvent = { _ in success = true; finished = true }; service.onFailure = { _ in finished = true }
        try await service.start(context)
        try await service.commit(AudioUtterance(id: context.id(0), startSeconds: 0, pcm: Data(count: 48000)))
        for _ in 0..<200 where !finished { await Task.yield() }
        #expect(finished); #expect(transport.count == codes.count); #expect(success == (codes.last == 200))
        await service.cancel()
    }
}
