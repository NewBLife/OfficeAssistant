import SwiftUI
import OfficeCore

@MainActor struct MeetingSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let importing: Bool
    let submit: (MeetingSetup) -> Void
    @State private var title: String
    @State private var participants = ""
    @State private var config: AIConfiguration
    @State private var scene = "面对面"
    @State private var mic = true
    @State private var micID: UInt32 = 0
    @State private var devices = MicrophoneDevice.available()
    @State private var sources: [SystemAudioSource] = []
    @State private var sourceID = ""
    @State private var loading = false
    @State private var retain = false
    @State private var error: String?
    init(configuration: AIConfiguration, importing: Bool, submit: @escaping (MeetingSetup) -> Void) {
        self.importing = importing; self.submit = submit
        _config = State(initialValue: configuration)
        _title = State(initialValue: "会议 " + Date().formatted(.dateTime.month().day().hour().minute()))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(importing ? "导入音频" : "开始会议记录").font(.title2.bold()); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(24)
            Form {
                Section("会议") {
                    TextField("标题", text: $title)
                    TextField("参与者备注（可选）", text: $participants)
                    Picker("记录模式", selection: Binding(get: { config.shouldTranslate }, set: { config.translationEnabled = $0 })) {
                        Text("仅转写").tag(false); Text("转写并翻译").tag(true)
                    }
                    Picker("识别服务", selection: $config.speechProvider) {
                        ForEach(AIProvider.allCases.filter(\.supportsSpeech)) { provider in
                            Text(provider.label + (importing && !provider.supportsFiles ? "（仅实时）" : "")).tag(provider)
                        }
                    }
                    if importing && !config.speechProvider.supportsFiles { Text("音频文件请选择 OpenAI 或硅基流。") .foregroundStyle(.orange) }
                    Picker("识别语言", selection: Binding(get: { config.effectiveRecognitionLanguage }, set: { config.recognitionLanguage = $0 })) {
                        ForEach(RecognitionLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    if config.shouldTranslate {
                        Picker("翻译服务", selection: $config.translationProvider) { ForEach(AIProvider.allCases.filter(\.supportsTranslation)) { Text($0.label).tag($0) } }
                        Picker("翻译方向", selection: $config.direction) { ForEach(TranslationDirection.allCases) { Text($0.label).tag($0) } }
                    }
                }
                if !importing {
                    Section("收音") {
                        Picker("场景", selection: $scene) { Text("面对面").tag("面对面"); Text("线上会议").tag("线上会议") }
                        Toggle("录入麦克风", isOn: $mic)
                        if mic {
                            Picker("麦克风", selection: $micID) {
                                Text("系统默认麦克风").tag(UInt32(0))
                                ForEach(devices) { Text($0.name).tag($0.id) }
                            }
                        }
                        if scene == "线上会议" {
                            Button(loading ? "正在读取…" : "读取可用的会议音源") {
                                loading = true
                                Task {
                                    defer { loading = false }
                                    do { sources = try await SystemAudioSource.available(); error = nil }
                                    catch { self.error = "无法读取音源，请允许系统音频录制权限后重试。" }
                                }
                            }.disabled(loading)
                            Picker("会议音源", selection: $sourceID) {
                                Text("请选择具体软件或显示器").tag("")
                                ForEach(sources) { Text($0.name).tag($0.id) }
                            }
                            Text("建议使用耳机，避免外放声音被麦克风重复录入。读取音源可能请求系统录制权限。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("在本机保留原始音频", isOn: $retain)
                    }
                }
                Section {
                    Text(config.shouldTranslate ? "音频发送到所选识别服务，原文发送到所选翻译服务。字幕记录保存在本机。请先保存相应凭证。" : "音频发送到所选识别服务，原文记录保存在本机。仅转写不调用翻译服务，只需配置识别服务凭证。")
                        .font(.callout).foregroundStyle(.secondary)
                    if config.speechProvider == .siliconflow { Text("硅基流会在短片段结束后识别；字幕延迟与原生流式服务不同。") .font(.caption).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button(importing ? "开始处理音频" : "开始识别") {
                var setup = MeetingSetup(title: title, configuration: config); setup.participants = participants
                setup.captureMicrophone = mic; setup.microphoneDeviceID = micID == 0 ? nil : micID
                setup.systemSource = scene == "线上会议" ? sources.first { $0.id == sourceID } : nil; setup.retainAudio = retain
                submit(setup); dismiss()
            }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (importing && !config.speechProvider.supportsFiles) || (!importing && !mic && (scene != "线上会议" || sourceID.isEmpty)) || (!importing && scene == "线上会议" && sourceID.isEmpty)) }.padding(20)
        }.frame(width: 590, height: 720)
    }
}
