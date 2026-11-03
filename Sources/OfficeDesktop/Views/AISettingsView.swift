import SwiftUI
import OfficeCore

@MainActor public struct AISettingsView: View {
    let settings: AISettingsStore
    let credentials: any CredentialStore
    let locked: Bool
    @State private var draft = AIConfiguration()
    @State private var provider: AIProvider = .openai
    @State private var key = ""
    @State private var region = "japaneast"
    @State private var accessID = ""
    @State private var accessSecret = ""
    @State private var appKey = ""
    @State private var securityToken = ""
    @State private var glossaryText = ""
    @State private var saved: Set<AIProvider> = []
    @State private var models: [String] = []
    @State private var message: String?
    @State private var checking = false
    public init(settings: AISettingsStore, credentials: any CredentialStore, locked: Bool) { self.settings = settings; self.credentials = credentials; self.locked = locked }
    public var body: some View {
        Form {
            Section("识别与翻译") {
                Picker("默认记录模式", selection: Binding(get: { draft.shouldTranslate }, set: { draft.translationEnabled = $0 })) {
                    Text("仅转写").tag(false); Text("转写并翻译").tag(true)
                }
                Picker("语音识别", selection: $draft.speechProvider) {
                    ForEach(AIProvider.allCases.filter(\.supportsSpeech)) { Text($0.label + ($0 == .siliconflow ? "（分段）" : "（实时）")).tag($0) }
                }
                Picker("默认识别语言", selection: Binding(get: { draft.effectiveRecognitionLanguage }, set: { draft.recognitionLanguage = $0 })) {
                    ForEach(RecognitionLanguage.allCases) { Text($0.label).tag($0) }
                }
                if draft.shouldTranslate {
                    Picker("文字翻译", selection: $draft.translationProvider) { ForEach(AIProvider.allCases.filter(\.supportsTranslation)) { Text($0.label).tag($0) } }
                    Picker("默认方向", selection: $draft.direction) { ForEach(TranslationDirection.allCases) { Text($0.label).tag($0) } }
                }
                Text(draft.shouldTranslate ? "音频发送至选中的识别服务，原文与必要上下文发送至选中的翻译服务。记录保存在本机。" : "音频发送至选中的识别服务，原文保存在本机。不读取翻译凭证，不发送翻译请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("服务凭证") {
                Picker("配置服务", selection: $provider) { ForEach(AIProvider.allCases) { Text($0.label).tag($0) } }
                    .onChange(of: provider) { _, _ in clearSecrets(); models = []; message = nil }
                Label(saved.contains(provider) ? "凭证已保存，真实识别仍需验证" : "尚未保存凭证", systemImage: saved.contains(provider) ? "key.fill" : "key")
                if provider == .azureSpeech {
                    SecureField("Speech 资源密钥", text: $key)
                    TextField("资源区域，如 japaneast", text: $region)
                    Text("区域必须与这把 Speech 密钥对应。此项使用 Azure Speech 服务。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if provider == .aliyunTingwu {
                    SecureField("AccessKey ID", text: $accessID)
                    SecureField("AccessKey Secret", text: $accessSecret)
                    SecureField("听悟项目 AppKey", text: $appKey)
                    SecureField("STS SecurityToken（可选）", text: $securityToken)
                    Text("需要已开通的听悟服务和同账号项目 AppKey，普通百炼 API Key 不适用于这个接口。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { SecureField("API 密钥", text: $key) }
                Button("保存这家服务的凭证") { saveCredential() }
                Text("已有密钥不会回填。保存后输入框会清空，密钥保存在系统钥匙串。")
                    .font(.caption).foregroundStyle(.secondary)
                if provider.baseURL != nil {
                    Button(checking ? "正在检查…" : "检查连接并读取模型列表") {
                        checking = true
                        Task {
                            defer { checking = false }
                            do { models = try await ProviderModelClient(credentials: credentials).models(provider: provider); message = "连接成功，返回 \(models.count) 个模型。具体能力以所选模型为准。" }
                            catch { message = ProviderNetwork.safeError(error) }
                        }
                    }.disabled(checking || !saved.contains(provider))
                }
                if !models.isEmpty {
                    Text(models.prefix(40).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            Section("模型") {
                TextField("OpenAI 实时转写模型", text: $draft.realtimeModel)
                TextField("OpenAI 文件转写模型", text: $draft.fileModel)
                TextField("硅基流语音模型", text: $draft.siliconSpeechModel)
                if draft.shouldTranslate {
                    ForEach(AIProvider.allCases.filter(\.supportsTranslation)) { provider in
                        TextField("\(provider.label)翻译模型", text: Binding(get: { draft.textModels[provider.rawValue] ?? provider.defaultTextModel }, set: { draft.textModels[provider.rawValue] = $0 }))
                    }
                }
            }
            Section("会议术语") {
                Text("每行填写 原词=译法，例如 納期=交货日期。最多 100 条，总计 4096 字。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $glossaryText).font(.body.monospaced()).frame(minHeight: 100)
            }
            Section {
                Button("保存 AI 设置") {
                    do {
                        draft.glossary = try glossaryText.split(separator: "\n").map { line in
                            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                            guard pair.count == 2, !pair[0].isEmpty else { throw OfficeError.invalid("每行术语请使用 原词=译法。") }
                            return GlossaryEntry(source: pair[0], translation: pair[1])
                        }
                        try settings.save(draft); message = "AI 设置已保存。"
                    } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
                if locked { Text("记录进行中，配置已暂时锁定。请先结束记录。")
                    .font(.caption).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped).disabled(locked)
            .onAppear {
                draft = settings.value; glossaryText = draft.glossary.map { "\($0.source)=\($0.translation)" }.joined(separator: "\n")
                for item in AIProvider.allCases { if (try? credentials.contains(item)) == true { saved.insert(item) } }
            }
            .onDisappear { clearSecrets() }
    }
    private func clearSecrets() { key = ""; accessID = ""; accessSecret = ""; appKey = ""; securityToken = "" }
    private func saveCredential() {
        do {
            let data: Data
            if provider == .azureSpeech { data = try JSONEncoder().encode(AzureSpeechCredentials(key: key.trimmingCharacters(in: .whitespacesAndNewlines), region: region.trimmingCharacters(in: .whitespacesAndNewlines))) }
            else if provider == .aliyunTingwu { data = try JSONEncoder().encode(TingwuCredentials(accessKeyID: accessID.trimmingCharacters(in: .whitespacesAndNewlines), accessKeySecret: accessSecret.trimmingCharacters(in: .whitespacesAndNewlines), appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines), securityToken: securityToken.isEmpty ? nil : securityToken.trimmingCharacters(in: .whitespacesAndNewlines))) }
            else { data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8) }
            try credentials.save(data, for: provider); saved.insert(provider); clearSecrets(); message = "凭证已保存到系统钥匙串。"
        } catch { message = error.localizedDescription }
    }
}
