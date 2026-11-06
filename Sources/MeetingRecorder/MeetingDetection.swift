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

    /// A cancelled stop: wait for the next time the meeting ends.
    mutating func waitForNextEnd() {
        meetingSeen = false
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

/// The "Recording starts in 5 · Cancel" banner: idle → counting → fired or cancelled. A cancelled start stays
/// declined until the microphone has been free for `sessionGap`, so the same meeting is not offered twice.
struct RecordingCountdown {
    enum Kind: Equatable {
        case start
        case stop
    }

    enum State: Equatable {
        case idle
        case counting(Kind, until: Date)
        case fired(Kind)
        case cancelled(Kind)
    }

    static let lengths = [3, 5, 10]
    static let defaultLength = 5
    static let sessionGap: TimeInterval = 60

    private(set) var state = State.idle
    private var startDeclined = false
    private var micFreeSince: Date?

    var counting: Kind? {
        guard case .counting(let kind, _) = state else { return nil }
        return kind
    }

    static func length(_ stored: Int) -> Int { lengths.contains(stored) ? stored : defaultLength }

    static func text(_ kind: Kind, remaining: Int) -> String {
        "Recording \(kind == .start ? "starts" : "stops") in \(remaining)"
    }

    mutating func begin(_ kind: Kind, seconds: Int, now: Date) -> Bool {
        guard counting == nil, !(kind == .start && startDeclined) else { return false }
        state = .counting(kind, until: now.addingTimeInterval(TimeInterval(seconds)))
        return true
    }

    func remaining(now: Date) -> Int? {
        guard case .counting(_, let until) = state else { return nil }
        return max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    mutating func tick(now: Date) -> Kind? {
        guard case .counting(let kind, let until) = state, now >= until else { return nil }
        state = .fired(kind)
        return kind
    }

    mutating func cancel() {
        guard let kind = counting else { return }
        state = .cancelled(kind)
        if kind == .start { startDeclined = true }
    }

    /// Drops a countdown the user did not cancel, e.g. when the meeting comes back before a stop.
    @discardableResult
    mutating func drop(_ kind: Kind) -> Bool {
        guard counting == kind else { return false }
        state = .idle
        return true
    }

    /// The meeting ending during a start countdown cancels it quietly.
    @discardableResult
    mutating func micChanged(busy: Bool, now: Date) -> Bool {
        if busy {
            if let free = micFreeSince, now.timeIntervalSince(free) >= Self.sessionGap { startDeclined = false }
            micFreeSince = nil
            return false
        }
        if micFreeSince == nil { micFreeSince = now }
        return drop(.start)
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
