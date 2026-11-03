import AppKit
import SwiftUI
import OfficeCore
import OfficeDesktop

@main @MainActor struct OfficeAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: OfficeAppModel

    init() {
        let model = OfficeAppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }
    var body: some Scene {
        Window("办公助手", id: "workspace") { WorkspaceView(model: model).tint(.blue) }
            .defaultSize(width: 1040, height: 760)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("新增待办") { model.showWorkspace(newTask: true) }.keyboardShortcut("n", modifiers: .command)
                }
            }
        Settings { SettingsView(model: model).frame(width: 620, height: 720) }
        MenuBarExtra {
            OfficeMenu(model: model)
        } label: { Image(systemName: model.meetings?.isActive == true ? "record.circle.fill" : "checklist") }
    }
}

@MainActor private struct OfficeMenu: View {
    let model: OfficeAppModel
    var body: some View {
        Text("今日待办 · \(model.todayCount)")
        if let meetings = model.meetings, meetings.isActive {
            Text("正在记录会议")
            Button("停止会议记录") { Task { await meetings.stop() } }
        }
        Divider()
        Button("打开待办") {
            model.showWorkspace()
        }
        Button("新增待办") {
            model.showWorkspace(newTask: true)
        }
        Divider()
        Button("退出办公助手") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }
}
