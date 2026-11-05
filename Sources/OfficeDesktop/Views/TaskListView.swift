import SwiftUI
import OfficeCore

@MainActor struct TaskListView: View {
    @Environment(\.locale) private var locale
    let items: [TaskItem]
    let store: TaskStore
    let now: Date
    var openMeeting: ((UUID, EvidenceReference?) -> Void)? = nil
    var groups: GroupStore? = nil
    let edit: (TaskItem) -> Void
    @State private var deleting: TaskItem?
    @State private var error: String?

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Button {
                        perform { if item.status == .completed { try store.reopen(id: item.id) }
                                  else { try store.complete(id: item.id, at: Date()) } }
                    } label: {
                        Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 23, weight: .light))
                            .foregroundStyle(item.status == .completed ? .green : .secondary)
                    }.buttonStyle(.plain).accessibilityLabel(item.status == .completed ? "撤销完成：\(item.title)" : "完成：\(item.title)")
                    VStack(alignment: .leading, spacing: 7) {
                        Button { edit(item) } label: {
                            Text(item.title).font(.system(size: 15, weight: .medium))
                                .strikethrough(item.status == .completed).foregroundStyle(item.status == .completed ? .secondary : .primary)
                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(item.status == .completed)
                        if let groups {
                            Text(groups.isLoaded ? GroupRules.path(item.groupID, groups: groups.groups) : "分组暂时不可用").font(.caption).foregroundStyle(.secondary)
                        }
                        if !item.notes.isEmpty { Text(item.notes).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                        ForEach((item.meetingLinks ?? []).reduce(into: [TaskMeetingLink]()) { values, link in if !values.contains(where: { $0.meetingID == link.meetingID }) { values.append(link) } }) { link in
                            Button { openMeeting?(link.meetingID, link.evidence.first) } label: { Label { Text("来源会议：\(link.meetingTitleSnapshot)") } icon: { Image(systemName: "waveform") } }
                                .buttonStyle(.link).font(.caption).disabled(openMeeting == nil)
                        }
                        HStack(spacing: 12) {
                            Label(LocalizedStringKey(item.owner ?? "未指定"), systemImage: "person")
                            if let due = item.dueAt {
                                Label(format(due, zone: item.timeZoneID), systemImage: "calendar")
                                    .foregroundStyle(due < now && item.status != .completed ? Color.orange : Color.secondary)
                            } else { Label(item.dueText == nil ? "未安排时间" : "时间待补充", systemImage: "clock") }
                            if item.repeatRule != .none { Label(LocalizedStringKey(item.repeatRule.label), systemImage: "repeat") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let snooze = item.snoozedUntil, item.status != .completed {
                            Text("稍后提醒：\(format(snooze, zone: item.timeZoneID))").font(.caption).foregroundStyle(.blue)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 10) {
                        Text(LocalizedStringKey(item.status.label)).font(.caption).foregroundStyle(item.status == .inProgress ? .blue : .secondary)
                        Menu {
                            if item.status != .completed {
                                Button("编辑") { edit(item) }
                                Button(item.status == .inProgress ? "改为待处理" : "开始处理") {
                                    perform { var updated = item; updated.status = item.status == .inProgress ? .pending : .inProgress; try store.upsert(updated) }
                                }
                                Button("10 分钟后提醒") { perform { try store.snooze(id: item.id, until: Date().addingTimeInterval(600)) } }
                            }
                            Button(item.status == .completed ? "撤销完成" : "标记完成") {
                                perform { if item.status == .completed { try store.reopen(id: item.id) }
                                          else { try store.complete(id: item.id, at: Date()) } }
                            }
                            if let groups { GroupMoveMenu(groups: groups, currentID: item.groupID) { try store.moveToGroup(id: item.id, groupID: $0) } }
                            Divider()
                            Button("删除", role: .destructive) { deleting = item }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26)
                    }
                }.padding(18)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
                    .contextMenu {
                        if item.status != .completed { Button("编辑") { edit(item) } }
                        if let groups { GroupMoveMenu(groups: groups, currentID: item.groupID) { try store.moveToGroup(id: item.id, groupID: $0) } }
                        Button("删除", role: .destructive) { deleting = item }
                    }
            }
        }
        .alert("删除这条待办？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let item = deleting { perform { try store.delete(id: item.id) } }; deleting = nil }
        } message: { Text(deleting?.title ?? "") }
        .alert("未能完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    private func format(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter(); formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "MdHm", options: 0, locale: locale)
        return formatter.string(from: date) + (zone == "Asia/Shanghai" ? "" : " · " + zone)
    }
}
