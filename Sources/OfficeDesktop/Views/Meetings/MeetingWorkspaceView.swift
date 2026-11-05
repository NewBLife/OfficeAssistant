import SwiftUI
import UniformTypeIdentifiers
import OfficeCore

@MainActor public struct MeetingWorkspaceView: View {
    @Bindable var controller: MeetingSessionController
    let groups: GroupStore?
    let scope: GroupScope
    let defaultGroupID: UUID?
    @State private var meetingSearch = ""
    let settings: AISettingsStore
    let minutes: MinutesCoordinator?; let tasks: TaskStore?; let links: MeetingTaskLinkService?; let preferences: AppPreferences
    let focus: EvidenceReference?; let sourceRequestID: UUID?; let openTask: (TaskItem) -> Void; let openMeeting: (UUID, EvidenceReference?) -> Void
    @State private var deleting: MeetingSession?
    @State private var deleteAudio = false
    @State private var exportingAudio = false
    @State private var tab = "转写"
    @State private var setupPresented = false
    @State private var renaming: MeetingSession?
    @State private var filePicker = false
    @State private var pickingRecovery = false
    @State private var importedURL: URL?
    @State private var resumeChoice = false
    @State private var error: String?
    public init(controller: MeetingSessionController, settings: AISettingsStore, minutes: MinutesCoordinator? = nil, tasks: TaskStore? = nil, links: MeetingTaskLinkService? = nil, preferences: AppPreferences = AppPreferences(), focus: EvidenceReference? = nil, sourceRequestID: UUID? = nil, openTask: @escaping (TaskItem) -> Void = { _ in }, openMeeting: @escaping (UUID, EvidenceReference?) -> Void = { _, _ in }, groups: GroupStore? = nil, scope: GroupScope = .all, defaultGroupID: UUID? = nil) {
        self.groups = groups; self.scope = scope; self.defaultGroupID = defaultGroupID
        self.controller = controller; self.settings = settings; self.minutes = minutes; self.tasks = tasks; self.links = links; self.preferences = preferences
        self.focus = focus; self.sourceRequestID = sourceRequestID; self.openTask = openTask; self.openMeeting = openMeeting
    }
    public var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("会议记录").font(.title.bold()).fixedSize()
                    Spacer(minLength: 12)
                    meetingCreationActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("会议记录").font(.title.bold())
                    meetingCreationActions
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(24)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    TextField("搜索会议标题", text: $meetingSearch).textFieldStyle(.roundedBorder).padding(10)
                    Text("\(visibleHistory.count) 场会议").font(.caption).foregroundStyle(.secondary)
                    List(visibleHistory) { item in
                    Button {
                        do { try controller.open(item) } catch { self.error = error.localizedDescription }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            if let groups { Text(groups.isLoaded ? GroupRules.path(item.groupID, groups: groups.groups) : "分组暂时不可用").font(.caption).foregroundStyle(.secondary) }
                            Text(item.title).font(.headline).lineLimit(2); Text(item.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption); Text(LocalizedStringKey(item.state.label)).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.borderless).disabled(controller.isActive)
                    .contextMenu {
                        if let groups { GroupMoveMenu(groups: groups, currentID: item.groupID) { try controller.moveToGroup(id: item.id, groupID: $0) }.disabled(controller.isActive && controller.meeting?.id == item.id) }
                        Button("修改会议名称") { renaming = item }
                        Button("删除会议", role: .destructive) { deleteAudio = false; deleting = item }
                            .disabled(controller.isActive)
                    }
                    }
                }.frame(minWidth: 175, idealWidth: 210, maxWidth: 260)
                detail.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.sheet(isPresented: $setupPresented) {
            MeetingSetupView(configuration: settings.value, importing: importedURL != nil, groups: groups, defaultGroupID: defaultGroupID) { setup in
                let url = importedURL
                Task {
                    do { if let url { try await controller.importAudio(url: url, setup: setup) } else { try await controller.start(setup) } }
                    catch { self.error = ProviderNetwork.safeError(error) }
                }
            }
        }
        .sheet(item: $renaming) { item in
            MeetingTitleEditor(meeting: item) { title in try controller.rename(item.id, title: title) }
        }
        .sheet(item: $deleting) { item in
            VStack(alignment: .leading, spacing: 18) {
                Text("删除会议？").font(.title2.bold())
                Text("“\(item.title)”的转写、纪要及候选行动项将被删除，已加入的待办会保留。此操作无法撤销。")
                if !item.audioFiles.isEmpty { Toggle("同时删除本机保留的音频", isOn: $deleteAudio) }
                HStack {
                    Spacer()
                    Button("取消") { deleting = nil }.keyboardShortcut(.cancelAction)
                    Button("删除", role: .destructive) {
                        do {
                            minutes?.forget(meetingID: item.id)
                            try controller.delete(item.id, includingAudio: deleteAudio)
                        } catch { self.error = error.localizedDescription }
                        deleting = nil
                    }.disabled(controller.isActive || exportingAudio)
                }
            }.padding(24).frame(width: 420)
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.audio]) { result in
            do {
                let url = try result.get()
                if pickingRecovery {
                    Task { do { try await controller.restoreImport(url: url) } catch { self.error = ProviderNetwork.safeError(error) } }
                } else { importedURL = url; setupPresented = true }
            } catch { self.error = pickingRecovery ? "未能选择原音频文件。" : "未能选择音频文件。" }
        }
        .confirmationDialog("继续记录前如何处理暂存音频？", isPresented: $resumeChoice) {
            if controller.meeting?.configuration.speechProvider.supportsFiles == true {
                Button("识别暂存音频后继续") { resume(process: true) }
            }
            Button("放弃暂存音频并继续", role: .destructive) { resume(process: false) }
            Button("取消", role: .cancel) {}
        }
        .alert("会议操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        .onChange(of: controller.meeting?.id) { _, _ in tab = "转写" }
        .onChange(of: scope) { _, _ in
            if !controller.isActive, !controller.canProcessBuffered,
               !visibleHistory.contains(where: { $0.id == controller.meeting?.id }), let first = visibleHistory.first {
                do { try controller.open(first) } catch { self.error = error.localizedDescription }
            }
        }
        .onChange(of: sourceRequestID) { _, _ in tab = "转写" }
    }
    private var meetingCreationActions: some View {
        HStack {
            Button("导入音频") { pickingRecovery = false; filePicker = true }
            Button { importedURL = nil; setupPresented = true } label: { Label("新建会议", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }.fixedSize().disabled(controller.isActive || controller.canProcessBuffered)
    }
    private var visibleHistory: [MeetingSession] {
        if let groups, !groups.isLoaded { return scope == .all ? controller.history.filter { meetingSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(meetingSearch) } : [] }
        return GroupContentFilter.meetings(controller.history, scope: scope, groups: groups?.groups ?? [], search: meetingSearch)
    }
    private func inScope(_ meeting: MeetingSession) -> Bool {
        scope == .all || GroupRules.matches(meeting.groupID, scope: scope, groups: groups?.groups ?? [])
    }
    @ViewBuilder private var detail: some View {
        if let meeting = controller.meeting, inScope(meeting) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(meeting.title).font(.title2.bold()).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { renaming = meeting } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("修改会议名称").accessibilityLabel("修改会议名称")
                        Spacer()
                        Text(LocalizedStringKey(meeting.state.label)).foregroundStyle(controller.isActive ? .red : .secondary).fixedSize()
                        Button(role: .destructive) { deleteAudio = false; deleting = meeting } label: { Label("删除会议", systemImage: "trash") }
                            .disabled(controller.isActive || exportingAudio).fixedSize()
                    }
                    if let groups {
                        HStack {
                            Text(groups.isLoaded ? GroupRules.path(meeting.groupID, groups: groups.groups) : "分组暂时不可用").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            GroupMoveMenu(groups: groups, currentID: meeting.groupID) { try controller.moveToGroup(id: meeting.id, groupID: $0) }.disabled(controller.isActive)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(meeting.configuration.speechProvider.label))
                        Text("识别")
                        Text("·")
                        if meeting.configuration.shouldTranslate {
                            Text(LocalizedStringKey(meeting.configuration.translationProvider.label))
                            Text("翻译")
                            Text("·")
                            Text(LocalizedStringKey(meeting.configuration.direction.label))
                        } else {
                            Text("仅转写")
                            Text("·")
                            Text(LocalizedStringKey(meeting.configuration.effectiveRecognitionLanguage.label))
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if controller.isActive {
                        TimelineView(.periodic(from: Date(), by: 1)) { context in
                            HStack { Image(systemName: "record.circle").foregroundStyle(.red); Text("\(Int(max(0, context.date.timeIntervalSince(meeting.startedAt)))) 秒").monospacedDigit()
                                ForEach(Array(controller.levels.keys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                                    Text(LocalizedStringKey(source.label)).font(.caption); ProgressView(value: controller.levels[source] ?? 0).frame(width: 70)
                                }
                            }
                        }
                    }
                    HStack {
                        if controller.starting { ProgressView().controlSize(.small); Text("正在连接或处理…").font(.caption) }
                        if controller.isActive {
                            Button("暂停") { Task { await controller.pause() } }.disabled(controller.starting)
                            Button("停止记录", role: .destructive) { Task { await controller.stop() } }
                        } else if controller.canResume {
                            Button("继续记录") { if controller.canProcessBuffered { resumeChoice = true } else { resume(process: false) } }
                        } else if (meeting.state == .paused || meeting.state == .interrupted), meeting.importIdentity != nil {
                            Button("选择原音频恢复导入") { pickingRecovery = true; filePicker = true }.disabled(controller.canProcessBuffered)
                        }
                        if controller.canProcessBuffered {
                            Text("暂存 \(Int(controller.bufferedSeconds)) 秒").font(.caption).foregroundStyle(.secondary)
                            Button("处理未完成片段") { Task { do { try await controller.processUnfinishedAudio() } catch { self.error = ProviderNetwork.safeError(error) } } }
                                .disabled(!meeting.configuration.speechProvider.supportsFiles)
                            Button("放弃暂存", role: .destructive) { controller.discardBuffered() }
                        }
                    }
                    if !controller.isActive && !controller.canResume && meeting.importIdentity == nil && (meeting.state == .paused || meeting.state == .interrupted) {
                        Text("音源选择不会跨重启保留。继续录音请新建会议并重新选择音源，已有字幕保留在本页。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = controller.errorMessage { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if !meeting.audioFiles.isEmpty {
                        HStack {
                            Button(exportingAudio ? "正在导出…" : "导出音频") {
                                exportingAudio = true
                                Task {
                                    defer { exportingAudio = false }
                                    do { try await MeetingAudioExporter.export(meeting) }
                                    catch { self.error = error.localizedDescription }
                                }
                            }.disabled(controller.isActive || exportingAudio)
                            Button("查看本机录音") {
                                do { NSWorkspace.shared.open(try AudioArchive.folder()) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    } else {
                        Text("未保留原始音频，无法导出。新建或导入时可勾选“在本机保留原始音频”。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if controller.hasUnclosedRemoteTasks {
                        Button("清理待关闭的听悟云端任务") { Task { await controller.cleanupRemoteTasks() } }.disabled(controller.isActive)
                    }
                    Picker("会议内容", selection: $tab) { Text("转写").tag("转写"); Text("会议纪要").tag("会议纪要"); Text("相关待办").tag("相关待办") }.pickerStyle(.segmented)
                }.padding(22)
                Divider()
                if tab == "转写" {
                    ScrollViewReader { proxy in
                        ScrollView {
                            if controller.segments.isEmpty { ContentUnavailableView("等待会议内容", systemImage: "waveform", description: Text(meeting.configuration.shouldTranslate ? "开始记录后，这里会逐步显示原文与译文。" : "开始记录后，这里会逐步显示转写原文。")) }
                            else { TranscriptView(controller: controller, settings: settings, focus: focus?.segmentID.meetingID == meeting.id ? focus : nil).padding(20) }
                        }.onAppear { if let focus, focus.segmentID.meetingID == meeting.id { proxy.scrollTo(focus.segmentID, anchor: .center) } }
                            .onChange(of: sourceRequestID) { _, _ in if let focus, focus.segmentID.meetingID == meeting.id { proxy.scrollTo(focus.segmentID, anchor: .center) } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
                } else if let minutes {
                    if tab == "会议纪要" {
                        MeetingMinutesView(meeting: meeting, coordinator: minutes, settings: settings, recording: controller.isActive, hasBuffered: controller.canProcessBuffered, imported: meeting.importIdentity != nil || controller.segments.contains { $0.id.source == .file }, tasks: tasks, links: links, preferences: preferences, openTask: openTask, openMeeting: openMeeting, groups: groups)
                    } else {
                        ScrollView { MeetingActionsView(meeting: meeting, coordinator: minutes, tasks: tasks, links: links, preferences: preferences, showCandidates: false, openTask: openTask, openMeeting: openMeeting, groups: groups).padding(22) }
                    }
                } else { ContentUnavailableView("纪要暂时不可用", systemImage: "doc.text", description: Text("请重启应用后重试，原记录不会被清空。")) }
            }
        } else {
            ContentUnavailableView("记录与翻译你的会议", systemImage: "waveform", description: Text("选择“新建会议”收听麦克风或线上会议，也可以导入音频。首次使用请先在 AI 服务中配置凭证。"))
        }
    }
    private func resume(process: Bool) {
        Task { do { try await controller.resume(processBufferedAudio: process) } catch { self.error = ProviderNetwork.safeError(error) } }
    }
}

@MainActor private struct MeetingTitleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var error: String?
    let meeting: MeetingSession
    let save: (String) throws -> Void
    init(meeting: MeetingSession, save: @escaping (String) throws -> Void) {
        self.meeting = meeting; self.save = save; _title = State(initialValue: meeting.title)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("修改会议名称").font(.title2.bold())
            TextField("会议名称", text: $title).textFieldStyle(.roundedBorder).onSubmit(saveTitle)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { saveTitle() }.buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200)
            }
        }.padding(24).frame(width: 420)
    }
    private func saveTitle() {
        do { try save(title); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
