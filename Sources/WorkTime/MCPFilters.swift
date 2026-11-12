import Foundation

/// Optional, combinable (AND) filters the list tools take. Matching is case-insensitive; an unknown value for a fixed set of
/// choices is an error naming the allowed ones, and the answer starts with a line saying which filters were applied.
enum FilterLogic {
    static func text(_ args: [String: Any], _ name: String) -> String? {
        (args[name] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func choice(_ args: [String: Any], _ name: String, allowed: [String]) throws -> String? {
        guard let raw = text(args, name) else { return nil }
        guard let found = allowed.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) else {
            throw MCPToolError("\(name) must be one of \(allowed.joined(separator: ", ")), not \(raw).")
        }
        return found
    }

    static func flag(_ args: [String: Any], _ name: String) throws -> Bool? {
        switch args[name] {
        case nil, is NSNull: return nil
        case let value as Bool: return value
        case let value as String where ["true", "false"].contains(value.lowercased()): return value.lowercased() == "true"
        default: throw MCPToolError("\(name) must be true or false.")
        }
    }

    static func minutes(_ args: [String: Any], _ name: String) throws -> Double? {
        guard args[name] != nil, !(args[name] is NSNull) else { return nil }
        guard let value = MCPServer.number(args[name]), value >= 0 else { throw MCPToolError("\(name) must be a number of minutes, 0 or more.") }
        return value
    }

    /// A day (`2026-11-13`, a whole day: its start, or with `end` the start of the next), or an ISO 8601 date-time or `HH:mm`.
    static func bound(_ text: String, name: String, end: Bool, now: Date, timeZone: TimeZone = .current) -> Result<Date, NoticeError> {
        if let day = ReminderLogic.day(text, timeZone: timeZone) {
            return .success(end ? ReminderLogic.calendar(timeZone).date(byAdding: .day, value: 1, to: day) ?? day : day)
        }
        guard let date = NoticeLogic.parse(text, now: now, timeZone: timeZone) else {
            return .failure(NoticeError("\(name) must be a date like 2026-11-13, an ISO 8601 date-time or HH:mm, not \(text)."))
        }
        return .success(date)
    }

    static func bound(_ args: [String: Any], _ name: String, end: Bool, now: Date, timeZone: TimeZone = .current) throws -> Date? {
        guard let raw = text(args, name) else { return nil }
        switch bound(raw, name: name, end: end, now: now, timeZone: timeZone) {
        case .success(let date): return date
        case .failure(let error): throw MCPToolError(error.message)
        }
    }

    static func matches(_ value: String?, _ needle: String?) -> Bool {
        guard let needle else { return true }
        return value?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func header(_ applied: [String]) -> String {
        applied.isEmpty ? "" : "Filtered by " + applied.joined(separator: ", ") + "\n"
    }

    static func applied(_ pairs: KeyValuePairs<String, Any?>) -> [String] {
        pairs.compactMap { name, value in
            switch value {
            case let text as String: "\(name) \u{201C}\(text)\u{201D}"
            case let flag as Bool: "\(name) \(flag)"
            case let number as Double: "\(name) \(Int(number))"
            case let date as Date: "\(name) \(ActivityLogic.dateText(date))"
            default: nil
            }
        }
    }

    static func requireOrder(since: Date?, until: Date?) throws {
        if let since, let until, since >= until { throw MCPToolError("since must be before until.") }
    }
}

struct MeetingFilter: Equatable {
    var since: Date?
    var until: Date?
    var with: String?
    var source: String?
    var status: ProcessingStatus?
    var minMinutes: Double?
    var hasActionItems: Bool?
    var query: String?
    private var sinceText: String?
    private var untilText: String?

    static let properties: [String: [String: Any]] = [
        "since": ["type": "string", "description": "Only meetings from this day on: YYYY-MM-DD or an ISO 8601 date-time."],
        "until": ["type": "string", "description": "Only meetings up to and including this day: YYYY-MM-DD, or before this ISO 8601 date-time."],
        "with": ["type": "string", "description": "Only meetings where this person is a named speaker or that is titled with their name."],
        "source": ["type": "string", "description": "Only meetings recorded from this app, like Zoom or Google Meet."],
        "status": ["type": "string", "enum": statuses, "description": "Only meetings in this processing state; summarised meetings are the finished ones."],
        "min_minutes": ["type": "number", "minimum": 0, "description": "Only meetings at least this long."],
        "has_action_items": ["type": "boolean", "description": "true: only meetings with action items still open; false: only those without."],
    ]

    static let statuses = ["none", "summarised", "unavailable", "failed", "stopped"]

    var isEmpty: Bool { self == MeetingFilter() }

    var needsSpeakers: Bool { with != nil }

    init() {}

    init(_ args: [String: Any], now: Date, timeZone: TimeZone = .current) throws {
        since = try FilterLogic.bound(args, "since", end: false, now: now, timeZone: timeZone)
        until = try FilterLogic.bound(args, "until", end: true, now: now, timeZone: timeZone)
        try FilterLogic.requireOrder(since: since, until: until)
        sinceText = FilterLogic.text(args, "since")
        untilText = FilterLogic.text(args, "until")
        with = FilterLogic.text(args, "with")
        source = FilterLogic.text(args, "source")
        status = try FilterLogic.choice(args, "status", allowed: Self.statuses).flatMap(ProcessingStatus.init(rawValue:))
        minMinutes = try FilterLogic.minutes(args, "min_minutes")
        hasActionItems = try FilterLogic.flag(args, "has_action_items")
        query = FilterLogic.text(args, "query")
    }

    var applied: [String] {
        FilterLogic.applied(["since": sinceText, "until": untilText, "with": with, "source": source, "status": status?.rawValue,
                             "min_minutes": minMinutes, "has_action_items": hasActionItems, "query": query])
    }

    func matches(_ meeting: Meeting, speakers: [String] = [], openActionItems: Int = 0) -> Bool {
        (since.map { meeting.created >= $0 } ?? true) && (until.map { meeting.created < $0 } ?? true)
            && (with.map { name in speakers.contains { FilterLogic.matches($0, name) } || FilterLogic.matches(meeting.title, name) } ?? true)
            && (source.map { FilterLogic.matches(meeting.source?.app, $0) || FilterLogic.matches(meeting.source?.title, $0) } ?? true)
            && (status.map { meeting.status == $0 } ?? true)
            && (minMinutes.map { minutes in (meeting.duration ?? 0) >= minutes * 60 } ?? true)
            && (hasActionItems.map { $0 == (openActionItems > 0) } ?? true)
            && (query.map { FilterLogic.matches(meeting.title, $0) || FilterLogic.matches(meeting.notes, $0) } ?? true)
    }

    /// The meetings that pass, with the speakers and open action items looked up only when a filter needs them.
    func apply(_ meetings: [Meeting], in store: MeetingStore) throws -> [Meeting] {
        guard !isEmpty else { return meetings }
        let speakers = needsSpeakers ? try store.speakerNames() : [:]
        let items = hasActionItems != nil ? try store.openActionItemCounts() : [:]
        return meetings.filter { matches($0, speakers: speakers[$0.id] ?? [], openActionItems: items[$0.id] ?? 0) }
    }
}

extension MeetingStore {
    func speakerNames() throws -> [Int64: [String]] {
        try read {
            Dictionary(grouping: try db.query("SELECT meeting_id, name FROM speakers WHERE name IS NOT NULL AND name <> ''") { ($0.int64(0), $0.string(1)) },
                       by: \.0).mapValues { $0.map(\.1) }
        }
    }

    func openActionItemCounts() throws -> [Int64: Int] {
        try read {
            Dictionary(uniqueKeysWithValues: try db.query("SELECT meeting_id, count(*) FROM action_items WHERE checked = 0 GROUP BY meeting_id") {
                ($0.int64(0), Int($0.int64(1)))
            })
        }
    }
}

struct ActivityFilter: Equatable {
    var app: String?
    var repo: String?
    var branch: String?
    var ticket: String?
    var project: String?
    var category: ActivityCategory?

    static let properties: [String: [String: Any]] = [
        "app": ["type": "string", "description": "Only time in this app (part of its name or bundle id)."],
        "repo": ["type": "string", "description": "Only time in repositories matching this (part of owner/name)."],
        "branch": ["type": "string", "description": "Only time on branches matching this."],
        "ticket": ["type": "string", "description": "Only time on tickets matching this, like QDLY-8296 or just QDLY."],
        "project": ["type": "string", "description": "Only time in projects matching this name; Unassigned for time without one."],
        "category": ["type": "string", "enum": ActivityCategory.allCases.map(\.rawValue), "description": "Only time the activity was classified as this."],
    ]

    var isEmpty: Bool { self == ActivityFilter() }

    init() {}

    init(_ args: [String: Any]) throws {
        app = FilterLogic.text(args, "app")
        repo = FilterLogic.text(args, "repo")
        branch = FilterLogic.text(args, "branch")
        ticket = FilterLogic.text(args, "ticket")
        project = FilterLogic.text(args, "project")
        category = try FilterLogic.choice(args, "category", allowed: ActivityCategory.allCases.map(\.rawValue)).flatMap(ActivityCategory.init(rawValue:))
    }

    var applied: [String] {
        FilterLogic.applied(["app": app, "repo": repo, "branch": branch, "ticket": ticket, "project": project, "category": category?.rawValue])
    }

    func matches(_ block: ActivityBlock, rules: [ProjectRule], projects: [Project]) -> Bool {
        let key = block.key
        return (app.map { FilterLogic.matches(key.appName, $0) || FilterLogic.matches(key.appBundle, $0) } ?? true)
            && (repo.map { key.repo != nil && FilterLogic.matches(ActivityLogic.repoLabel(key), $0) } ?? true)
            && (branch.map { FilterLogic.matches(key.branch, $0) } ?? true)
            && (ticket.map { FilterLogic.matches(ActivityLogic.ticket(of: key), $0) } ?? true)
            && (project.map { FilterLogic.matches(ActivityLogic.project(for: block, rules: rules, projects: projects)?.name ?? ActivityLogic.unassigned, $0) } ?? true)
            && (category.map { block.category == $0 } ?? true)
    }
}

struct AgentFilter: Equatable {
    var kind: String?
    var status: String?
    var needsMe: Bool?
    var query: String?

    static let kinds = ["main", "pr", "topic", "assistant"]
    static let statuses = ["working", "waiting", "idle", "error", "signed_out"]

    static let properties: [String: [String: Any]] = [
        "kind": ["type": "string", "enum": kinds, "description": "Only this kind of agent: Main, a pull request's, a topic agent or an assistant."],
        "status": ["type": "string", "enum": statuses, "description": "Only agents in this state."],
        "needs_me": ["type": "boolean", "description": "true: only agents waiting for a permission, finished with an unseen result or errored; false: the others."],
        "query": ["type": "string", "description": "Only agents whose title, folder, last prompt or last result contain this."],
    ]

    var isEmpty: Bool { self == AgentFilter() }

    init() {}

    init(_ args: [String: Any], names: [String] = ["kind", "status", "needs_me", "query"]) throws {
        let args = args.filter { names.contains($0.key) }
        kind = try FilterLogic.choice(args, "kind", allowed: Self.kinds)
        status = try FilterLogic.choice(args, "status", allowed: Self.statuses)
        needsMe = try FilterLogic.flag(args, "needs_me")
        query = FilterLogic.text(args, "query")
    }

    var applied: [String] { FilterLogic.applied(["kind": kind, "status": status, "needs_me": needsMe, "query": query]) }

    static func kind(of state: AgentState) -> String {
        if Workspaces.isMainKey(state.key) { return "main" }
        if state.isAssistant { return "assistant" }
        return state.isTopic ? "topic" : "pr"
    }

    func matches(_ state: AgentState) -> Bool {
        (kind.map { Self.kind(of: state) == $0 } ?? true) && (status.map { state.status.rawValue == $0 } ?? true)
            && (needsMe.map { $0 == (AgentOverview.need(state) <= .error) } ?? true)
            && (query.map { text in [state.title, state.folder, state.lastPrompt, state.lastResult].contains { FilterLogic.matches($0, text) } } ?? true)
    }
}

struct NoticeFilter: Equatable {
    var source: String?
    var urgency: String?
    var dueBefore: Date?
    var dueAfter: Date?
    var query: String?

    static let properties: [String: [String: Any]] = [
        "source": ["type": "string", "description": "Only notifications from this sender (part of the agent's or session's name or folder)."],
        "urgency": ["type": "string", "enum": ["normal", "high"], "description": "Only this urgency."],
        "due_before": ["type": "string", "description": "Only those firing before this: a date (that day counts), ISO 8601 or HH:mm."],
        "due_after": ["type": "string", "description": "Only those firing at or after this: a date, ISO 8601 or HH:mm."],
        "query": ["type": "string", "description": "Only notifications whose title or text contain this."],
    ]

    init(_ args: [String: Any], now: Date, timeZone: TimeZone = .current) throws {
        source = FilterLogic.text(args, "source")
        urgency = try FilterLogic.choice(args, "urgency", allowed: ["normal", "high"])
        dueBefore = try FilterLogic.bound(args, "due_before", end: true, now: now, timeZone: timeZone)
        dueAfter = try FilterLogic.bound(args, "due_after", end: false, now: now, timeZone: timeZone)
        query = FilterLogic.text(args, "query")
    }

    var applied: [String] {
        FilterLogic.applied(["source": source, "urgency": urgency, "due_before": dueBefore, "due_after": dueAfter, "query": query])
    }

    func matches(_ notice: AgentNotice) -> Bool {
        (source.map { text in [notice.source.title, notice.source.label(titles: [:]), notice.source.agent, notice.source.cwd].contains { FilterLogic.matches($0, text) } } ?? true)
            && (urgency.map { notice.urgency.rawValue == $0 } ?? true)
            && (dueBefore.map { notice.date < $0 } ?? true) && (dueAfter.map { notice.date >= $0 } ?? true)
            && (query.map { FilterLogic.matches(notice.title, $0) || FilterLogic.matches(notice.body, $0) } ?? true)
    }
}

/// What `reminders` narrows the app's open reminders to; the list is chosen by the app.
struct ReminderFilter: Equatable {
    var dueBefore: Date?
    var dueAfter: Date?
    var priority: ReminderPriority?
    var query: String?

    func matches(_ reminder: AgentReminder) -> Bool {
        (dueBefore.map { before in reminder.due.map { $0.date < before } ?? false } ?? true)
            && (dueAfter.map { after in reminder.due.map { $0.date >= after } ?? false } ?? true)
            && (priority.map { reminder.priority == $0 } ?? true)
            && (query.map { FilterLogic.matches(reminder.title, $0) || FilterLogic.matches(reminder.notes, $0) } ?? true)
    }
}

/// Structured `jira_search` arguments composed into JQL, every value quoted and escaped.
enum JQLFilter {
    static let properties: [String: [String: Any]] = [
        "assignee": ["type": "string", "description": "me for the user, unassigned, or a name or account id; several separated by commas."],
        "status": ["type": "string", "description": "A status name; several separated by commas."],
        "project": ["type": "string", "description": "A project key; several separated by commas."],
        "type": ["type": "string", "description": "An issue type like Bug; several separated by commas."],
        "priority": ["type": "string", "description": "A priority name; several separated by commas."],
        "text": ["type": "string", "description": "Words in the summary, description or comments."],
        "updated_since": ["type": "string", "description": "Only issues updated from this day on: YYYY-MM-DD, or a JQL offset like -7d."],
        "updated_before": ["type": "string", "description": "Only issues updated before this day: YYYY-MM-DD, or a JQL offset like -1d."],
    ]

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func clauses(_ args: [String: Any]) throws -> [String] {
        func values(_ name: String) -> [String] {
            (FilterLogic.text(args, name) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func match(_ field: String, _ name: String) -> String? {
            let list = values(name)
            return list.isEmpty ? nil : list.count == 1 ? "\(field) = \(quote(list[0]))" : "\(field) in (\(list.map(quote).joined(separator: ", ")))"
        }
        func day(_ name: String, _ comparison: String) throws -> String? {
            guard let text = FilterLogic.text(args, name) else { return nil }
            guard text.wholeMatch(of: #/\d{4}-\d{2}-\d{2}|-\d+[mhdw]/#) != nil else {
                throw MCPToolError("\(name) must be a date like 2026-11-13 or an offset like -7d, not \(text).")
            }
            return "updated \(comparison) \(quote(text))"
        }
        let assignees = values("assignee").map { name -> String in
            switch name.lowercased() {
            case "me", "currentuser": "currentUser()"
            case "unassigned", "none": "EMPTY"
            default: quote(name)
            }
        }
        let assignee = assignees.isEmpty ? nil : assignees == ["EMPTY"] ? "assignee is EMPTY" : "assignee in (\(assignees.joined(separator: ", ")))"
        return try [assignee, match("project", "project"), match("status", "status"), match("issuetype", "type"), match("priority", "priority"),
                    FilterLogic.text(args, "text").map { "text ~ \(quote($0))" }, day("updated_since", ">="), day("updated_before", "<")]
            .compactMap { $0 }
    }

    /// `jql` with the clauses ANDed on; its own ORDER BY stays last. Without clauses `jql` is returned as it is.
    static func compose(jql: String?, clauses: [String]) -> String {
        let jql = (jql ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clauses.isEmpty else { return jql }
        var condition = jql
        var order: String? = jql.isEmpty ? "ORDER BY updated DESC" : nil
        if let match = jql.matches(of: #/(?i)\border\s+by\b/#).last(where: { jql[..<$0.range.lowerBound].filter { $0 == "\"" }.count % 2 == 0 }) {
            condition = String(jql[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            order = String(jql[match.range.lowerBound...])
        }
        let parts = (condition.isEmpty ? [] : ["(\(condition))"]) + clauses
        return parts.joined(separator: " AND ") + (order.map { " " + $0 } ?? "")
    }
}

/// Structured `slack_search` arguments composed into Slack's search modifiers.
enum SlackSearchFilter {
    static let attachments = ["link", "reaction", "pin", "star"]

    static let properties: [String: [String: Any]] = [
        "channel": ["type": "string", "description": "Only messages in this channel, with or without the #."],
        "from": ["type": "string", "description": "Only messages from this person, with or without the @."],
        "since": ["type": "string", "description": "Only messages from this day on: YYYY-MM-DD."],
        "until": ["type": "string", "description": "Only messages up to and including this day: YYYY-MM-DD."],
        "has": ["type": "string", "enum": attachments, "description": "Only messages with a link, a reaction, or that are pinned or starred."],
    ]

    /// The modifiers to append to the query, and the filters they stand for.
    static func modifiers(_ args: [String: Any], now: Date, timeZone: TimeZone = .current) throws -> (terms: [String], applied: [String]) {
        func name(_ argument: String, prefix: Character) throws -> String? {
            guard let raw = FilterLogic.text(args, argument) else { return nil }
            let value = raw.drop { $0 == prefix }
            guard !value.isEmpty, !value.contains(where: \.isWhitespace) else {
                throw MCPToolError("\(argument) must be one name without spaces, not \(raw).")
            }
            return String(value)
        }
        func day(_ argument: String, shift: Int) throws -> String? {
            guard let raw = FilterLogic.text(args, argument) else { return nil }
            guard let date = ReminderLogic.day(raw, timeZone: timeZone) else { throw MCPToolError("\(argument) must be a date like 2026-11-13, not \(raw).") }
            return ReminderLogic.dayText(ReminderLogic.calendar(timeZone).date(byAdding: .day, value: shift, to: date) ?? date, timeZone: timeZone)
        }
        let channel = try name("channel", prefix: "#"), from = try name("from", prefix: "@")
        let has = try FilterLogic.choice(args, "has", allowed: attachments)
        let after = try day("since", shift: -1), before = try day("until", shift: 1)
        try FilterLogic.requireOrder(since: FilterLogic.bound(args, "since", end: false, now: now, timeZone: timeZone),
                                     until: FilterLogic.bound(args, "until", end: true, now: now, timeZone: timeZone))
        let terms = [channel.map { "in:#\($0)" }, from.map { "from:@\($0)" }, after.map { "after:\($0)" }, before.map { "before:\($0)" },
                     has.map { "has:\($0)" }].compactMap { $0 }
        let applied = FilterLogic.applied(["channel": channel.map { "#" + $0 }, "from": from.map { "@" + $0 }, "since": FilterLogic.text(args, "since"),
                                           "until": FilterLogic.text(args, "until"), "has": has])
        return (terms, applied)
    }
}
