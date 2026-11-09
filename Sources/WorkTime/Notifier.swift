import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let meetingCategory = "meeting-started"
    private static let recordAction = "record"
    private static let meetingIdentifier = "meeting-started"
    private static let endedCategory = "meeting-ended"
    private static let stopAction = "stop"
    private static let keepAction = "keep"
    private static let meetingKey = "meeting"

    private let onRecord: @MainActor @Sendable () async -> Void
    private let onOpen: @MainActor @Sendable (URL) -> Void
    private let onStop: @MainActor @Sendable () async -> Void
    private let onKeepRecording: @MainActor @Sendable () -> Void
    private let center = UNUserNotificationCenter.current()

    init(onRecord: @escaping @MainActor @Sendable () async -> Void, onOpen: @escaping @MainActor @Sendable (URL) -> Void,
         onStop: @escaping @MainActor @Sendable () async -> Void, onKeepRecording: @escaping @MainActor @Sendable () -> Void) {
        self.onRecord = onRecord
        self.onOpen = onOpen
        self.onStop = onStop
        self.onKeepRecording = onKeepRecording
        super.init()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [])
        let stop = UNNotificationAction(identifier: Self.stopAction, title: "Stop", options: [])
        let keep = UNNotificationAction(identifier: Self.keepAction, title: "Keep recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.meetingCategory, actions: [record], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.endedCategory, actions: [stop, keep], intentIdentifiers: [], options: []),
        ])
    }

    func postMeetingStarted(appName: String?) {
        let content = content(title: "Meeting started \u{2014} record it?", body: MeetingApps.notificationBody(appName: appName))
        content.categoryIdentifier = Self.meetingCategory
        post(content, identifier: Self.meetingIdentifier)
    }

    func postMeetingEnded() {
        let minutes = Int(AutoStop.silenceLimit / 60)
        let content = content(title: "Meeting ended \u{2014} stop recording?",
                              body: "The recording stops by itself after \(minutes) minutes of silence.")
        content.categoryIdentifier = Self.endedCategory
        post(content, identifier: Self.endedCategory)
    }

    func postProcessed(title: String, body: String, meeting: URL) {
        let content = content(title: title, body: body)
        content.userInfo = [Self.meetingKey: meeting.path]
        post(content, identifier: UUID().uuidString)
    }

    func withdrawMeetingStarted() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingIdentifier])
    }

    func withdrawMeetingEnded() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.endedCategory])
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
        let action = response.actionIdentifier
        if let path = content.userInfo[Self.meetingKey] as? String {
            if action == UNNotificationDefaultActionIdentifier { await onOpen(URL(fileURLWithPath: path)) }
            return
        }
        switch (content.categoryIdentifier, action) {
        case (Self.meetingCategory, Self.recordAction), (Self.meetingCategory, UNNotificationDefaultActionIdentifier):
            await onRecord()
        case (Self.endedCategory, Self.stopAction):
            await onStop()
        case (Self.endedCategory, Self.keepAction):
            await onKeepRecording()
        default:
            break
        }
    }
}
