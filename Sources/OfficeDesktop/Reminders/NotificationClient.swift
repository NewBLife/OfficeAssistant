import Foundation
import UserNotifications
import OfficeCore

public enum NotificationAuthorization: Equatable { case notDetermined, denied, authorized }
@MainActor public protocol NotificationClient {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func pendingIDs() async -> Set<String>
    func deliveredIDs() async -> Set<String>
    func remove(ids: [String])
    func add(_ request: ReminderRequest) async throws
}

@MainActor public final class SystemNotificationClient: NotificationClient {
    public let center: UNUserNotificationCenter
    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        let actions = [UNNotificationAction(identifier: "office.complete", title: "完成"),
                       UNNotificationAction(identifier: "office.snooze", title: "10 分钟后提醒")]
        center.setNotificationCategories([UNNotificationCategory(identifier: "office.task", actions: actions, intentIdentifiers: [])])
    }
    public func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }
    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    public func pendingIDs() async -> Set<String> { Set(await center.pendingNotificationRequests().map(\.identifier)) }
    public func deliveredIDs() async -> Set<String> { Set(await center.deliveredNotifications().map { $0.request.identifier }) }
    public func remove(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    public func add(_ request: ReminderRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title; content.body = request.body; content.sound = .default
        if let taskID = request.taskID {
            content.categoryIdentifier = "office.task"; content.userInfo = ["taskID": taskID.uuidString]
        }
        let trigger: UNNotificationTrigger
        switch request.trigger {
        case .once(let date):
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            components.timeZone = calendar.timeZone; components.calendar = calendar
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .daily(let hour, let minute, let timeZoneID):
            var components = DateComponents(); components.hour = hour; components.minute = minute
            components.timeZone = TimeZone(identifier: timeZoneID)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        }
        try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
    }
}
