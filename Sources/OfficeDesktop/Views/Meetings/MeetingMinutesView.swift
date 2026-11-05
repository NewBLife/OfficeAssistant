import SwiftUI
import OfficeCore

private enum MinutesSheet: String, Identifiable { case generate, edit, export; var id: Self { self } }
@MainActor struct MeetingMinutesView: View {
    let meeting: MeetingSession; let coordinator: MinutesCoordinator; let settings: AISettingsStore
    let recording: Bool; let hasBuffered: Bool; let imported: Bool
    let tasks: TaskStore?; let links: MeetingTaskLinkService?; let preferences: AppPreferences
    let openTask: (TaskItem) -> Void; let openMeeting: (UUID, EvidenceReference?) -> Void
    var groups: GroupStore? = nil
    @State private var documents: [MinutesDocument] = []; @State private var selected: UUID?
    @State private var sheet: MinutesSheet?; @State private var error: String?; @State private var incrementalChoice = false
    private var document: MinutesDocument? { documents.first { $0.id == selected } ?? documents.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(documents.isEmpty ? "生成会议纪要" : "生成新版本") { incrementalChoice = false; sheet = .generate }.buttonStyle(.borderedProminent).disabled(recording || coordinator.isRunning)
                if recording {
                    Button(coordinator.incrementalEnabled(meetingID: meeting.id) ? "关闭会议中提取" : "会议中提取行动项") {
                        if coordinator.incrementalEnabled(meetingID: meeting.id) { coordinator.recordingStopped(meetingID: meeting.id) }
                        else { incrementalChoice = true; sheet = .generate }
                    }
                }
                Spacer()
                Button("编辑纪要") { sheet = .edit }.disabled(document == nil)
                Button("导出纪要") { sheet = .export }.disabled(document == nil)
            }.padding(16)
            if coordinator.isRunning && coordinator.currentJob?.meetingID == meeting.id {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("已完成 \(coordinator.completedChunks)/\(coordinator.totalChunks) 段").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消生成") { coordinator.cancel(meetingID: meeting.id) }
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            if !documents.isEmpty {
                Picker("历史版本", selection: $selected) {
                    ForEach(documents) { item in Text("版本 \(item.revision) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))\(item.editedByUser ? " · 已校对" : "")").tag(Optional(item.id)) }
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            if recording { Text("完整纪要请在暂停或结束记录后生成；会议中提取只产生待审阅候选。").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            if hasBuffered { Text("仍有暂存音频，纪要仅涵盖已经保存的定稿原文。").font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            if let error, coordinator.currentJob?.meetingID != meeting.id || error != coordinator.errorMessage { Text(error).foregroundStyle(.orange).padding(.horizontal).textSelection(.enabled) }
            if coordinator.currentJob?.meetingID == meeting.id, let message = coordinator.errorMessage { Text(message).font(.callout).foregroundStyle(.orange).padding(.horizontal) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let doc = document {
                        if coordinator.isStale(doc) { Label("原文已更新，本版本需要重新核对。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        Text(meeting.title).font(.title2.bold())
                        Text(doc.overviewZH).textSelection(.enabled)
                        if let ja = doc.overviewJA { Text(ja).foregroundStyle(.secondary).textSelection(.enabled) }
                        pointSection("议题摘要", doc.topics); pointSection("明确决定", doc.decisions); pointSection("未解决问题", doc.openQuestions)
                    } else { ContentUnavailableView("等待生成会议纪要", systemImage: "doc.text", description: Text("根据已保存的最终原文生成摘要、决定、问题和行动项。仅转写会议也可使用。")) }
                    MeetingActionsView(meeting: meeting, coordinator: coordinator, tasks: tasks, links: links, preferences: preferences, showCandidates: true, openTask: openTask, openMeeting: openMeeting, groups: groups)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.onAppear(perform: load).onChange(of: coordinator.changeCount) { _, _ in load() }
            .sheet(item: $sheet) { item in
                switch item {
                case .generate:
                    MinutesOptionsView(meeting: meeting, settings: settings, timeZoneID: preferences.timeZoneID, imported: imported, incremental: incrementalChoice) { options in
                        if incrementalChoice { coordinator.setIncrementalExtraction(true, meetingID: meeting.id, options: options) }
                        else {
                            error = nil
                            Task { do { try await coordinator.generate(meetingID: meeting.id, options: options) } catch { self.error = ProviderNetwork.safeError(error) } }
                        }
                    }
                case .edit:
                    if let document { MinutesEditor(document: document) { try coordinator.saveEdit($0) } }
                case .export:
                    if let document { MinutesExportOptions(document: document) { language, format in
                        let taskSnapshot = tasks?.items ?? []
                        Task {
                            do {
                                var exportDocument = document; exportDocument.meetingTitle = meeting.title
                                let text = try MinutesExportRenderer.render(document: exportDocument, candidates: coordinator.candidates(meetingID: meeting.id), linkedTasks: taskSnapshot, language: language, format: format)
                                _ = try await MinutesFileExporter().export(text: text, suggestedName: meeting.title + "-会议纪要", format: format)
                            } catch { self.error = ProviderNetwork.safeError(error) }
                        }
                    } }
                }
            }
    }
    @ViewBuilder private func pointSection(_ title: String, _ values: [MinutesPoint]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if values.isEmpty { Text("无已记录内容").foregroundStyle(.secondary) }
            ForEach(values) { point in
                VStack(alignment: .leading, spacing: 5) {
                    Text("• " + point.textZH).textSelection(.enabled)
                    if let ja = point.textJA { Text(ja).foregroundStyle(.secondary).textSelection(.enabled) }
                    ForEach(point.evidence) { ref in Button { openMeeting(meeting.id, ref) } label: { Text("\(ref.segmentID.source.label) \(Int(ref.sourceStartSeconds))秒：\(ref.quote)").font(.caption).multilineTextAlignment(.leading) }.buttonStyle(.link) }
                }
            }
        }
    }
    private func load() { do { documents = try coordinator.documents(meetingID: meeting.id); selected = documents.first?.id; error = nil } catch { self.error = "纪要无法读取，原记录已保留。" } }
}

@MainActor private struct MinutesOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var options: MinutesOptions; @State private var knownDate: Bool; @State private var reference: Date
    let settings: AISettingsStore; let incremental: Bool; let submit: (MinutesOptions) -> Void
    init(meeting: MeetingSession, settings: AISettingsStore, timeZoneID: String, imported: Bool, incremental: Bool, submit: @escaping (MinutesOptions) -> Void) {
        self.settings = settings; self.incremental = incremental; self.submit = submit
        let config = settings.value; let options = MinutesOptions(provider: config.translationProvider, model: config.textModel, timeZoneID: timeZoneID, referenceDate: imported ? nil : meeting.startedAt)
        _options = State(initialValue: options); _knownDate = State(initialValue: !imported); _reference = State(initialValue: meeting.startedAt)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(incremental ? "会议中提取行动项" : "生成会议纪要").font(.title2.bold())
            Form {
                Picker("纪要服务", selection: $options.provider) { ForEach(AIProvider.allCases.filter(\.supportsTranslation)) { Text(LocalizedStringKey($0.label)).tag($0) } }
                    .onChange(of: options.provider) { _, provider in options.model = settings.value.textModels[provider.rawValue] ?? provider.defaultTextModel }
                TextField("文字模型", text: $options.model)
                Picker("纪要语言", selection: $options.language) { ForEach(MinutesLanguage.allCases) { Text(LocalizedStringKey($0.label)).tag($0) } }
                Toggle("已知实际会议时间", isOn: $knownDate)
                if knownDate { DatePicker("实际会议开始", selection: $reference).environment(\.timeZone, TimeZone(identifier: options.timeZoneID) ?? .current) }
                TextField("会议时区", text: $options.timeZoneID)
                Text("导入时间不等于录音实际日期。日期未知时，“明天/下周”等时间保留为待确认，不自动设置提醒。").font(.caption).foregroundStyle(.secondary)
                Text("本次原文和会议备注将发送至所选纪要服务；不发送其他会议或待办库。候选需确认后才加入待办。").font(.callout)
                Text("支持 2 小时会议；超过 2 小时自动分段处理并合并纪要。长会议可能需要数分钟。").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack { Button("取消") { dismiss() }; Spacer(); Button(incremental ? "开启提取" : "开始生成") {
                options.referenceDate = knownDate ? reference : nil; submit(options); dismiss()
            }.buttonStyle(.borderedProminent).disabled(options.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || TimeZone(identifier: options.timeZoneID) == nil) }
        }.padding(24).frame(width: 580, height: 570)
    }
}
@MainActor private struct MinutesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MinutesDocument; @State private var error: String?
    let save: (MinutesDocument) throws -> Void
    init(document: MinutesDocument, save: @escaping (MinutesDocument) throws -> Void) { _draft = State(initialValue: document); self.save = save }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("校对会议纪要").font(.title2.bold())
            Form {
                Section("中文概述") { TextEditor(text: $draft.overviewZH).frame(minHeight: 120) }
                if draft.options.language == .chineseJapanese { Section("日文概述") { TextEditor(text: Binding(get: { draft.overviewJA ?? "" }, set: { draft.overviewJA = $0 })).frame(minHeight: 100) } }
                Section("议题摘要") { ForEach($draft.topics) { $point in pointEditor($point) } }
                Section("明确决定") { ForEach($draft.decisions) { $point in pointEditor($point) } }
                Section("未解决问题") { ForEach($draft.openQuestions) { $point in pointEditor($point) } }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack { Button("取消") { dismiss() }; Spacer(); Text("保存为新版本，原版本保留").font(.caption).foregroundStyle(.secondary); Button("保存纪要") { do { try save(draft); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(draft.overviewZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 650, height: 700)
    }
    @ViewBuilder private func pointEditor(_ point: Binding<MinutesPoint>) -> some View {
        TextField("中文", text: point.textZH, axis: .vertical)
        if draft.options.language == .chineseJapanese { TextField("日文", text: Binding(get: { point.wrappedValue.textJA ?? "" }, set: { point.wrappedValue.textJA = $0 }), axis: .vertical) }
    }
}
@MainActor private struct MinutesExportOptions: View {
    @Environment(\.dismiss) private var dismiss
    @State private var language: MinutesLanguage; @State private var format: MinutesExportFormat = .markdown
    let submit: (MinutesLanguage, MinutesExportFormat) -> Void
    init(document: MinutesDocument, submit: @escaping (MinutesLanguage, MinutesExportFormat) -> Void) { _language = State(initialValue: document.options.language); self.submit = submit }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导出会议纪要").font(.title2.bold())
            Picker("语言", selection: $language) { ForEach(MinutesLanguage.allCases) { Text(LocalizedStringKey($0.label)).tag($0) } }
            Picker("文件格式", selection: $format) { ForEach(MinutesExportFormat.allCases) { Text(LocalizedStringKey($0.label)).tag($0) } }
            Text("导出所选纪要版本、行动项和当前关联任务状态。此操作不调用 AI。").font(.callout).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("选择保存位置") { submit(language, format); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 470)
    }
}
