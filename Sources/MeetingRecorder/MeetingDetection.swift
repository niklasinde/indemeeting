import Foundation

struct MeetingDetector {
    enum Decision: Equatable {
        case idle
        case wait(TimeInterval)
        case notify
    }

    static let threshold: TimeInterval = 3

    private var busySince: Date?
    private var handled = false

    mutating func update(micBusy: Bool, recording: Bool, now: Date) -> Decision {
        guard micBusy else {
            busySince = nil
            handled = false
            return .idle
        }
        let since = busySince ?? now
        busySince = since
        if recording { handled = true }
        if handled { return .idle }
        let remaining = Self.threshold - now.timeIntervalSince(since)
        if remaining > 0 { return .wait(remaining) }
        handled = true
        return .notify
    }
}

enum MeetingApps {
    static let dedicated: [(id: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("notion.id", "Notion"),
    ]
    static let browsers: [(id: String, name: String)] = [
        ("com.google.Chrome", "Google Chrome"),
        ("com.apple.Safari", "Safari"),
        ("company.thebrowser.Browser", "Arc"),
    ]

    static func name(frontmost: String?, running: [String]) -> String? {
        if let app = (dedicated + browsers).first(where: { $0.id == frontmost }) { return app.name }
        return dedicated.first { running.contains($0.id) }?.name
    }

    static func notificationBody(appName: String?) -> String {
        appName.map { "\($0) \u{00B7} microphone in use" } ?? "Microphone in use"
    }
}
