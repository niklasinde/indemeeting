import Foundation

/// A due date: a day for an all-day reminder, else a time that also gets an alarm.
struct ReminderDue: Codable, Equatable, Sendable {
    var date: Date
    var allDay = false
}

enum ReminderPriority: String, Codable, CaseIterable, Sendable {
    case none, low, medium, high

    /// EventKit's scale: 1 is high, 5 medium, 9 low, 0 none.
    var eventKit: Int {
        switch self {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }

    init(eventKit: Int) {
        switch eventKit {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}

/// An Apple Reminders reminder as agents see it; `list` is the list's id.
struct AgentReminder: Codable, Equatable, Sendable {
    var id = ""
    var title: String
    var list = ""
    var due: ReminderDue?
    var link: String?
    var notes: String?
    var priority = ReminderPriority.none
    var completed = false
}

/// What `add_reminder` asks for, before the app picks the list and resolves the link.
struct ReminderDraft: Codable, Equatable, Sendable {
    var title: String
    var notes: String?
    var due: ReminderDue?
    var list: String?
    var link: String?
    var priority = ReminderPriority.none
}

/// What the `--mcp` process hands the app through the agent inbox; the app answers with a `NoticeReply`.
struct ReminderRequest: Codable, Equatable {
    enum Action: String, Codable { case add, list, complete }

    var id: String
    var action: Action
    var draft: ReminderDraft?
    var list: String?
    var dueBefore: Date?
    var dueAfter: Date?
    var priority: ReminderPriority?
    var query: String?
    var reminder: String?
    var source: NoticeSource
    var created: Date

    var filter: ReminderFilter { ReminderFilter(dueBefore: dueBefore, dueAfter: dueAfter, priority: priority, query: query) }
}

/// The app's Reminders with what agents need on top of the notch bar's todos: details, adding with a due date, one by id.
protocol ReminderStore: TodoStore {
    /// The incomplete reminders of the lists, or of every list when nil.
    func reminders(in lists: [String]?) async throws -> [AgentReminder]
    func reminder(_ id: String) -> AgentReminder?
    /// Saves a new reminder in `reminder.list` and returns its id.
    func add(_ reminder: AgentReminder) throws -> String
}

enum ReminderLogic {
    static let listLimit = 100

    static func requestName(_ id: String) -> String { "\(id).reminder.json" }

    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".reminder.json") }

    // MARK: Arguments

    static func draft(_ args: [String: Any], now: Date, timeZone: TimeZone = .current) -> Result<ReminderDraft, NoticeError> {
        func text(_ name: String) -> String? {
            (args[name] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let title = text("title") else { return .failure(NoticeError("title is required.")) }
        guard title.count <= NoticeLogic.titleLimit else {
            return .failure(NoticeError("title is \(title.count) characters; keep it under \(NoticeLogic.titleLimit)."))
        }
        let notes = text("notes")
        if let notes, notes.count > NoticeLogic.bodyLimit {
            return .failure(NoticeError("notes is \(notes.count) characters; the limit is \(NoticeLogic.bodyLimit)."))
        }
        let link = text("link")
        if let link, !isLink(link) {
            return .failure(NoticeError("link must be a GitHub pull request (url or owner/repo#number), a Jira key or url, or another https url, not \(link)."))
        }
        var priority = ReminderPriority.none
        if let raw = text("priority") {
            guard let parsed = ReminderPriority(rawValue: raw.lowercased()) else { return .failure(NoticeError("priority must be none, low, medium or high.")) }
            priority = parsed
        }
        var due: ReminderDue?
        if let raw = text("due") {
            switch self.due(raw, now: now, timeZone: timeZone) {
            case .success(let parsed): due = parsed
            case .failure(let error): return .failure(error)
            }
        }
        return .success(ReminderDraft(title: title, notes: notes, due: due, list: text("list"), link: link, priority: priority))
    }

    /// `due` as notify reads `at`, or a date alone (`2026-11-13`) for an all-day reminder, from today up to 30 days ahead.
    static func due(_ text: String, now: Date, timeZone: TimeZone = .current) -> Result<ReminderDue, NoticeError> {
        guard let day = day(text, timeZone: timeZone) else {
            return NoticeLogic.time(text, now: now, timeZone: timeZone, name: "due").map { ReminderDue(date: $0) }
        }
        guard day >= calendar(timeZone).startOfDay(for: now) else { return .failure(NoticeError("due \(text) is in the past.")) }
        guard day.timeIntervalSince(now) <= NoticeLogic.maxAhead else { return .failure(NoticeError("due \(text) is more than 30 days away.")) }
        return .success(ReminderDue(date: day, allDay: true))
    }

    /// `due_before` as a date: a day counts in full, otherwise as notify reads `at`, past or not.
    static func dueBefore(_ text: String, now: Date, timeZone: TimeZone = .current) -> Result<Date, NoticeError> {
        FilterLogic.bound(text, name: "due_before", end: true, now: now, timeZone: timeZone)
    }

    static func dayText(_ date: Date, timeZone: TimeZone = .current) -> String {
        dueText(ReminderDue(date: date, allDay: true), timeZone: timeZone)
    }

    static func day(_ text: String, timeZone: TimeZone) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func isLink(_ text: String) -> Bool {
        if GitHubLink.pasted(text) != nil { return true }
        switch NoticeLogic.link(text) {
        case .web?, .jira?, .pullRequest?: return true
        case .agent?, nil: return false
        }
    }

    /// Where a link points: a pull request's GitHub page, a Jira ticket on the site set up in WorkTime, any other https url.
    static func url(_ link: String, jiraSite: String?) -> URL? {
        if let target = GitHubLink.pasted(link) { return URL(string: target.url) }
        switch NoticeLogic.link(link) {
        case .web(let url)?: return url
        case .jira(let key)?: return jiraSite.flatMap { JiraLogic.browseURL(site: $0, key: key) }
        default: return nil
        }
    }

    /// The reminder's notes: the agent's own, the link (the Reminders app does not always show the url field), and who added it.
    static func notes(_ notes: String?, link: String?, addedBy: String) -> String {
        [notes, link, "Added by \(addedBy)"].compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: Lists and duplicates

    /// The list named `name` (any case), or with no name the list the notch bar shows, else the system default, else the first.
    static func list(named name: String?, in lists: [TodoList], stored: String?, defaultID: String?) -> Result<TodoList, NoticeError> {
        guard !lists.isEmpty else { return .failure(NoticeError("There are no Reminders lists.")) }
        if let name {
            if let list = lists.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return .success(list) }
            return .failure(NoticeError("No Reminders list named \(name). The lists are: \(lists.map(\.title).joined(separator: ", "))."))
        }
        let selected = TodoLogic.selectedList(stored: stored, lists: lists, defaultID: defaultID)
        return .success(lists.first { $0.id == selected } ?? lists.first { $0.id == defaultID } ?? lists[0])
    }

    /// An open reminder in the same list with the same title (any case) and the same due day or minute.
    static func duplicate(of reminder: AgentReminder, in existing: [AgentReminder], timeZone: TimeZone = .current) -> AgentReminder? {
        existing.first {
            !$0.completed && $0.list == reminder.list && $0.title.caseInsensitiveCompare(reminder.title) == .orderedSame
                && sameDue($0.due, reminder.due, timeZone: timeZone)
        }
    }

    private static func sameDue(_ a: ReminderDue?, _ b: ReminderDue?, timeZone: TimeZone) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard a.allDay == b.allDay else { return false }
        return a.allDay ? calendar(timeZone).isDate(a.date, inSameDayAs: b.date) : abs(a.date.timeIntervalSince(b.date)) < 60
    }

    static func accessProblem(_ access: TodoAccess) -> String? {
        switch access {
        case .granted: nil
        case .unknown: "WorkTime has not been given Reminders access yet. Ask the user to open the Reminders list in WorkTime's notch bar and allow it."
        case .denied: "WorkTime is not allowed to use Reminders. Ask the user to allow it in System Settings > Privacy & Security > Reminders."
        }
    }

    // MARK: The app's side

    /// What the app does with a request, against its Reminders store. `addedBy` names the sender in the notes.
    static func handle(_ request: ReminderRequest, store: (any ReminderStore)?, stored: String?, addedBy: String, jiraSite: String?,
                       now: Date, timeZone: TimeZone = .current) async -> NoticeReply {
        func reply(_ ok: Bool, _ id: String?, _ message: String) -> NoticeReply { NoticeReply(id: request.id, ok: ok, notice: id, message: message) }
        guard abs(now.timeIntervalSince(request.created)) <= AgentInbox.staleAfter else { return reply(false, nil, "The request is too old.") }
        guard let store else { return reply(false, nil, "WorkTime has not opened Reminders yet.") }
        if let problem = accessProblem(store.access) { return reply(false, nil, problem) }
        let lists = store.lists
        func title(_ id: String) -> String { lists.first { $0.id == id }?.title ?? id }
        do {
            switch request.action {
            case .add:
                guard let draft = request.draft else { return reply(false, nil, "title is required.") }
                let list: TodoList
                switch self.list(named: draft.list, in: lists, stored: stored, defaultID: store.defaultListID) {
                case .success(let found): list = found
                case .failure(let error): return reply(false, nil, error.message)
                }
                let url = draft.link.flatMap { self.url($0, jiraSite: jiraSite) }
                var reminder = AgentReminder(title: draft.title, list: list.id, due: draft.due, link: url?.absoluteString,
                                             notes: notes(draft.notes, link: url?.absoluteString ?? draft.link, addedBy: addedBy), priority: draft.priority)
                if let same = duplicate(of: reminder, in: try await store.reminders(in: [list.id]), timeZone: timeZone) {
                    return reply(true, same.id, "\"\(same.title)\" is already open in \(list.title), so it was not added again; id \(same.id).")
                }
                reminder.id = try store.add(reminder)
                return reply(true, reminder.id, "Added \"\(reminder.title)\" to \(list.title)" + (reminder.due.map { ", due " + dueText($0, timeZone: timeZone) } ?? "")
                             + "; id \(reminder.id).")
            case .list:
                var ids: [String]?
                if let name = request.list {
                    switch self.list(named: name, in: lists, stored: stored, defaultID: store.defaultListID) {
                    case .success(let found): ids = [found.id]
                    case .failure(let error): return reply(false, nil, error.message)
                    }
                }
                let open = open(try await store.reminders(in: ids), filter: request.filter)
                guard !open.isEmpty else { return reply(true, nil, "No open reminders.\n") }
                let lines = open.prefix(listLimit).map { line($0, list: title($0.list), timeZone: timeZone) }
                return reply(true, nil, lines.joined(separator: "\n") + (open.count > listLimit ? "\n\(open.count - listLimit) more not shown." : "") + "\n")
            case .complete:
                guard let id = request.reminder, let reminder = store.reminder(id) else { return reply(false, nil, "No reminder with id \(request.reminder ?? "")." ) }
                guard !reminder.completed else { return reply(false, id, "\"\(reminder.title)\" is already completed.") }
                try store.complete(id)
                return reply(true, id, "Completed \"\(reminder.title)\" in \(title(reminder.list)).")
            }
        } catch {
            return reply(false, nil, "Reminders refused: \(error.localizedDescription)")
        }
    }

    /// Open reminders matching the filter, due ones soonest first.
    static func open(_ reminders: [AgentReminder], filter: ReminderFilter) -> [AgentReminder] {
        let open = reminders.filter { !$0.completed && filter.matches($0) }
        return open.enumerated().sorted { a, b in
            switch (a.element.due?.date, b.element.due?.date) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    static func line(_ reminder: AgentReminder, list: String, timeZone: TimeZone = .current) -> String {
        var parts = ["id \(reminder.id)", list, reminder.title]
        if let due = reminder.due { parts.append("due " + dueText(due, timeZone: timeZone)) }
        if reminder.priority != .none { parts.append("\(reminder.priority.rawValue) priority") }
        if let link = reminder.link { parts.append(link) }
        return "- " + parts.joined(separator: " \u{00B7} ")
    }

    static func dueText(_ due: ReminderDue, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = due.allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: due.date)
    }
}
