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

/// Ends a recording when the meeting does: once another app that held the microphone during the recording releases
/// it, ask; unanswered, stop after `silenceLimit` of silence on both sources since then.
struct AutoStop {
    enum Decision: Equatable {
        case idle
        case ask
        case withdraw
        case stop
    }

    static let silenceLimit: TimeInterval = 120

    private var meetingSeen = false
    private var endedAt: Date?
    private var kept = false

    mutating func keepRecording() {
        kept = true
        endedAt = nil
    }

    mutating func update(enabled: Bool, othersUsingMic: Bool, paused: Bool, lastSound: Date, now: Date) -> Decision {
        if othersUsingMic { meetingSeen = true }
        if !enabled || kept || othersUsingMic {
            guard endedAt != nil else { return .idle }
            endedAt = nil
            return .withdraw
        }
        guard meetingSeen else { return .idle }
        guard let ended = endedAt else {
            endedAt = now
            return .ask
        }
        guard !paused, now.timeIntervalSince(max(lastSound, ended)) >= Self.silenceLimit else { return .idle }
        meetingSeen = false
        endedAt = nil
        return .stop
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
