import SwiftUI
import OfficeCore

@MainActor struct GroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let groups: GroupStore
    let editingID: UUID?
    @State private var name: String
    @State private var parentID: UUID?
    @State private var error: String?
    init(groups: GroupStore, editingID: UUID? = nil, parentID: UUID? = nil) {
        self.groups = groups; self.editingID = editingID
        let existing = groups.groups.first { $0.id == editingID }
        _name = State(initialValue: existing?.name ?? "")
        _parentID = State(initialValue: existing?.parentID ?? parentID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editingID == nil ? "新建分组" : "编辑分组").font(.title2.bold())
            TextField("分组名称", text: $name).textFieldStyle(.roundedBorder)
            Picker("上级分组", selection: $parentID) {
                Text("无（一级分组）").tag(Optional<UUID>.none)
                ForEach(groups.groups.filter { $0.parentID == nil && $0.id != editingID }) { group in Text(group.name).tag(Optional(group.id)) }
            }.disabled(editingID.map { id in groups.groups.contains { $0.parentID == id } } ?? false)
            Text("最多两层。已有子分组的一级分组，需要先移出子分组才能调整上级。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    do {
                        if let editingID { try groups.update(id: editingID, name: name, parentID: parentID) }
                        else { try groups.create(name: name, parentID: parentID) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!groups.isLoaded || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 410)
    }
}
