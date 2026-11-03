import SwiftUI
import OfficeCore

@MainActor struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TaskStore
    let preferences: AppPreferences
    let isNew: Bool
    @State private var draft: TaskItem
    @State private var quickText = ""
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var message: String?

    init(item: TaskItem, store: TaskStore, preferences: AppPreferences) {
        self.store = store; self.preferences = preferences
        isNew = !store.items.contains { $0.id == item.id }
        _draft = State(initialValue: item)
        _hasDeadline = State(initialValue: item.dueAt != nil)
        _deadline = State(initialValue: item.dueAt ?? Date().addingTimeInterval(3600))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新增待办" : "编辑待办").font(.title2.bold())
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            Form {
                if isNew {
                    Section("快捷记录") {
                        TextField("例如：明天下午三点交周报", text: $quickText)
                            .accessibilityIdentifier("quickEntry")
                        Button("识别时间并填写") { applyQuickEntry() }.disabled(quickText.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text("识别结果会填入下方表单，确认后保存。复杂任务提取将在会议功能中加入。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("事项") {
                    TextField("标题", text: $draft.title).accessibilityIdentifier("taskTitle")
                    TextField("备注", text: $draft.notes, axis: .vertical).lineLimit(2...4)
                    HStack {
                        TextField("负责人（可留空）", text: Binding(get: { draft.owner ?? "" }, set: { draft.owner = $0 }))
                        Button("我") {
                            if preferences.displayName.isEmpty { message = "请先在设置中填写你的姓名。" }
                            else { draft.owner = preferences.displayName }
                        }
                    }
                    Picker("状态", selection: $draft.status) {
                        Text("待处理").tag(TaskStatus.pending)
                        Text("进行中").tag(TaskStatus.inProgress)
                    }
                }
                Section("时间与提醒") {
                    Toggle("设置截止时间", isOn: $hasDeadline)
                        .onChange(of: hasDeadline) { _, enabled in if !enabled { draft.repeatRule = .none } }
                    if hasDeadline {
                        DatePicker("截止时间", selection: $deadline, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, TimeZone(identifier: draft.timeZoneID) ?? .current)
                        Picker("任务时区", selection: $draft.timeZoneID) {
                            ForEach(Array(Set([preferences.timeZoneID, draft.timeZoneID, "Asia/Shanghai", "Asia/Tokyo", "Europe/London", "America/New_York", "UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        Text("截止时间按上述时区显示；更换时区不会改变已选的绝对时刻。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let original = draft.dueText {
                        Text("时间待补充：\(original)").foregroundStyle(.orange)
                        Text("尚未安排到点提醒，可以先保存。需要提醒时，请开启截止时间并选择具体时刻。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("重复", selection: $draft.repeatRule) {
                        ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.disabled(!hasDeadline)
                    if hasDeadline && deadline <= Date() { Text("该时间已经过去，保存后会在今日待办中显示为逾期，不补发历史提醒。")
                        .font(.caption).foregroundStyle(.orange) }
                }
                if let links = draft.meetingLinks, !links.isEmpty {
                    Section("来源会议") {
                        ForEach(links) { link in
                            Text(link.meetingTitleSnapshot).font(.headline)
                            ForEach(link.evidence) { ref in Text("\(ref.segmentID.source.label)：\(ref.quote)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Text("来源关系独立保存；可在待办列表打开会议，在会议页解除关联。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            if let message { Text(message).font(.callout).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12) }
            Divider()
            HStack {
                Text(hasDeadline ? "保存后按截止时间提醒" : "未设置到点提醒").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存待办") {
                    draft.dueAt = hasDeadline ? deadline : nil
                    if !hasDeadline { draft.repeatRule = .none }
                    do { try store.upsert(draft); dismiss() } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(20)
        }.frame(width: 560, height: isNew ? 740 : 600)
    }
    private func applyQuickEntry() {
        let suggestion = QuickEntryParser.parse(quickText, reference: Date(), timeZoneID: draft.timeZoneID)
        draft.title = suggestion.title; draft.dueText = suggestion.dueText
        hasDeadline = suggestion.dueAt != nil
        if let date = suggestion.dueAt { deadline = date }
        message = suggestion.needsClarification ? "时间尚不明确，已保留原文。请确认具体截止时间。" : nil
    }
}
