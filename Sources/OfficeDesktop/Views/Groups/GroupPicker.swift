import SwiftUI
import OfficeCore

@MainActor struct GroupPicker: View {
    let groups: GroupStore
    @Binding var selection: UUID?
    var body: some View {
        Picker("分组", selection: $selection) {
            Text("未分组").tag(Optional<UUID>.none)
            ForEach(GroupRules.ordered(groups.groups)) { group in
                Text(GroupRules.path(group.id, groups: groups.groups)).tag(Optional(group.id))
            }
        }.disabled(!groups.isLoaded)
        .onAppear { normalize() }
        .onChange(of: groups.groups) { _, _ in normalize() }
    }
    private func normalize() {
        if groups.isLoaded { selection = GroupRules.effectiveGroupID(selection, groups: groups.groups) }
    }
}

@MainActor struct GroupMoveMenu: View {
    let groups: GroupStore
    let currentID: UUID?
    let move: (UUID?) throws -> Void
    @State private var error: String?
    var body: some View {
        Menu("移动到分组") {
            Button("未分组") { perform(nil) }
            ForEach(GroupRules.ordered(groups.groups)) { group in
                Button {
                    perform(group.id)
                } label: {
                    if group.id == currentID { Label(GroupRules.path(group.id, groups: groups.groups), systemImage: "checkmark") }
                    else { Text(GroupRules.path(group.id, groups: groups.groups)) }
                }
            }
        }.disabled(!groups.isLoaded)
        .alert("未能移动分组", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func perform(_ id: UUID?) { do { try move(id) } catch { self.error = error.localizedDescription } }
}
