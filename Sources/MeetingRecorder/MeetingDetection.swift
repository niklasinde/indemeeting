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

/// Ends a recording when the meeting does: once the apps that held the microphone when the meeting started release
/// it, ask; unanswered, stop after `silenceLimit` of silence on both sources since then.
struct AutoStop {
    enum Decision: Equatable {
        case idle
        case ask
        case withdraw
        case stop
    }

    static let silenceLimit: TimeInterval = 120

    private(set) var meetingApps: Set<String> = []
    private var endedAt: Date?
    private var kept = false

    mutating func keepRecording() {
        kept = true
        endedAt = nil
    }

    /// A cancelled stop: wait for the next time the meeting ends.
    mutating func waitForNextEnd() {
        meetingApps = []
        endedAt = nil
    }

    /// `micUsers`: the other apps taking audio input, as `MicUsers.others` lists them.
    mutating func update(enabled: Bool, micUsers: Set<String>, paused: Bool, lastSound: Date, now: Date) -> Decision {
        if meetingApps.isEmpty { meetingApps = MeetingApps.known(in: micUsers) ?? micUsers }
        let meetingOn = !meetingApps.isDisjoint(with: micUsers)
        if !enabled || kept || meetingOn {
            guard endedAt != nil else { return .idle }
            endedAt = nil
            return .withdraw
        }
        guard !meetingApps.isEmpty else { return .idle }
        guard let ended = endedAt else {
            endedAt = now
            return .ask
        }
        guard !paused, now.timeIntervalSince(max(lastSound, ended)) >= Self.silenceLimit else { return .idle }
        meetingApps = []
        endedAt = nil
        return .stop
    }
}

/// A process Core Audio reports as taking audio input.
struct MicUser: Equatable {
    let pid: Int32
    let parent: Int32
    let bundleID: String
}

enum MicUsers {
    /// System services that open the input whenever anything records, so they never mean a meeting is running.
    /// corespeechd does this for as long as WorkTime itself records.
    static let systemServices: Set<String> = [
        "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.accessibility.heard", "com.apple.universalaccessd",
        "com.apple.audiomxd", "com.apple.replayd", "com.apple.controlcenter", "com.apple.mediaremoted",
        "com.apple.PowerChime", "systemsoundserverd",
    ]

    /// The apps other than this one, its child processes and system services taking audio input.
    static func others(_ users: [MicUser], ownPID: Int32, ownBundleID: String?) -> Set<String> {
        Set(users.compactMap { user in
            guard user.pid != ownPID, user.parent != ownPID, user.bundleID != ownBundleID,
                  !systemServices.contains(user.bundleID) else { return nil }
            return user.bundleID.isEmpty ? "pid \(user.pid)" : user.bundleID
        })
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

    /// The users that belong to a known meeting app or browser, helpers included; nil when there are none.
    static func known(in users: Set<String>) -> Set<String>? {
        let ids = (dedicated + browsers).map(\.id)
        let known = users.filter { user in ids.contains { user == $0 || user.hasPrefix($0 + ".") } }
        return known.isEmpty ? nil : known
    }

    static func notificationBody(appName: String?) -> String {
        appName.map { "\($0) \u{00B7} microphone in use" } ?? "Microphone in use"
    }

    /// The known meeting apps to look at, most likely first: those taking microphone input (a helper process counts
    /// for its app), then the frontmost, then the other running ones.
    static func candidates(micOwners: [String], frontmost: String?, running: [String]) -> [String] {
        let known = (dedicated + browsers).map(\.id)
        func app(_ bundle: String) -> String? { known.first { bundle == $0 || bundle.hasPrefix($0 + ".") } }
        let ordered = micOwners.compactMap(app) + [frontmost].compactMap { $0.flatMap(app) } + known.filter(running.contains)
        return ordered.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func appName(_ bundle: String) -> String? { (dedicated + browsers).first { $0.id == bundle }?.name }

    static func isBrowser(_ bundle: String) -> Bool { browsers.contains { $0.id == bundle } }
}

/// Where a meeting was held: the app or web service, and the call's name when one could be read.
struct MeetingSource: Equatable {
    var app: String
    var title: String?
    var bundle: String?
}

struct BrowserTab: Equatable {
    var url: String?
    var title: String
}

enum MeetingSourceLogic {
    static let services = ["Google Meet", "Zoom", "Microsoft Teams", "Slack"]

    /// `Huddle with Andy · Slack`; the call name is left out when it is already the shown title.
    static func label(app: String?, title: String?, shownTitle: String? = nil) -> String? {
        guard let app else { return nil }
        return [title == shownTitle ? nil : title, app].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// The source of one candidate app. A trusted one (taking the microphone, or frontmost) always gives one; another
    /// only with signs of a call: a meeting tab, a huddle window or a meeting window.
    static func source(app: String, trusted: Bool, windowTitles: [String], tabs: [BrowserTab]) -> MeetingSource? {
        guard let name = MeetingApps.appName(app) else { return nil }
        if MeetingApps.isBrowser(app) {
            let pages = tabs.isEmpty ? windowTitles.map { BrowserTab(url: nil, title: $0) } : tabs
            let meetings = pages.compactMap { page in service(url: page.url, title: page.title).map { (page: page, service: $0) } }
            if let best = meetings.min(by: { services.firstIndex(of: $0.service)! < services.firstIndex(of: $1.service)! }) {
                return MeetingSource(app: best.service, title: cleanTitle(best.page.title, service: best.service), bundle: app)
            }
            return trusted ? MeetingSource(app: name, bundle: app) : nil
        }
        switch name {
        case "Slack":
            if let huddle = windowTitles.first(where: { $0.localizedCaseInsensitiveContains("huddle") }) {
                return MeetingSource(app: name, title: cleanTitle(huddle, service: name), bundle: app)
            }
            guard trusted else { return nil }
            return MeetingSource(app: name, title: windowTitles.lazy.compactMap { cleanTitle($0, service: name) }.first, bundle: app)
        case "Zoom", "Microsoft Teams":
            let title = windowTitles.lazy.compactMap { cleanTitle($0, service: name) }.first
            let inMeeting = title != nil || windowTitles.contains {
                $0.localizedCaseInsensitiveContains("meeting") || $0.localizedCaseInsensitiveContains("webinar")
            }
            return trusted || inMeeting ? MeetingSource(app: name, title: title, bundle: app) : nil
        default:
            return trusted ? MeetingSource(app: name, bundle: app) : nil
        }
    }

    /// The new source when it says more about the same call than the stored one: a name where there was none, a
    /// meeting service where there was only the browser, or a longer name that contains the old one.
    static func refined(_ stored: MeetingSource, with new: MeetingSource?) -> MeetingSource? {
        guard let new, new != stored, new.bundle == stored.bundle else { return nil }
        guard let old = stored.title else { return new.title != nil || new.app != stored.app ? new : nil }
        guard let title = new.title, new.app == stored.app else { return nil }
        return title.count > old.count && title.localizedCaseInsensitiveContains(old) ? new : nil
    }

    /// The meeting service a browser page belongs to, from its address, else from its title.
    static func service(url: String?, title: String) -> String? {
        if let url = url.flatMap(URL.init(string:)), let host = url.host?.lowercased() {
            let path = url.path.lowercased()
            if host == "meet.google.com", path.range(of: "^/(lookup/)?[a-z0-9-]{3,}", options: .regularExpression) != nil { return "Google Meet" }
            if host == "zoom.us" || host.hasSuffix(".zoom.us"), ["/wc/", "/j/", "/s/"].contains(where: path.hasPrefix) { return "Zoom" }
            if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) { return "Microsoft Teams" }
            if host == "app.slack.com", title.localizedCaseInsensitiveContains("huddle") { return "Slack" }
            return nil
        }
        let page = strip(title)
        if page.range(of: meetAffix, options: .regularExpression) != nil { return "Google Meet" }
        if page.hasSuffix("| Microsoft Teams") { return "Microsoft Teams" }
        if page.range(of: zoomSuffix, options: .regularExpression) != nil { return "Zoom" }
        return nil
    }

    private static let meetAffix = "^(Google )?Meet\\s[-\u{2013}:]\\s|\\s[-\u{2013}]\\sGoogle Meet$"
    private static let zoomSuffix = "\\s[-|]\\sZoom( Meeting)?$"

    /// The call's name in a window or tab title, without browser and app suffixes, unread counts and generic names.
    static func cleanTitle(_ raw: String, service: String) -> String? {
        let text = strip(raw)
        switch service {
        case "Google Meet":
            let name = text.replacingOccurrences(of: meetAffix, with: "", options: .regularExpression)
            guard name.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) == nil else { return nil }
            return nonGeneric(name, ["Meet", "Google Meet"])
        case "Microsoft Teams":
            let first = text.components(separatedBy: " | ").first { $0 != "Microsoft Teams" } ?? ""
            return nonGeneric(first, ["Chat", "Calendar", "Activity", "Teams", "Calls", "Files", "Home", "Search", "Meeting",
                                      "Meeting compact view"])
        case "Zoom":
            let name = text.replacingOccurrences(of: zoomSuffix, with: "", options: .regularExpression)
            return name.localizedCaseInsensitiveContains("zoom") ? nil : nonGeneric(name, ["Meeting", "Webinar"])
        case "Slack":
            return slackTitle(text)
        default:
            return nonGeneric(text, [service])
        }
    }

    /// A huddle window (`Huddle: general - Slack`, `Huddle with Andy`) as is, else the conversation of a Slack window
    /// (`Andy Smith (DM) - Quiddly - Slack`, `general (Channel) - Quiddly - Slack`, older `Slack | general | Quiddly`)
    /// as the huddle in it.
    private static func slackTitle(_ text: String) -> String? {
        let parts = text.hasPrefix("Slack | ") ? Array(text.components(separatedBy: " | ").dropFirst())
            : text.components(separatedBy: " - ").flatMap { $0.components(separatedBy: " \u{2013} ") }
        guard var name = parts.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        if name.lowercased().hasPrefix("huddle with ") { return name }
        name = name.replacingOccurrences(of: "^Huddle\\s*[:\u{2013}-]?\\s*|\\s+huddle$", with: "", options: [.regularExpression, .caseInsensitive])
        var direct: Bool?
        for (marker, isDirect) in [("(DM)", true), ("(Group DM)", true), ("(Channel)", false), ("(Private Channel)", false)]
        where name.hasSuffix(marker) {
            name = name.dropLast(marker.count).trimmingCharacters(in: .whitespaces)
            direct = isDirect
        }
        if name.hasPrefix("#") || (direct == nil && name == name.lowercased() && !name.contains(" ")) { direct = false }
        let generic = ["Slack", "huddle", "Huddles", "Activity", "Home", "DMs", "Threads", "Later", "Search", "Unreads", "Drafts & sent"]
        guard let name = nonGeneric(name, generic) else { return nil }
        if direct == false { return "Huddle in " + (name.hasPrefix("#") ? name : "#" + name) }
        return "Huddle with \(name)"
    }

    /// Without the browser's suffix, Chrome's recording notes, unread counts and leading emoji.
    private static func strip(_ raw: String) -> String {
        var text = ActivityLogic.pageTitle(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while true {
            let next = text
                .replacingOccurrences(of: "\\s[-\u{2013}]\\s(Audio playing|Audio muted|Camera recording|Microphone recording|"
                                          + "Camera and microphone recording|Sharing (this tab|your screen|a window)|Network error)$",
                                      with: "", options: .regularExpression)
                .replacingOccurrences(of: "^(\\(\\d+\\+?\\)|\\[\\d+\\]|\\*|\u{2022}|\u{25CF})\\s*", with: "", options: .regularExpression)
            let trimmed = String(next.drop { $0.isWhitespace || $0.unicodeScalars.first?.properties.isEmojiPresentation == true })
            if trimmed == text { return text }
            text = ActivityLogic.pageTitle(trimmed)
        }
    }

    private static func nonGeneric(_ text: String, _ generic: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || generic.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ? nil : trimmed
    }
}
