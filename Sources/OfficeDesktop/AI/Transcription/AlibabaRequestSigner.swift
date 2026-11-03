import Foundation
import CryptoKit
import OfficeCore

public enum AlibabaRequestSigner {
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"))! }
    public static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        let pairs: [(String, String)] = items.map { (encode($0.name), encode($0.value ?? "")) }
        let ordered = pairs.sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
        return ordered.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
    }
    public static func sign(_ original: URLRequest, credentials: TingwuCredentials, date: Date = Date(), nonce: String = UUID().uuidString) throws -> URLRequest {
        guard let url = original.url, url.host == "tingwu.cn-beijing.aliyuncs.com", url.scheme == "https", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw OfficeError.invalid("听悟请求地址无效。") }
        var request = original
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        request.setValue("CreateTask", forHTTPHeaderField: "x-acs-action"); request.setValue("2023-09-30", forHTTPHeaderField: "x-acs-version")
        request.setValue(formatter.string(from: date), forHTTPHeaderField: "x-acs-date"); request.setValue(nonce, forHTTPHeaderField: "x-acs-signature-nonce")
        request.setValue(hash(request.httpBody ?? Data()), forHTTPHeaderField: "x-acs-content-sha256"); request.setValue(url.host, forHTTPHeaderField: "host")
        if let token = credentials.securityToken, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "x-acs-security-token") }
        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, entry in
            let name = entry.key.lowercased(); if name == "host" || name.hasPrefix("x-acs-") { result[name] = entry.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let names = headers.keys.sorted(); let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined(); let signed = names.joined(separator: ";")
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let canonical = [request.httpMethod ?? "PUT", path, canonicalQuery(components.queryItems ?? []), canonicalHeaders, signed, hash(request.httpBody ?? Data())].joined(separator: "\n")
        let stringToSign = "ACS3-HMAC-SHA256\n" + hash(Data(canonical.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: Data(credentials.accessKeySecret.utf8))).map { String(format: "%02x", $0) }.joined()
        request.setValue("ACS3-HMAC-SHA256 Credential=\(credentials.accessKeyID),SignedHeaders=\(signed),Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
}
