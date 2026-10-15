import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let meetingCategory = "meeting-started"
    private static let recordAction = "record"
    private static let meetingIdentifier = "meeting-started"
    private static let meetingKey = "meeting"

    private let onRecord: @MainActor @Sendable () async -> Void
    private let onOpen: @MainActor @Sendable (URL) -> Void
    private let center = UNUserNotificationCenter.current()

    init(onRecord: @escaping @MainActor @Sendable () async -> Void, onOpen: @escaping @MainActor @Sendable (URL) -> Void) {
        self.onRecord = onRecord
        self.onOpen = onOpen
        super.init()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.meetingCategory, actions: [record],
                                                                 intentIdentifiers: [], options: [])])
    }

    func postMeetingStarted(appName: String?) {
        let content = content(title: "Meeting started \u{2014} record it?", body: MeetingApps.notificationBody(appName: appName))
        content.categoryIdentifier = Self.meetingCategory
        post(content, identifier: Self.meetingIdentifier)
    }

    func postProcessed(title: String, body: String, meeting: URL) {
        let content = content(title: title, body: body)
        content.userInfo = [Self.meetingKey: meeting.path]
        post(content, identifier: UUID().uuidString)
    }

    func withdrawMeetingStarted() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingIdentifier])
    }

    private func content(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }

    private func post(_ content: UNNotificationContent, identifier: String) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if let path = content.userInfo[Self.meetingKey] as? String {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                await onOpen(URL(fileURLWithPath: path))
            }
            return
        }
        guard content.categoryIdentifier == Self.meetingCategory,
              [Self.recordAction, UNNotificationDefaultActionIdentifier].contains(response.actionIdentifier) else { return }
        await onRecord()
    }
}
