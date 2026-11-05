import Foundation
import OfficeCore

public struct ProviderHTTPError: LocalizedError {
    public let status: Int
    public var retryAfter: TimeInterval? = nil
    public init(status: Int, retryAfter: TimeInterval? = nil) { self.status = status; self.retryAfter = retryAfter }
    public var errorDescription: String? {
        switch status {
        case 401, 403: "服务拒绝访问（\(status)），请检查密钥、区域和权限。"
        case 402: "服务余额或额度不足（402）。"
        case 404: "服务或模型不存在（404），请检查模型设置。"
        case 429: "服务请求频率或额度受限（429），请稍后重试。"
        default: "服务暂时无法完成请求（HTTP \(status)）。"
        }
    }
}
public enum ProviderNetwork {
    public static func allowed(_ url: URL) -> Bool {
        guard ["https", "wss"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return false }
        return ["api.openai.com", "api.deepseek.com", "api.siliconflow.cn", "tingwu.cn-beijing.aliyuncs.com", "tingwu-realtime-cn-beijing.aliyuncs.com"].contains(url.host?.lowercased() ?? "")
    }
    public static func safeError(_ error: Error) -> String {
        if let value = error as? ProviderHTTPError { return value.localizedDescription }
        if let value = error as? OfficeError { return value.localizedDescription }
        if error is CancellationError { return "操作已停止。" }
        return "网络连接中断或超时，请检查网络后重试。"
    }
}
final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public protocol ProviderTransport {
    func data(for request: URLRequest) async throws -> Data
    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error>
}
public final class URLSessionProviderTransport: ProviderTransport {
    private let session: URLSession
    public init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 120) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout; config.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }
    private func validate(_ request: URLRequest) throws {
        guard let url = request.url, ProviderNetwork.allowed(url) else { throw OfficeError.invalid("拒绝向非官方服务地址发送凭证。") }
    }
    private static func retryDelay(_ response: URLResponse) -> TimeInterval? {
        guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(header) { return min(30, max(0, seconds)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: header).map { min(30, max(0, $0.timeIntervalSinceNow)) }
    }
    public func data(for request: URLRequest) async throws -> Data {
        try validate(request)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw ProviderHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, retryAfter: Self.retryDelay(response)) }
        return data
    }
    public func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validate(request)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw ProviderHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, retryAfter: Self.retryDelay(response)) }
                    var buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation(); buffer.append(byte)
                        if byte == 10 || buffer.count >= 4096 { continuation.yield(buffer); buffer = Data() }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }; continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
@MainActor public struct ProviderModelClient {
    let credentials: any CredentialStore; let transport: any ProviderTransport
    public init(credentials: any CredentialStore, transport: any ProviderTransport = URLSessionProviderTransport()) { self.credentials = credentials; self.transport = transport }
    public func models(provider: AIProvider) async throws -> [String] {
        guard let base = provider.baseURL else { throw OfficeError.invalid("该服务使用内置识别能力，不提供通用模型列表。") }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        let key = String(data: try credentials.read(provider), encoding: .utf8) ?? ""
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try await transport.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}
