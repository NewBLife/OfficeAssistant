import SwiftUI
import OfficeCore

private struct ActionPresentation: Identifiable {
    var id = UUID(); var mode: String; var candidate: ActionCandidate?
}
@MainActor struct MeetingActionsView: View {
    let meeting: MeetingSession; let coordinator: MinutesCoordinator; let tasks: TaskStore?; let links: MeetingTaskLinkService?
    let preferences: AppPreferences; let showCandidates: Bool
    let openTask: (TaskItem) -> Void; let openMeeting: (UUID, EvidenceReference?) -> Void
    var groups: GroupStore? = nil
    @State private var candidates: [ActionCandidate] = []; @State private var presentation: ActionPresentation?
    @State private var error: String?; @State private var selected: Set<UUID> = []; @State private var batchConfirm = false; @State private var unlink: UUID?
    private var related: [TaskItem] { (tasks?.items ?? []).filter { ($0.meetingLinks ?? []).contains { $0.meetingID == meeting.id } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showCandidates {
                HStack { Text("行动项候选").font(.headline); Spacer(); Button("批量确认加入") { batchConfirm = true }.disabled(selected.isEmpty || tasks?.isLoaded != true) }
                Text("请核对原文依据。未指定负责人或具体时刻可保留空白，不会自动设置到点提醒。").font(.caption).foregroundStyle(.secondary)
                if candidates.isEmpty { Text("暂无行动项候选").foregroundStyle(.secondary) }
                ForEach(candidates.filter { $0.reviewState != .ignored }) { candidate in candidateCard(candidate) }
                let ignored = candidates.filter { $0.reviewState == .ignored }
                if !ignored.isEmpty { DisclosureGroup("已忽略 \(ignored.count) 项") { ForEach(ignored) { item in HStack { Text(item.titleZH); Spacer(); Button("恢复审阅") { var value = item; value.reviewState = .proposed; perform { try coordinator.saveCandidate(value) } } } } } }
            } else {
                HStack {
                    Text("相关待办 · \(related.count)").font(.headline); Spacer()
                    Button("关联已有待办") { presentation = ActionPresentation(mode: "associate") }.disabled(tasks?.isLoaded != true)
                    Button("从会议新建待办") { presentation = ActionPresentation(mode: "new") }.disabled(tasks?.isLoaded != true)
                }
                if let tasks, tasks.isLoaded {
                    if related.isEmpty { ContentUnavailableView("尚未关联待办", systemImage: "checklist", description: Text("从纪要行动项确认加入，或在这里新建、关联已有待办。")) }
                    TaskListView(items: related, store: tasks, now: Date(), openMeeting: openMeeting, groups: groups, edit: openTask)
                    ForEach(related) { task in HStack { Text(task.title).font(.caption).foregroundStyle(.secondary); Spacer(); Button("解除会议关联") { unlink = task.id }.font(.caption) } }
                } else { Text("待办库暂时无法读取，关联操作已停用。").foregroundStyle(.orange) }
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onAppear(perform: load).onChange(of: coordinator.changeCount) { _, _ in load() }
            .sheet(item: $presentation) { item in
                if let tasks, let links {
                    if item.mode == "edit", let candidate = item.candidate {
                        CandidateEditor(candidate: candidate, groups: groups, defaultGroupID: (try? links.defaultGroupID(meetingID: meeting.id)) ?? meeting.groupID) { value, draft, duplicate, add, assignment in
                            try coordinator.saveCandidate(value)
                            if add { _ = try links.accept(value, editedTask: draft, allowDuplicate: duplicate, groupAssignment: assignment); coordinator.refresh() }
                        }
                    } else if item.mode == "associate" {
                        ExistingMeetingTaskPicker(tasks: tasks) { id in
                            if let candidate = item.candidate { _ = try links.associate(candidate: candidate, existingTaskID: id) }
                            else { try tasks.linkMeeting(taskID: id, link: TaskMeetingLink(meetingID: meeting.id, meetingTitleSnapshot: meeting.title)) }
                            coordinator.refresh()
                        }
                    } else if item.mode == "new" { TaskEditorView(item: newTask(), store: tasks, preferences: preferences, groups: groups) }
                }
            }
            .confirmationDialog("将所选行动项加入待办？负责人或时间留空时，不会补造信息或安排到点提醒。", isPresented: $batchConfirm) {
                Button("确认加入所选事项") { batchAdd() }; Button("取消", role: .cancel) {}
            }
            .confirmationDialog("解除会议关联？待办本身和完成状态会保留。", isPresented: Binding(get: { unlink != nil }, set: { if !$0 { unlink = nil } })) {
                Button("解除关联") { if let id = unlink { perform { try tasks?.unlinkMeeting(taskID: id, meetingID: meeting.id); coordinator.refresh() } }; unlink = nil }
                Button("取消", role: .cancel) { unlink = nil }
            }
    }
    @ViewBuilder private func candidateCard(_ item: ActionCandidate) -> some View {
        let task = tasks?.taskForCandidate(meetingID: meeting.id, candidateID: item.id)
        let added = task != nil || item.reviewState == .accepted
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if !added { Toggle("选择", isOn: Binding(get: { selected.contains(item.id) }, set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })).labelsHidden().disabled(item.clarifications.contains(.possibleDuplicate) || item.clarifications.contains(.commitment)) }
                Text(item.titleZH).font(.headline); Spacer()
                if let task { Text("已加入 · " + task.status.label).foregroundStyle(.green) }
                else if added { Text("已加入，任务已删除或不可用").foregroundStyle(.secondary) }
            }
            Text("负责人：\(item.owner ?? "未指定") · 时间：\(item.dueText ?? "未安排时间")").font(.caption).foregroundStyle(.secondary)
            if !item.clarifications.isEmpty && !added { Text(item.clarifications.map(\.label).joined(separator: " · ")).font(.caption).foregroundStyle(.orange) }
            ForEach(item.evidence) { ref in Button { openMeeting(meeting.id, ref) } label: { Text("\(ref.segmentID.source.label) \(Int(ref.sourceStartSeconds))秒：\(ref.quote)").font(.caption).multilineTextAlignment(.leading) }.buttonStyle(.link) }
            if !added {
                HStack {
                    Button("校对并加入待办") { presentation = ActionPresentation(mode: "edit", candidate: item) }.buttonStyle(.borderedProminent).disabled(tasks?.isLoaded != true)
                    Button("关联已有待办") { presentation = ActionPresentation(mode: "associate", candidate: item) }.disabled(tasks?.isLoaded != true)
                    Button("忽略") { var value = item; value.reviewState = .ignored; perform { try coordinator.saveCandidate(value) } }
                }
            }
        }.padding(15).background(.background, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
    private func newTask() -> TaskItem { var value = TaskItem(title: "", timeZoneID: preferences.timeZoneID); value.groupID = meeting.groupID; value.meetingLinks = [TaskMeetingLink(meetingID: meeting.id, meetingTitleSnapshot: meeting.title)]; return value }
    private func load() { do { candidates = try coordinator.candidates(meetingID: meeting.id); selected = selected.intersection(Set(candidates.filter { $0.reviewState == .proposed }.map(\.id))) } catch { self.error = "行动项读取失败，原记录已保留。" } }
    private func perform(_ operation: () throws -> Void) { do { try operation(); error = nil } catch { self.error = error.localizedDescription } }
    private func batchAdd() {
        guard let links else { return }
        for item in candidates where selected.contains(item.id) && item.reviewState == .proposed && !item.clarifications.contains(.possibleDuplicate) && !item.clarifications.contains(.commitment) {
            do { _ = try links.accept(item, editedTask: TaskItem(title: item.titleZH, owner: item.owner, dueAt: item.dueAt, dueText: item.dueText, timeZoneID: item.timeZoneID)) }
            catch { self.error = error.localizedDescription; break }
        }
        selected = []; coordinator.refresh()
    }
}

@MainActor private struct CandidateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: ActionCandidate; @State private var owner: String; @State private var hasDate: Bool; @State private var date: Date
    @State private var duplicate = false; @State private var commitment = false; @State private var error: String?
    let groups: GroupStore?
    @State private var groupID: UUID?
    let save: (ActionCandidate, TaskItem, Bool, Bool, GroupAssignment) throws -> Void
    init(candidate: ActionCandidate, groups: GroupStore?, defaultGroupID: UUID?, save: @escaping (ActionCandidate, TaskItem, Bool, Bool, GroupAssignment) throws -> Void) {
        self.groups = groups; _groupID = State(initialValue: defaultGroupID)
        _candidate = State(initialValue: candidate); _owner = State(initialValue: candidate.owner ?? ""); _hasDate = State(initialValue: candidate.dueAt != nil)
        _date = State(initialValue: candidate.dueAt ?? Date().addingTimeInterval(3600)); self.save = save
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("校对行动项").font(.title2.bold())
            Form {
                if let groups { GroupPicker(groups: groups, selection: $groupID) }
                TextField("待办标题", text: $candidate.titleZH)
                TextField("负责人（留空为未指定）", text: $owner)
                Text("原始时间：" + (candidate.dueText ?? "未指定"))
                Toggle("设置具体截止时间与提醒", isOn: $hasDate)
                if hasDate { DatePicker("截止时间", selection: $date).environment(\.timeZone, TimeZone(identifier: candidate.timeZoneID) ?? .current) }
                Text("时区：" + candidate.timeZoneID).font(.caption).foregroundStyle(.secondary)
                ForEach(candidate.evidence) { ref in Text("依据：" + ref.quote).font(.callout).textSelection(.enabled) }
                if candidate.clarifications.contains(.possibleDuplicate) { Toggle("已核对，这是一项独立事项", isOn: $duplicate) }
                if candidate.clarifications.contains(.crossChunkReview) { Text("本会议分段生成，请先查看全场转写，核对后续是否取消或变更了此事项。").foregroundStyle(.orange) }
                if candidate.clarifications.contains(.commitment) { Toggle("已核对，确认需要创建待办", isOn: $commitment) }
                Text("负责人、时间可留空。加入后成为独立待办，不随纪要重新生成而改写。").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }; Button("只保存校对") { commit(add: false) }; Spacer()
                Button("确认加入待办") { commit(add: true) }.buttonStyle(.borderedProminent).disabled(candidate.titleZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (candidate.clarifications.contains(.possibleDuplicate) && !duplicate) || (candidate.clarifications.contains(.commitment) && !commitment))
            }
        }.padding(24).frame(width: 590, height: 620)
    }
    private func commit(add: Bool) {
        candidate.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : owner.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.dueAt = hasDate ? date : nil
        if candidate.owner != nil { candidate.clarifications.removeAll { $0 == .owner } }
        if hasDate { candidate.clarifications.removeAll { $0 == .deadline || $0 == .meetingDate } }
        if commitment { candidate.clarifications.removeAll { $0 == .commitment || $0 == .crossChunkReview } }
        let draft = TaskItem(title: candidate.titleZH, owner: candidate.owner, dueAt: candidate.dueAt, dueText: candidate.dueText, timeZoneID: candidate.timeZoneID)
        do { try save(candidate, draft, duplicate, add, groups?.isLoaded == true ? .explicit(groupID) : .inherit); dismiss() } catch { self.error = error.localizedDescription }
    }
}
@MainActor private struct ExistingMeetingTaskPicker: View {
    @Environment(\.dismiss) private var dismiss
    let tasks: TaskStore; let select: (UUID) throws -> Void
    @State private var search = ""; @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("关联已有待办").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
            TextField("搜索标题", text: $search).textFieldStyle(.roundedBorder)
            List(tasks.items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { task in
                Button { do { try select(task.id); dismiss() } catch { self.error = error.localizedDescription } } label: {
                    HStack { VStack(alignment: .leading) { Text(task.title); Text(task.status.label).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("关联") }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.borderless)
            }
            if let error { Text(error).foregroundStyle(.orange) }
        }.padding(24).frame(width: 530, height: 500)
    }
}
