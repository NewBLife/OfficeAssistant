import Foundation
import OfficeCore

public struct RecognitionContext: Sendable {
    public var meetingID: UUID; public var source: AudioSourceID; public var configuration: AIConfiguration
    public var nextSequence: Int
    public init(meetingID: UUID, source: AudioSourceID, configuration: AIConfiguration, nextSequence: Int = 0) { self.meetingID = meetingID; self.source = source; self.configuration = configuration; self.nextSequence = nextSequence }
    public var language: String { configuration.effectiveRecognitionLanguage.code }
    public func id(_ sequence: Int) -> SegmentID { SegmentID(meetingID: meetingID, source: source, sequence: sequence) }
}
@MainActor public protocol SpeechRecognizer: AnyObject {
    var onEvent: ((TranscriptEvent) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onRemoteTask: ((RemoteTask) throws -> Void)? { get set }
    func start(_ context: RecognitionContext) async throws
    func append(_ frame: PCMFrame) async throws
    func commit(_ utterance: AudioUtterance) async throws
    // Synchronous barrier: no queued audio may start sending after this returns.
    func stopSending()
    func cancel() async
}
public func jsonRequest(url: URL, body: [String: Any]) throws -> URLRequest {
    var request = URLRequest(url: url); request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body); return request
}
