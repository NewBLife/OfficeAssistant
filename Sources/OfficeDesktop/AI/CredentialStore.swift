import Foundation
import Security
import OfficeCore

public struct AzureSpeechCredentials: Codable, Sendable {
    public var key: String
    public var region: String
    public init(key: String, region: String) { self.key = key; self.region = region }
}
public struct TingwuCredentials: Codable, Sendable {
    public var accessKeyID: String
    public var accessKeySecret: String
    public var appKey: String
    public var securityToken: String?
    public init(accessKeyID: String, accessKeySecret: String, appKey: String, securityToken: String? = nil) {
        self.accessKeyID = accessKeyID; self.accessKeySecret = accessKeySecret; self.appKey = appKey; self.securityToken = securityToken
    }
}
public enum CredentialValidation {
    public static func validate(_ data: Data, for provider: AIProvider) throws {
        func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch provider {
        case .azureSpeech:
            guard let value = try? JSONDecoder().decode(AzureSpeechCredentials.self, from: data), nonempty(value.key),
                  value.region.range(of: "^[a-z][a-z0-9]+$", options: .regularExpression) != nil else { throw OfficeError.invalid("请填写 Speech 密钥和有效资源区域，如 japaneast。") }
        case .aliyunTingwu:
            guard let value = try? JSONDecoder().decode(TingwuCredentials.self, from: data), nonempty(value.accessKeyID), nonempty(value.accessKeySecret), nonempty(value.appKey) else { throw OfficeError.invalid("请填写 AccessKey ID、Secret 和项目 AppKey。") }
        default:
            guard let key = String(data: data, encoding: .utf8), nonempty(key), !key.contains("\n"), !key.contains("\r") else { throw OfficeError.invalid("请填写有效的 API 密钥。") }
        }
    }
}
@MainActor public protocol CredentialStore {
    func contains(_ provider: AIProvider) throws -> Bool
    func save(_ secret: Data, for provider: AIProvider) throws
    func read(_ provider: AIProvider) throws -> Data
}
@MainActor public final class KeychainCredentialStore: CredentialStore {
    private let service = "local.officeassistant.providers"
    public init() {}
    private func query(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
    }
    public func contains(_ provider: AIProvider) throws -> Bool {
        var q = query(provider); q[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw OfficeError.invalid("无法检查钥匙串（\(status)）。") }
        return true
    }
    public func save(_ secret: Data, for provider: AIProvider) throws {
        try CredentialValidation.validate(secret, for: provider)
        let q = query(provider)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = secret
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw OfficeError.invalid("密钥未保存，原值保持不变（\(status)）。") }
    }
    public func read(_ provider: AIProvider) throws -> Data {
        var q = query(provider); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw OfficeError.invalid("请先在 AI 服务设置中保存\(provider.label)凭证。") }
        try CredentialValidation.validate(data, for: provider)
        return data
    }
}
