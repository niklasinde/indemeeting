import Foundation

/// What the user walks into a meeting knowing: who is in it, what the last meetings with them decided and left open, the tickets
/// and pull requests it names, and its agenda.
struct MeetingBrief: Equatable, Identifiable {
    var event: CalendarEventInfo
    /// The earlier meetings that match best, newest information first, with their decisions and open items filled in.
    var earlier: [PastMeeting] = []
    var tickets: [InCallCard.Ticket] = []
    var pullRequests: [InCallCard.PullRequest] = []
    var agenda: String?
    var focus: String?

    var id: String { MeetingBriefLogic.key(event) }
}

struct BriefSection: Equatable {
    enum Kind: String { case people, lastTime, open, ticket, pullRequest, agenda, focus }

    let kind: Kind
    let label: String
    var lines: [String]
}

/// Asks the app for a brief on behalf of the `--mcp` process, through the agent inbox; the app answers with a `NoticeReply`.
struct BriefRequest: Codable, Equatable {
    var id: String
    var event: String?
    var created: Date
}

enum MeetingBriefLogic {
    static let enabledKey = "meetingBriefs"
    static let leadKey = "meetingBriefLead"
    static let leadChoices = [5, 10, 15]
    static let defaultLead = 10
    static let fileName = "briefed-meetings.json"
    static let userInfoKey = "meetingBrief"
    static let keepBriefed: TimeInterval = 14 * 86400
    static let decisionLimit = 3, openLimit = 5, ticketLimit = 4, pullRequestLimit = 4, earlierLimit = 3

    static func requestName(_ id: String) -> String { "\(id).brief.json" }
    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".brief.json") }

    /// On when set; until then on only if the calendar can already be read.
    static func isEnabled(hasAccess: Bool, defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? hasAccess }

    static func lead(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: leadKey)
        return leadChoices.contains(stored) ? stored : defaultLead
    }

    /// One brief per occurrence: a recurring event keeps its id, so the start tells the occurrences apart.
    static func key(_ event: CalendarEventInfo) -> String { "\(event.id)|\(Int(event.start.timeIntervalSince1970))" }

    /// A meeting rather than a block in the calendar: not all-day, declined or cancelled, with someone else invited or a call link.
    static func isMeeting(_ event: CalendarEventInfo) -> Bool {
        !event.isAllDay && !event.declined && !event.cancelled && (!event.attendees.isEmpty || CalendarLogic.service(of: event) != nil)
    }

    /// The meetings to brief now: starting within `lead` minutes and not yet started, not briefed before, and none while a call is
    /// being recorded.
    static func due(_ events: [CalendarEventInfo], now: Date, lead: Int, recording: Bool, briefed: Set<String>) -> [CalendarEventInfo] {
        guard !recording else { return [] }
        let until = now.addingTimeInterval(TimeInterval(lead) * 60)
        return events.filter { isMeeting($0) && $0.start > now && $0.start <= until && !briefed.contains(key($0)) }.sorted { $0.start < $1.start }
    }

    /// For `meeting_brief`: the meeting named by `query` (its id or part of its title), else the next one today.
    static func pick(_ events: [CalendarEventInfo], query: String?, now: Date, timeZone: TimeZone = .current) -> CalendarEventInfo? {
        let meetings = events.filter { isMeeting($0) && $0.end > now }.sorted { $0.start < $1.start }
        if let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            return meetings.first { $0.id == query || key($0) == query } ?? meetings.first { $0.title.localizedCaseInsensitiveContains(query) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return meetings.first { $0.start > now && calendar.isDate($0.start, inSameDayAs: now) }
    }

    static func decodeBriefed(_ data: Data?) -> [String: Date] { data.flatMap { AgentInbox.decode([String: Date].self, from: $0) } ?? [:] }

    static func encode(_ briefed: [String: Date]) -> Data { AgentInbox.encode(briefed) }

    /// The briefed keys without those of meetings over two weeks ago.
    static func pruned(_ briefed: [String: Date], now: Date) -> [String: Date] { briefed.filter { now.timeIntervalSince($0.value) < keepBriefed } }

    static func context(_ event: CalendarEventInfo, entities: [SpottedEntity], now: Date) -> RetrievalContext {
        RetrievalContext(entities: Set(entities.map(\.id)), title: event.title, attendees: event.attendees.map(\.identity), seriesID: event.seriesID, now: now)
    }

    // MARK: Text

    /// With no history, tickets or agenda there is only who and when: shown when someone is invited, skipped otherwise.
    static func isEmpty(_ brief: MeetingBrief) -> Bool { sections(brief).allSatisfy { $0.kind == .people } }

    static func worthShowing(_ brief: MeetingBrief) -> Bool { !isEmpty(brief) || !brief.event.attendees.isEmpty }

    static func sections(_ brief: MeetingBrief) -> [BriefSection] {
        var sections: [BriefSection] = []
        let people = brief.event.attendees.map(\.label).filter { !$0.isEmpty }
        if !people.isEmpty { sections.append(BriefSection(kind: .people, label: "With", lines: [list(people, limit: 6)])) }
        if let last = brief.earlier.first {
            let points = Array(last.decisions.prefix(decisionLimit))
            if !points.isEmpty { sections.append(BriefSection(kind: .lastTime, label: "Last time \u{00B7} \(day(last.date))", lines: points)) }
        }
        let open = brief.earlier.flatMap { meeting in meeting.openItems.map { "\($0) (\(day(meeting.date)))" } }
        if !open.isEmpty { sections.append(BriefSection(kind: .open, label: "Still open", lines: Array(open.prefix(openLimit)))) }
        for ticket in brief.tickets.prefix(ticketLimit) {
            sections.append(BriefSection(kind: .ticket, label: ticket.key, lines: [[ticket.summary, ticket.status, ticket.assignee].compactMap { $0 }.joined(separator: " \u{00B7} ")]))
        }
        for pr in brief.pullRequests.prefix(pullRequestLimit) {
            sections.append(BriefSection(kind: .pullRequest, label: pr.label,
                                         lines: [[pr.title, pr.state, pr.checks, pr.review].compactMap { $0 }.joined(separator: " \u{00B7} ")]))
        }
        if let agenda = brief.agenda, !agenda.isEmpty {
            sections.append(BriefSection(kind: .agenda, label: "Agenda", lines: Array(agenda.components(separatedBy: .newlines).prefix(4))))
        }
        if let focus = brief.focus, !focus.isEmpty { sections.append(BriefSection(kind: .focus, label: "Aim", lines: [focus])) }
        return sections
    }

    /// `Weekly sync, 13:15\u{2013}13:45` and one bullet per section.
    static func text(_ brief: MeetingBrief, timeZone: TimeZone = .current) -> String {
        var lines = ["\(brief.event.title), \(time(brief.event.start, timeZone))\u{2013}\(time(brief.event.end, timeZone))"]
        for section in sections(brief) {
            if section.lines.count == 1 {
                lines.append("\u{2022} \(section.label): \(section.lines[0])")
            } else {
                lines.append("\u{2022} \(section.label):")
                lines += section.lines.map { "   - \($0)" }
            }
        }
        if isEmpty(brief) && brief.event.attendees.isEmpty { lines.append("\u{2022} Nothing to prepare: no one else is invited and nothing earlier matches.") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func notificationTitle(_ event: CalendarEventInfo, now: Date) -> String {
        let minutes = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(event.title) in \(minutes) min"
    }

    /// The first lines of the brief, for the notification.
    static func notificationBody(_ brief: MeetingBrief) -> String {
        let lines = sections(brief).prefix(3).map { section in "\(section.label): \(section.lines.first ?? "")" }
        return String(lines.joined(separator: "\n").prefix(220))
    }

    private static func list(_ names: [String], limit: Int) -> String { names.prefix(limit).joined(separator: ", ") + (names.count > limit ? " +\(names.count - limit)" : "") }

    static func time(_ date: Date, _ timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB"))) }
}

enum MeetingBriefPrompts {
    static let schema: [String: Any] = ["type": "object", "required": ["aim"], "properties": ["aim": ["type": "string"]]]

    static func aim(_ brief: MeetingBrief) -> (system: String, prompt: String) {
        let system = """
            You prepare someone for a meeting. Answer in the language of the notes with an aim of two or three short lines: what to get out of \
            it, from the notes given. Use only the notes; do not invent facts. aim: the text.
            """
        return (system, MeetingBriefLogic.text(brief))
    }

    static func parse(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any],
              let aim = (json["aim"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !aim.isEmpty else { return nil }
        return aim
    }
}
