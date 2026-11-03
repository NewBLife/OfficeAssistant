import Foundation
import Observation
import OfficeCore

@MainActor @Observable public final class PreferencesStore {
    public private(set) var value: AppPreferences
    public private(set) var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var canSave = true
    @ObservationIgnored public var onChange: (() -> Void)?
    private static let key = "office.preferences.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; value = AppPreferences()
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
}
