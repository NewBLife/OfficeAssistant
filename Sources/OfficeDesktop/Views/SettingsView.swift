import SwiftUI
import OfficeCore

@MainActor public struct SettingsView: View {
    @Bindable var model: OfficeAppModel
    @State private var draft = AppPreferences()
    @State private var message: String?
    @State private var failed = false
    public init(model: OfficeAppModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置").font(.largeTitle.bold()).padding(28)
            Form {
                Section("个人信息") {
                    TextField("你的姓名", text: $draft.displayName)
                    Text("新增任务时点击“我”，使用这里的姓名。未指定的负责人会保持为空。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("显示时区", selection: $draft.timeZoneID) {
                        ForEach(Array(Set([draft.timeZoneID, "Asia/Shanghai", "Asia/Tokyo", "Europe/London", "America/New_York", "UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("日常提醒") {
                    Toggle("每日待办汇总", isOn: $draft.dailySummaryEnabled)
                    if draft.dailySummaryEnabled {
                        HStack {
                            Text("汇总时间")
                            Spacer()
                            Picker("时", selection: $draft.summaryHour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.labelsHidden().frame(width: 75)
                            Text(":")
                            Picker("分", selection: $draft.summaryMinute) { ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.labelsHidden().frame(width: 75)
                        }
                        Text("按显示时区发送汇总通知，点击后查看今日待办与逾期事项。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label(notificationLabel, systemImage: model.notificationStatus == .authorized ? "bell" : "bell.slash")
                        Spacer()
                        Button(model.notificationStatus == .notDetermined ? "开启提醒" : "系统通知设置") {
                            if model.notificationStatus == .notDetermined { Task { await model.enableNotifications() } }
                            else { model.showNotificationSettings() }
                        }
                    }
                    Text("关机或系统关闭通知时无法即时提醒；重新打开后，逾期事项仍保留在列表中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("启动") {
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { enabled in Task { await model.setLoginEnabled(enabled) } }))
                    Text(model.loginMessage).font(.caption).foregroundStyle(.secondary)
                }
                Section("数据") {
                    Label("待办保存在这台 Mac", systemImage: "externaldrive")
                    Text("待办与提醒可离线使用。会议识别与翻译在 AI 服务页面单独配置。会议纪要与行动项提取将在后续阶段加入。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("办公助手 · 0.2.0").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error = model.preferences.errorMessage ?? model.errorMessage { Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 24) }
            HStack {
                if let message { Text(message).font(.callout).foregroundStyle(failed ? .red : .secondary) }
                Spacer()
                Button("保存设置") {
                    do { try model.preferences.save(draft); failed = false; message = "设置已保存" }
                    catch { failed = true; message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }.padding(24)
        }.onAppear { draft = model.preferences.value; model.readLoginStatus(); model.refresh() }
    }
    private var notificationLabel: String {
        switch model.notificationStatus { case .authorized: "系统通知已开启"; case .denied: "系统通知已关闭"; case .notDetermined: "尚未开启系统通知" }
    }
}
