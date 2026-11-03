import Foundation
import Observation
import OfficeCore

@MainActor @Observable public final class AISettingsStore {
    public private(set) var value = AIConfiguration()
    public private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private var readable = true
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "office.ai.preferences.v1") {
            do { value = try JSONDecoder().decode(AIConfiguration.self, from: data); try value.validate() }
            catch { readable = false; errorMessage = "AI 设置无法读取，原值已保留。" }
        }
    }
    public func save(_ value: AIConfiguration) throws {
        guard readable else { throw OfficeError.invalid(errorMessage ?? "无法保存 AI 设置。") }
        try value.validate(); defaults.set(try JSONEncoder().encode(value), forKey: "office.ai.preferences.v1")
        self.value = value; errorMessage = nil
    }
}
