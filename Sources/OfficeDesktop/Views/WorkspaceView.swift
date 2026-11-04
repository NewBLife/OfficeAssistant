import SwiftUI
import OfficeCore

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case today, all, completed, meetings, ai, settings, groups
    var id: Self { self }
    var title: String { switch self { case .today: "今天"; case .all: "全部待办"; case .completed: "已完成"; case .meetings: "会议记录"; case .ai: "AI 服务"; case .settings: "设置"; case .groups: "分组" } }
    var icon: String { switch self { case .today: "sun.max"; case .all: "checklist"; case .completed: "checkmark.circle"; case .meetings: "waveform"; case .ai: "sparkles"; case .settings: "gearshape"; case .groups: "folder" } }
}

@MainActor public struct WorkspaceView: View {
    @Bindable var model: OfficeAppModel
    @Environment(\.openWindow) private var openWindow
    @State private var section: WorkspaceSection? = .today
    @State private var groupScope: GroupScope = .all
    @State private var search = ""
    @State private var statusFilter = "全部状态"
    @State private var editing: TaskItem?
    @State private var sourceError: String?
    public init(model: OfficeAppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            sidebar.navigationTitle("办公助手").navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 260)
                .safeAreaInset(edge: .bottom) {
                    HStack { Image(systemName: "externaldrive"); Text("记录保存在这台 Mac") }.font(.caption).foregroundStyle(.secondary).padding(16)
                }
        } detail: {
            if section == .groups { GroupWorkspaceView(model: model, scope: groupScope, openTask: { editing = $0 }, openMeeting: openSource) }
            else if section == .settings { SettingsView(model: model) }
            else if section == .ai { AISettingsView(settings: model.aiSettings, credentials: model.credentials, locked: model.meetings?.isActive ?? false) }
            else if section == .meetings {
                if let meetings = model.meetings { MeetingWorkspaceView(controller: meetings, settings: model.aiSettings, minutes: model.minutes, tasks: model.store, links: model.meetingLinks, preferences: model.preferences.value, focus: model.requestedEvidence, sourceRequestID: model.meetingSourceRequestID, openTask: { editing = $0 }, openMeeting: openSource, groups: model.groups) }
                else { ContentUnavailableView("会议记录暂时无法打开", systemImage: "externaldrive.badge.exclamationmark", description: Text("请重启应用重试，原有记录已保留。")) }
            } else if let store = model.store {
                taskWorkspace(store)
            } else {
                VStack(spacing: 18) {
                    ContentUnavailableView("暂时无法打开待办", systemImage: "externaldrive.badge.exclamationmark", description: Text(model.errorMessage ?? "本地数据未能读取，原有文件已保留。"))
                    Button("重试读取") { model.openStore() }
                }
            }
        }.frame(minWidth: 900, minHeight: 640)
            .sheet(item: $editing) { item in
                if let store = model.store { TaskEditorView(item: item, store: store, preferences: model.preferences.value, groups: model.groups) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .officeNewTask)) { _ in newTask() }
            .onReceive(NotificationCenter.default.publisher(for: .officeShowToday)) { _ in section = .today }
            .onAppear { model.openWorkspace = { openWindow(id: "workspace") }; consumeRequests() }
            .onChange(of: model.wantsNewTask) { _, _ in consumeRequests() }
            .onChange(of: model.wantsToday) { _, _ in consumeRequests() }
            .onChange(of: model.wantsMeetingID) { _, _ in consumeRequests() }
            .alert("无法打开来源会议", isPresented: Binding(get: { sourceError != nil }, set: { if !$0 { sourceError = nil } })) { Button("好") { sourceError = nil } } message: { Text(sourceError ?? "") }
    }
    private var sidebar: some View {
        List {
            Section("待办") {
                ForEach([WorkspaceSection.today, .all, .completed]) { entry in navigationRow(entry) }
            }
            Section("工作空间") {
                ForEach([WorkspaceSection.meetings, .ai, .settings]) { entry in navigationRow(entry) }
            }
            GroupSidebarView(groups: model.groups, selection: $groupScope, active: section == .groups) { section = .groups }
        }.listStyle(.sidebar)
    }
    private func navigationRow(_ entry: WorkspaceSection) -> some View {
        Button { section = entry } label: {
            HStack {
                Label(entry.title, systemImage: entry.icon); Spacer()
                if entry == .today { Text("\(model.todayCount)").foregroundStyle(.secondary).monospacedDigit() }
            }.padding(.vertical, 5).padding(.horizontal, 3)
                .background(section == entry ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func taskWorkspace(_ store: TaskStore) -> some View {
        VStack(spacing: 0) {
            if model.notificationStatus != .authorized {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                    Text(model.notificationStatus == .denied ? "系统通知已关闭，待办仍会正常保存。" : "开启系统通知，接收到期提醒与每日汇总。")
                    Spacer()
                    Button(model.notificationStatus == .denied ? "前往系统设置" : "开启提醒") {
                        if model.notificationStatus == .denied { model.showNotificationSettings() }
                        else { Task { await model.enableNotifications() } }
                    }
                }.font(.callout).padding(14).background(Color.accentColor.opacity(0.08))
            }
            if let message = store.errorMessage ?? model.errorMessage {
                HStack { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange); Spacer()
                    if !store.isLoaded { Button("重试") { do { try store.reload() } catch { model.errorMessage = error.localizedDescription } } }
                }.padding(12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section?.title ?? "今天").font(.system(size: 30, weight: .bold))
                            Text(dateCaption).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: newTask) { Label("新增待办", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.isLoaded)
                    }
                    if section == .today {
                        HStack(spacing: 14) {
                            metric("今日待处理", value: todayItems(store).count, icon: "checklist", color: .blue)
                            metric("已逾期", value: store.items.filter { $0.status != .completed && ($0.dueAt.map { $0 < model.now } ?? false) }.count, icon: "clock", color: .orange)
                            metric("已完成", value: store.items.filter { $0.status == .completed }.count, icon: "checkmark.circle", color: .green)
                        }
                    }
                    HStack {
                        TextField("搜索标题、备注或负责人", text: $search).textFieldStyle(.roundedBorder)
                        if section == .all {
                            Picker("状态", selection: $statusFilter) { ForEach(["全部状态", "待处理", "进行中", "已完成"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 125)
                        }
                    }
                    let listed = filteredItems(store)
                    if listed.isEmpty {
                        ContentUnavailableView(search.isEmpty ? (section == .completed ? "还没有已完成事项" : "暂时没有待办") : "没有匹配的事项",
                                               systemImage: section == .completed ? "checkmark.circle" : "checklist",
                                               description: Text(search.isEmpty ? "点击“新增待办”，记录下一件要做的事。" : "试试其他标题、备注或负责人。"))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        TaskListView(items: listed, store: store, now: model.now, openMeeting: openSource, groups: model.groups) { editing = $0 }
                    }
                    if section == .today {
                        let undated = matching(store.items.filter { $0.status != .completed && $0.dueAt == nil })
                        if !undated.isEmpty {
                            Text("未安排时间 · \(undated.count)").font(.headline).foregroundStyle(.secondary)
                            TaskListView(items: undated, store: store, now: model.now, openMeeting: openSource, groups: model.groups) { editing = $0 }
                        }
                    }
                }.padding(30).frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
    }
    private func metric(_ title: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) { Text("\(value)").font(.title2.bold()).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
    private var dateCaption: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: model.preferences.value.timeZoneID); formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: model.now)
    }
    private func newTask() {
        guard model.store?.isLoaded == true else { return }
        var draft = TaskItem(title: "", timeZoneID: model.preferences.value.timeZoneID)
        if section == .groups { draft.groupID = groupScope.defaultGroupID }
        editing = draft
    }
    private func consumeRequests() {
        if model.wantsMeetingID != nil { section = .meetings; model.wantsMeetingID = nil }
        if model.wantsToday { section = .today; model.wantsToday = false }
        if model.wantsNewTask { newTask(); model.wantsNewTask = false }
    }
    private func openSource(_ id: UUID, _ evidence: EvidenceReference?) { do { try model.openMeeting(id: id, evidence: evidence) } catch { sourceError = error.localizedDescription } }
    private func todayItems(_ store: TaskStore) -> [TaskItem] { store.items.filter { TaskRules.isTodayOrOverdue($0, now: model.now, displayTimeZoneID: model.preferences.value.timeZoneID) } }
    private func matching(_ values: [TaskItem]) -> [TaskItem] {
        values.filter { search.isEmpty || "\($0.title) \($0.notes) \($0.owner ?? "")".localizedCaseInsensitiveContains(search) }
            .sorted { ($0.dueAt ?? .distantFuture) == ($1.dueAt ?? .distantFuture) ? $0.createdAt > $1.createdAt : ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }
    private func filteredItems(_ store: TaskStore) -> [TaskItem] {
        let values: [TaskItem]
        switch section {
        case .completed: values = store.items.filter { $0.status == .completed }
        case .all: values = store.items.filter { statusFilter == "全部状态" || $0.status.label == statusFilter }
        default: values = todayItems(store)
        }
        return matching(values)
    }
}
