import Foundation
import Observation
import OfficeCore

public enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, chinese, english, japanese
    public var id: Self { self }
    public var locale: Locale {
        switch self {
        case .system: .current
        case .chinese: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        case .japanese: Locale(identifier: "ja")
        }
    }
    public var name: String {
        switch self {
        case .system: "跟随系统"
        case .chinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

@MainActor @Observable public final class PreferencesStore {
    public private(set) var value: AppPreferences
    public private(set) var errorMessage: String?
    public private(set) var interfaceLanguage: InterfaceLanguage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var canSave = true
    @ObservationIgnored public var onChange: (() -> Void)?
    private static let key = "office.preferences.v1"
    private static let languageKey = "office.interface-language.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; value = AppPreferences()
        interfaceLanguage = defaults.string(forKey: Self.languageKey).flatMap(InterfaceLanguage.init(rawValue:)) ?? .system
        if let data = defaults.data(forKey: Self.key) {
            do {
                let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
                try decoded.validate(); value = decoded
            } catch { canSave = false; errorMessage = "设置无法读取，原值已保留：\(error.localizedDescription)" }
        }
    }
    public func save(_ preferences: AppPreferences) throws {
        guard canSave else { throw OfficeError.invalid(errorMessage ?? "无法保存设置。") }
        try preferences.validate()
        defaults.set(try JSONEncoder().encode(preferences), forKey: Self.key)
        value = preferences; errorMessage = nil; onChange?()
    }
    public func setInterfaceLanguage(_ language: InterfaceLanguage) {
        defaults.set(language.rawValue, forKey: Self.languageKey)
        interfaceLanguage = language
        onChange?()
    }
}
