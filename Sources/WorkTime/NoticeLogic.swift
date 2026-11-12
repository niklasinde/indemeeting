import Foundation

/// Who sent a notification: a WorkTime agent by its key, or a Claude Code session by its folder and session id.
struct NoticeSource: Codable, Equatable, Hashable, Sendable {
    static let agentEnvKey = "WORKTIME_AGENT"

    var agent: String?
    var workspace: String?
    var session: String?
    var cwd: String?
    /// What the app shows for it, filled in when the app takes the notification.
    var title: String?

    var identity: String { agent ?? session.map { "session:" + $0 } ?? cwd.map { "cwd:" + $0 } ?? "unknown" }

    var isMain: Bool { agent.map(Workspaces.isMainKey) ?? false }

    /// The source of the calling `--mcp` process: the agent key and workspace the sidecar passes, else the Claude Code session.
    static func current(environment: [String: String], cwd: String) -> NoticeSource {
        func value(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
        let agent = value(agentEnvKey)
        return NoticeSource(agent: agent, workspace: value(Workspaces.envKey), session: agent == nil ? value("CLAUDE_SESSION_ID") : nil,
                            cwd: agent == nil ? cwd : nil)
    }

    /// The name shown beside a notification: the agent's title when known, else what the key or folder says.
    func label(titles: [String: String]) -> String {
        if let agent {
            if let title = titles[agent] { return title }
            if let id = Workspaces.id(ofMainKey: agent) { return "Main \u{00B7} \(id)" }
            return GitHubLink.pullRequest(at: agent).map { "\($0.repo)#\($0.number)" } ?? agent
        }
        if let cwd { return "Claude Code \u{00B7} " + (cwd as NSString).lastPathComponent }
        return "Claude Code"
    }
}

enum NoticeUrgency: String, Codable, Sendable {
    case normal, high
}

/// A notification an agent asked for: shown at once or at `at`, and kept in the app's list until opened or dismissed.
struct AgentNotice: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case scheduled, shown, missed
    }

    var id: String
    var title: String
    var body: String?
    var link: String?
    var urgency = NoticeUrgency.normal
    var source: NoticeSource
    var created: Date
    var at: Date?
    var state = State.shown

    var date: Date { at ?? created }
}

/// Where a notification's link leads.
enum NoticeLink: Equatable {
    case pullRequest(GitHubLink.Target)
    case agent(String)
    case jira(String)
    case web(URL)
}

/// What the `--mcp` process hands the app through the agent inbox, and the app's answer.
struct NoticeRequest: Codable, Equatable {
    enum Action: String, Codable { case notify, cancel }

    var id: String
    var action: Action
    var notice: AgentNotice?
    var cancel: String?
    var source: NoticeSource
    var created: Date
}

struct NoticeReply: Codable, Equatable {
    var id: String
    var ok: Bool
    var notice: String?
    var message: String
}

struct NoticeError: Error, Equatable {
    let message: String

    init(_ message: String) { self.message = message }
}

enum NoticeLogic {
    static let titleLimit = 120
    static let bodyLimit = 1000
    static let collapseWindow: TimeInterval = 60
    static let perMinuteLimit = 10
    static let maxAhead: TimeInterval = 30 * 86_400
    static let missedAfter: TimeInterval = 600
    static let fileName = "notifications.json"
    static let userInfoKey = "notice"

    static func requestName(_ id: String) -> String { "\(id).notice.json" }

    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".notice.json") }

    static func identifier(_ id: String) -> String { "notice-" + id }

    // MARK: Arguments

    /// A notification from the tool's arguments, or why it cannot be one.
    static func notice(_ args: [String: Any], source: NoticeSource, now: Date, timeZone: TimeZone = .current,
                       id: String = UUID().uuidString) -> Result<AgentNotice, NoticeError> {
        func text(_ name: String) -> String? {
            (args[name] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let title = text("title") else { return .failure(NoticeError("title is required.")) }
        guard title.count <= titleLimit else { return .failure(NoticeError("title is \(title.count) characters; keep it under \(titleLimit).")) }
        let body = text("body")
        if let body, body.count > bodyLimit { return .failure(NoticeError("body is \(body.count) characters; the limit is \(bodyLimit).")) }
        let link = text("link")
        if let link, self.link(link) == nil {
            return .failure(NoticeError("link must be a GitHub pull request url, a Jira key or url, a Slack permalink, another https url "
                                        + "or a WorkTime agent key, not \(link)."))
        }
        var urgency = NoticeUrgency.normal
        if let raw = text("urgency") {
            guard let parsed = NoticeUrgency(rawValue: raw.lowercased()) else { return .failure(NoticeError("urgency must be normal or high.")) }
            urgency = parsed
        }
        var at: Date?
        if let raw = text("at") {
            switch time(raw, now: now, timeZone: timeZone) {
            case .success(let date): at = date
            case .failure(let error): return .failure(error)
            }
        }
        return .success(AgentNotice(id: id, title: title, body: body, link: link, urgency: urgency, source: source, created: now, at: at,
                                    state: at == nil ? .shown : .scheduled))
    }

    /// `at` as a date: ISO 8601 with or without an offset (without one it is local time), or `HH:mm` today, tomorrow once past.
    static func time(_ text: String, now: Date, timeZone: TimeZone = .current) -> Result<Date, NoticeError> {
        let text = text.trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date: Date
        if let match = text.wholeMatch(of: #/(\d{1,2})[:.](\d{2})/#), let hour = Int(match.1), let minute = Int(match.2), hour < 24, minute < 60 {
            guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return .failure(NoticeError("at \(text) could not be read.")) }
            date = today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
        } else if let parsed = isoDate(text, timeZone: timeZone) {
            date = parsed
        } else {
            return .failure(NoticeError("at must be an ISO 8601 date-time like 2026-11-12T13:15 or 2026-11-12T13:15:00+01:00, or HH:mm for today, not \(text)."))
        }
        guard date > now else { return .failure(NoticeError("at \(text) is in the past.")) }
        guard date.timeIntervalSince(now) <= maxAhead else { return .failure(NoticeError("at \(text) is more than 30 days away.")) }
        return .success(date)
    }

    private static func isoDate(_ text: String, timeZone: TimeZone) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func link(_ text: String) -> NoticeLink? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = GitHubLink.pullRequest(at: text) { return .pullRequest(target) }
        if TopicAgents.isKey(text) || Assistants.isKey(text) || Workspaces.isMainKey(text) { return .agent(text) }
        if !text.contains("://"), let key = JiraLogic.issueKey(text) { return .jira(key) }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return .web(url)
    }

    // MARK: Admission

    enum Decision: Equatable {
        case add
        /// The same notification came moments ago: nothing new is shown.
        case collapse(String)
        /// A scheduled one with the same title and time from the same source is updated in place.
        case replace(String)
        case reject(String)
    }

    /// Whether a new notification is shown: repeats collapse, a source sending too many is turned away. `recent` holds what
    /// was taken in the last minute, including ones since dismissed.
    static func admit(_ notice: AgentNotice, existing: [AgentNotice], recent: [AgentNotice], now: Date) -> Decision {
        let identity = notice.source.identity
        if let at = notice.at, let same = existing.first(where: {
            $0.state == .scheduled && $0.source.identity == identity && $0.title == notice.title && $0.at == at
        }) {
            return .replace(same.id)
        }
        let lastMinute = recent.filter { $0.source.identity == identity && now.timeIntervalSince($0.created) < collapseWindow }
        if notice.at == nil, let same = lastMinute.first(where: { $0.at == nil && $0.title == notice.title && $0.body == notice.body }) {
            return .collapse(same.id)
        }
        if lastMinute.count >= perMinuteLimit {
            return .reject("\(lastMinute.count) notifications in the last minute from this source; wait before sending more.")
        }
        return .add
    }

    /// Scheduled notifications whose time has come: shown when at most ten minutes late, otherwise listed as missed.
    static func due(_ notices: [AgentNotice], now: Date) -> (fire: [String], missed: [String]) {
        let passed = notices.filter { $0.state == .scheduled && ($0.at ?? .distantFuture) <= now }
        return (passed.filter { now.timeIntervalSince($0.at!) <= missedAfter }.map(\.id),
                passed.filter { now.timeIntervalSince($0.at!) > missedAfter }.map(\.id))
    }

    /// Why `source` may not cancel the notification `id`, or nil when it may: its own, or any from a Main.
    static func cancelProblem(_ id: String, in notices: [AgentNotice], by source: NoticeSource) -> String? {
        guard let notice = notices.first(where: { $0.id == id }) else { return "No notification with id \(id)." }
        guard notice.state == .scheduled else { return "The notification \(id) has already been shown." }
        guard source.isMain || notice.source.identity == source.identity else {
            return "The notification \(id) was scheduled by \(notice.source.title ?? notice.source.label(titles: [:])); only it or a Main can cancel it."
        }
        return nil
    }

    // MARK: Files and text

    static func encode(_ notices: [AgentNotice]) -> Data { AgentInbox.encode(notices) }

    static func decode(_ data: Data?) -> [AgentNotice] { data.flatMap { AgentInbox.decode([AgentNotice].self, from: $0) } ?? [] }

    static func pending(_ notices: [AgentNotice]) -> [AgentNotice] {
        notices.filter { $0.state == .scheduled }.sorted { $0.date < $1.date }
    }

    static func waiting(_ notices: [AgentNotice]) -> [AgentNotice] {
        notices.filter { $0.state != .scheduled }.sorted { $0.date > $1.date }
    }

    static func line(_ notice: AgentNotice, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parts = ["id \(notice.id)", formatter.string(from: notice.date), notice.title, "from " + (notice.source.title ?? notice.source.label(titles: [:]))]
        if notice.state == .missed { parts.append("missed") }
        if notice.urgency == .high { parts.append("high urgency") }
        if let link = notice.link { parts.append(link) }
        return "- " + parts.joined(separator: " \u{00B7} ")
    }

    static func replyText(_ reply: NoticeReply, scheduled at: Date?, timeZone: TimeZone = .current) -> String {
        guard let at else { return reply.message }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return reply.message + " It fires at \(formatter.string(from: at)); id \(reply.notice ?? "") for cancel_notification."
    }
}
