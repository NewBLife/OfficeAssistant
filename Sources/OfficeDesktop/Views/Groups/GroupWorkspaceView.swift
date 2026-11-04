import SwiftUI
import OfficeCore

@MainActor struct GroupWorkspaceView: View {
    @Bindable var model: OfficeAppModel
    let scope: GroupScope
    let openTask: (TaskItem) -> Void
    let openMeeting: (UUID, EvidenceReference?) -> Void
    @State private var tab = "待办"
    @State private var search = ""
    @State private var status: TaskStatus?
    private var title: String {
        switch scope {
        case .all: "全部内容"
        case .ungrouped: "未分组"
        case .group(let id): GroupRules.path(id, groups: model.groups.groups)
        }
    }
    var body: some View {
        if !model.groups.isLoaded {
            ContentUnavailableView("分组暂时不可用", systemImage: "folder.badge.questionmark", description: Text(model.groups.errorMessage ?? "请在侧栏重试读取；原有会议和待办仍可从原入口查看。"))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Label(title, systemImage: "folder").font(.title2.bold()).lineLimit(2)
                    Spacer()
                    Picker("分组内容", selection: $tab) { Text("待办").tag("待办"); Text("会议与纪要").tag("会议与纪要") }.pickerStyle(.segmented).frame(width: 240)
                }.padding(24)
                Divider()
                if tab == "待办" { taskContent }
                else if let controller = model.meetings {
                    MeetingWorkspaceView(controller: controller, settings: model.aiSettings, minutes: model.minutes, tasks: model.store, links: model.meetingLinks, preferences: model.preferences.value, openTask: openTask, openMeeting: openMeeting, groups: model.groups, scope: scope, defaultGroupID: scope.defaultGroupID)
                } else { ContentUnavailableView("会议库暂时不可用", systemImage: "externaldrive.badge.exclamationmark") }
            }
            .onChange(of: scope) { _, _ in search = ""; status = nil; tab = "待办" }
        }
    }
    @ViewBuilder private var taskContent: some View {
        if let store = model.store, store.isLoaded {
            let listed = GroupContentFilter.tasks(store.items, scope: scope, groups: model.groups.groups, search: search, status: status)
            VStack(spacing: 16) {
                HStack {
                    TextField("搜索标题、备注或负责人", text: $search).textFieldStyle(.roundedBorder)
                    Picker("状态", selection: $status) {
                        Text("全部状态").tag(Optional<TaskStatus>.none)
                        ForEach(TaskStatus.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }.frame(width: 140)
                    Button {
                        var item = TaskItem(title: "", timeZoneID: model.preferences.value.timeZoneID)
                        item.groupID = scope.defaultGroupID; openTask(item)
                    } label: { Label("新增待办", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }
                HStack { Text("\(listed.count) 项待办"); Spacer(); Text("一级分组包含子分组内容") }.font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    if listed.isEmpty {
                        ContentUnavailableView("暂无匹配的待办", systemImage: "checklist", description: Text("可以新增待办，或切换“会议与纪要”新建会议、导入音频。"))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else { TaskListView(items: listed, store: store, now: model.now, openMeeting: openMeeting, groups: model.groups, edit: openTask) }
                }
            }.padding(24).background(Color(nsColor: .windowBackgroundColor))
        } else { ContentUnavailableView("待办库暂时不可用", systemImage: "externaldrive.badge.exclamationmark") }
    }
}
