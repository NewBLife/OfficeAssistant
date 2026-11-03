import AppKit
import UserNotifications
import OfficeDesktop

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var model: OfficeAppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Self.model?.start()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.model?.showWorkspace(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let meetings = Self.model?.meetings, meetings.isActive || meetings.meeting?.state == .paused else { return .terminateNow }
        Task { @MainActor in await meetings.interrupt(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { Self.model?.stop() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo["taskID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            Self.model?.handleNotification(action: action, taskID: id)
            if action == UNNotificationDefaultActionIdentifier {
                Self.model?.showWorkspace()
            }
            completionHandler()
        }
    }
}
