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

    /// Says Main handed a pull request's agent a prompt, so it is not missed while that agent works out of sight.
    static func postAgentMessage(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// An agent's notification, at once or with a calendar trigger at its time so it shows even while the app is busy or quit.
    static func postNotice(_ notice: AgentNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.source.title ?? ""
        content.body = notice.body ?? ""
        content.sound = .default
        content.userInfo = [NoticeLogic.userInfoKey: notice.id]
        if notice.urgency == .high { content.interruptionLevel = .timeSensitive }
        let trigger = notice.at.map {
            UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0),
                                          repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: NoticeLogic.identifier(notice.id), content: content, trigger: trigger))
    }

    /// A meeting brief shortly before the meeting; a click opens the brief in the notch bar.
    static func postBrief(title: String, body: String, key: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [MeetingBriefLogic.userInfoKey: key]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "brief:" + key, content: content, trigger: nil))
    }

    static func withdrawNotice(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [NoticeLogic.identifier(id)])
        center.removeDeliveredNotifications(withIdentifiers: [NoticeLogic.identifier(id)])
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
        if let id = content.userInfo[NoticeLogic.userInfoKey] as? String {
            if action == UNNotificationDefaultActionIdentifier { await NoticeCenter.shared.open(id) }
            return
        }
        if content.userInfo[MeetingBriefLogic.userInfoKey] != nil {
            if action == UNNotificationDefaultActionIdentifier { await MeetingBriefModel.shared.show() }
            return
        }
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
