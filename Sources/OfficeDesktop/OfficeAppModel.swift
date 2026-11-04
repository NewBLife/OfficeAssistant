import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications
import OfficeCore

public extension Notification.Name {
    static let officeNewTask = Notification.Name("office.newTask")
    static let officeShowToday = Notification.Name("office.showToday")
}

@MainActor @Observable public final class OfficeAppModel {
    public private(set) var store: TaskStore?
    public let groups: GroupStore
    public let preferences: PreferencesStore
    public let aiSettings: AISettingsStore
    public let credentials = KeychainCredentialStore()
    public private(set) var meetings: MeetingSessionController?
    public private(set) var minutes: MinutesCoordinator?
    public var wantsMeetingID: UUID?
    public var requestedEvidence: EvidenceReference?
    public var meetingSourceRequestID = UUID()
    @ObservationIgnored private let dataDirectory: URL?
    @ObservationIgnored private var meetingRepository: CoreDataMeetingRepository?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    public let notifications = SystemNotificationClient()
    public private(set) var notificationStatus: NotificationAuthorization = .notDetermined
    public var errorMessage: String?
    public var now = Date()
    public var wantsNewTask = false
    public var wantsToday = false
    @ObservationIgnored public var openWorkspace: (() -> Void)?
    public private(set) var loginEnabled = false
    public private(set) var loginMessage = ""
    @ObservationIgnored private var coordinator: ReminderCoordinator?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(dataDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.dataDirectory = dataDirectory
        if let dataDirectory { try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true) }
        groups = GroupStore(url: dataDirectory?.appendingPathComponent("groups.json"))
        preferences = PreferencesStore(defaults: defaults); aiSettings = AISettingsStore(defaults: defaults)
        coordinator = ReminderCoordinator(client: notifications)
        openStore()
        do {
            let repo = try CoreDataMeetingRepository(url: dataDirectory?.appendingPathComponent("meetings.store")); meetingRepository = repo
            meetings = MeetingSessionController(repository: repo, credentials: credentials, groups: groups)
            minutes = MinutesCoordinator(meetings: repo, notes: repo, generator: MinutesGenerator(credentials: credentials), linkedTasks: { [weak self] in self?.store?.items ?? [] }, isRecording: { [weak self] id in self?.meetings?.isActive == true && self?.meetings?.meeting?.id == id })
            meetings?.onFinalSegmentSaved = { [weak self] id in self?.minutes?.noticeFinal(meetingID: id) }
            meetings?.onRecordingStopped = { [weak self] id in self?.minutes?.recordingStopped(meetingID: id) }
        }
        catch { errorMessage = "会议数据库无法打开，原数据已保留。" }
        preferences.onChange = { [weak self] in if self?.dataDirectory == nil { self?.refresh() } }
        readLoginStatus()
    }
    public var todayCount: Int {
        store?.items.filter { $0.dueAt == nil ? $0.status != .completed : TaskRules.isTodayOrOverdue($0, now: now, displayTimeZoneID: preferences.value.timeZoneID) }.count ?? 0
    }
    public var meetingLinks: MeetingTaskLinkService? {
        guard let store, let repo = meetingRepository else { return nil }
        return MeetingTaskLinkService(tasks: store, notes: repo, meetings: repo, groups: groups)
    }
    public func openMeeting(id: UUID, evidence: EvidenceReference?) throws {
        guard let meetings, let repo = meetingRepository else { throw OfficeError.invalid("会议库暂时不可用。") }
        let records = try repo.list()
        try MeetingNavigationPolicy.validate(target: id, available: records.map(\.id), activeMeetingID: meetings.isActive ? meetings.meeting?.id : nil)
        if !meetings.isActive, let item = records.first(where: { $0.id == id }) { try meetings.open(item) }
        requestedEvidence = evidence; meetingSourceRequestID = UUID(); wantsMeetingID = id; wantsToday = false
        openWorkspace?(); NSApp.activate(ignoringOtherApps: true)
    }
    public func openStore() {
        do {
            let newStore = TaskStore(repository: try CoreDataTaskRepository(url: dataDirectory?.appendingPathComponent("tasks.store")), groups: groups)
            store = newStore
            newStore.onChange = { [weak self] in self?.refresh() }
            errorMessage = newStore.errorMessage
        } catch { errorMessage = "本地数据无法打开，原有文件已保留：\(error.localizedDescription)" }
    }
    public func start() {
        guard dataDirectory == nil, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let meetings = self?.meetings, meetings.isActive { await meetings.interrupt() } }
        }
        refresh()
    }
    public func stop() {
        timer?.invalidate(); timer = nil; refreshTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }; sleepObserver = nil
    }
    public func showWorkspace(newTask: Bool = false) {
        if newTask { wantsNewTask = true } else { wantsToday = true }
        openWorkspace?()
        NSApp.activate(ignoringOtherApps: true)
    }
    public func refresh() {
        guard dataDirectory == nil else { return }
        now = Date()
        // Do not cancel an in-flight notification add: the coordinator reconciles generations.
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.notificationStatus = await self.notifications.authorization()
            guard let store = self.store, store.isLoaded else { return }
            do { try await self.coordinator?.reconcile(tasks: store.items, preferences: self.preferences.value, now: self.now) }
            catch { self.errorMessage = "提醒暂时未能更新：\(error.localizedDescription)" }
        }
    }
    public func enableNotifications() async {
        do { _ = try await notifications.requestAuthorization(); refresh() }
        catch { errorMessage = "无法开启提醒：\(error.localizedDescription)" }
    }
    public func handleNotification(action: String, taskID: UUID?) {
        guard let store else { return }
        do {
            if let taskID, action == "office.complete" { try store.complete(id: taskID, at: Date()) }
            else if let taskID, action == "office.snooze" { try store.snooze(id: taskID, until: Date().addingTimeInterval(600)) }
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    public func readLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginEnabled = true; loginMessage = "登录后自动启动"
        case .requiresApproval: loginEnabled = false; loginMessage = "请在系统设置的登录项中允许"
        case .notFound: loginEnabled = false; loginMessage = "当前应用无法注册登录启动"
        default: loginEnabled = false; loginMessage = "已关闭"
        }
    }
    public func setLoginEnabled(_ enabled: Bool) async {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch { errorMessage = "登录启动设置失败：\(error.localizedDescription)" }
        readLoginStatus()
    }
    public func showNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
