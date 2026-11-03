import Foundation

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai, deepseek, siliconflow, azureSpeech, aliyunTingwu
    public var id: String { rawValue }
    public var label: String { switch self {
    case .openai: "OpenAI"; case .deepseek: "DeepSeek"; case .siliconflow: "硅基流"
    case .azureSpeech: "微软 Azure Speech"; case .aliyunTingwu: "阿里通义听悟" } }
    public var supportsSpeech: Bool { self != .deepseek }
    public var supportsRealtime: Bool { [.openai, .azureSpeech, .aliyunTingwu].contains(self) }
    public var supportsFiles: Bool { self == .openai || self == .siliconflow }
    public var supportsTranslation: Bool { [.openai, .deepseek, .siliconflow].contains(self) }
    public var baseURL: URL? { switch self {
    case .openai: URL(string: "https://api.openai.com/v1/")
    case .deepseek: URL(string: "https://api.deepseek.com/")
    case .siliconflow: URL(string: "https://api.siliconflow.cn/v1/")
    default: nil } }
    public var defaultTextModel: String { switch self {
    case .openai: "gpt-4.1-mini"; case .deepseek: "deepseek-flash"
    case .siliconflow: "deepseek-ai/DeepSeek-V4-Flash"; default: "" } }
}
public enum TranslationDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case jaToZh, zhToJa
    public var id: Self { self }
    public var label: String { self == .jaToZh ? "日语 → 中文" : "中文 → 商务日语" }
    public var inputLanguage: String { self == .jaToZh ? "ja" : "zh" }
}
public enum RecognitionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese, japanese, mixed
    public var id: Self { self }
    public var label: String { switch self { case .chinese: "中文"; case .japanese: "日语"; case .mixed: "中日混合" } }
    public var code: String { self == .chinese ? "zh" : "ja" }
}
public struct GlossaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var source: String
    public var translation: String
    public init(source: String, translation: String) { self.source = source; self.translation = translation }
}
public struct AIConfiguration: Codable, Equatable, Sendable {
    public var speechProvider: AIProvider = .openai
    public var translationProvider: AIProvider = .deepseek
    public var realtimeModel = "gpt-live-transcribe"
    public var fileModel = "gpt-transcribe"
    public var siliconSpeechModel = "FunAudioLLM/SenseVoiceSmall"
    public var textModels: [String: String] = Dictionary(uniqueKeysWithValues: AIProvider.allCases.filter(\.supportsTranslation).map { ($0.rawValue, $0.defaultTextModel) })
    public var direction: TranslationDirection = .jaToZh
    public var mixedLanguages = false
    // Missing values preserve the behavior of settings and meetings saved before this option.
    public var translationEnabled: Bool?
    public var recognitionLanguage: RecognitionLanguage?
    public var glossary: [GlossaryEntry] = []
    public init() {}
    public var textModel: String { textModels[translationProvider.rawValue] ?? translationProvider.defaultTextModel }
    public var shouldTranslate: Bool { translationEnabled ?? true }
    public var effectiveRecognitionLanguage: RecognitionLanguage { recognitionLanguage ?? (mixedLanguages ? .mixed : (direction == .jaToZh ? .japanese : .chinese)) }
    public var modeLabel: String { shouldTranslate ? "转写并翻译" : "仅转写" }
    public func validate() throws {
        guard speechProvider.supportsSpeech else { throw OfficeError.invalid("所选服务不支持语音识别。") }
        if shouldTranslate {
            guard translationProvider.supportsTranslation else { throw OfficeError.invalid("所选服务不支持文字翻译。") }
            guard !textModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OfficeError.invalid("请填写翻译模型。") }
        }
        guard glossary.count <= 100, glossary.reduce(0, { $0 + $1.source.count + $1.translation.count }) <= 4096,
              glossary.allSatisfy({ !$0.source.isEmpty && $0.source.count <= 128 && $0.translation.count <= 128 }) else { throw OfficeError.invalid("术语最多 100 条，每项不超过 128 字，总计不超过 4096 字。") }
    }
}
