import Foundation
import Testing
@testable import OfficeCore

struct ProviderConfigurationTests {
    @Test func testProviderCapabilities() {
        #expect(!AIProvider.deepseek.supportsSpeech)
        #expect(AIProvider.azureSpeech.supportsRealtime)
        #expect(!AIProvider.azureSpeech.supportsFiles)
        #expect(!AIProvider.aliyunTingwu.supportsTranslation)
        #expect(AIProvider.siliconflow.supportsFiles)
    }
    @Test func testIndependentProviderSelection() throws {
        var config = AIConfiguration(); config.speechProvider = .aliyunTingwu; config.translationProvider = .deepseek
        try config.validate()
        #expect(config.speechProvider != config.translationProvider)
        config.translationProvider = .azureSpeech
        #expect(throws: (any Error).self) { try config.validate() }
    }
    @Test func testConfigurationDoesNotEncodeSecrets() throws {
        let json = String(data: try JSONEncoder().encode(AIConfiguration()), encoding: .utf8)!
        #expect(!json.contains("apiKey")); #expect(!json.contains("accessKeySecret"))
    }
    @Test func testTranscriptionOnlyDoesNotRequireTranslationConfiguration() throws {
        var config = AIConfiguration(); config.translationEnabled = false
        config.translationProvider = .azureSpeech; config.textModels[AIProvider.azureSpeech.rawValue] = ""
        try config.validate(); #expect(!config.shouldTranslate)
        config.translationEnabled = true
        #expect(throws: (any Error).self) { try config.validate() }
    }
    @Test func testLegacyConfigurationKeepsTranslationAndLanguage() throws {
        var config = AIConfiguration(); config.direction = .zhToJa
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "translationEnabled"); object.removeValue(forKey: "recognitionLanguage")
        let old = try JSONDecoder().decode(AIConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.shouldTranslate); #expect(old.effectiveRecognitionLanguage == .chinese)
        config.mixedLanguages = true
        #expect(config.effectiveRecognitionLanguage == .mixed)
    }
    @Test func testRecognitionLanguageIsIndependentOfTranslationDirection() throws {
        var config = AIConfiguration(); config.translationEnabled = false
        config.direction = .jaToZh; config.recognitionLanguage = .chinese
        let decoded = try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded.effectiveRecognitionLanguage == .chinese); #expect(!decoded.shouldTranslate)
    }
}
