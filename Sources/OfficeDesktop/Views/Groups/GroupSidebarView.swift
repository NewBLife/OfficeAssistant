import SwiftUI
import OfficeCore

private struct GroupEditRequest: Identifiable {
    let id = UUID(); var editingID: UUID?; var parentID: UUID?
}
@MainActor struct GroupSidebarView: View {
    let groups: GroupStore
    @Binding var selection: GroupScope
    let active: Bool
    let activate: () -> Void
    @State private var editing: GroupEditRequest?
    @State private var deleting: OfficeCore.WorkGroup?
    @State private var error: String?
    var body: some View {
        Section("分组") {
            if !groups.isLoaded {
                Label("分组暂时不可用", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("重试读取分组") { do { try groups.reload() } catch { self.error = groups.errorMessage } }
            } else {
                row("全部内容", scope: .all, icon: "square.grid.2x2")
                row("未分组", scope: .ungrouped, icon: "tray")
                ForEach(GroupRules.ordered(groups.groups).filter { $0.parentID == nil }) { group in
                    DisclosureGroup {
                        ForEach(GroupRules.ordered(groups.groups).filter { $0.parentID == group.id }) { child in
                            row(child.name, scope: .group(child.id), icon: "folder")
                                .contextMenu { groupMenu(child) }
                        }
                    } label: {
                        row(group.name, scope: .group(group.id), icon: "folder")
                            .contextMenu { groupMenu(group) }
                    }
                }
                if groups.groups.isEmpty { Text("按客户或项目新建分组").font(.caption).foregroundStyle(.secondary) }
                Button { editing = GroupEditRequest() } label: { Label("新建分组", systemImage: "folder.badge.plus") }
            }
        }
        .sheet(item: $editing) { request in GroupEditorView(groups: groups, editingID: request.editingID, parentID: request.parentID) }
        .confirmationDialog("删除分组“\(deleting?.name ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除分组", role: .destructive) {
                if let deleting { do { try groups.delete(id: deleting.id) } catch { self.error = error.localizedDescription } }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            let count = groups.groups.filter { $0.parentID == deleting?.id }.count
            Text(count > 0 ? "同时移除 \(count) 个子分组。会议、纪要和待办全部保留，并归入“未分组”。" : "会议、纪要和待办全部保留，并归入“未分组”。")
        }
        .alert("分组操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        .onChange(of: groups.groups) { _, values in
            if case let .group(id) = selection, !values.contains(where: { $0.id == id }) { selection = .ungrouped }
        }
    }
    private func row(_ title: String, scope: GroupScope, icon: String) -> some View {
        Button { selection = scope; activate() } label: {
            Label(LocalizedStringKey(title), systemImage: icon).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4).padding(.horizontal, 3)
                .background(active && selection == scope ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func groupMenu(_ group: OfficeCore.WorkGroup) -> some View {
        if group.parentID == nil { Button("新建子分组") { editing = GroupEditRequest(parentID: group.id) } }
        Button("重命名或移动") { editing = GroupEditRequest(editingID: group.id) }
        Button("删除分组", role: .destructive) { deleting = group }
    }
}
