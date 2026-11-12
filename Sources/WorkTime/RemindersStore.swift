import EventKit

/// The user's default Reminders list, through EventKit.
final class RemindersStore: ReminderStore {
    let events = EKEventStore()

    var access: TodoAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    var lists: [TodoList] {
        guard access == .granted else { return [] }
        return events.calendars(for: .reminder).map { TodoList(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "") }
    }

    var defaultListID: String? { access == .granted ? events.defaultCalendarForNewReminders()?.calendarIdentifier : nil }

    func requestAccess() async -> Bool {
        (try? await events.requestFullAccessToReminders()) ?? false
    }

    func todos(in list: String) async throws -> [TodoItem] {
        guard access == .granted else { return [] }
        let calendars = list == TodoLogic.allLists ? nil : events.calendar(withIdentifier: list).map { [$0] }
        if list != TodoLogic.allLists && calendars == nil { return [] }
        return await incomplete(in: calendars) {
            TodoItem(id: $0.calendarItemIdentifier, text: $0.title ?? "", due: $0.dueDateComponents?.date, created: $0.creationDate)
        }
    }

    func reminders(in lists: [String]?) async throws -> [AgentReminder] {
        guard access == .granted else { return [] }
        let calendars = lists.map { $0.compactMap(events.calendar(withIdentifier:)) }
        if calendars?.isEmpty == true { return [] }
        return await incomplete(in: calendars, Self.agentReminder)
    }

    func reminder(_ id: String) -> AgentReminder? {
        (events.calendarItem(withIdentifier: id) as? EKReminder).map(Self.agentReminder)
    }

    func add(_ reminder: AgentReminder) throws -> String {
        guard let list = events.calendar(withIdentifier: reminder.list) else { throw ReminderStoreError.noList }
        let saved = EKReminder(eventStore: events)
        saved.title = reminder.title
        saved.calendar = list
        saved.notes = reminder.notes
        saved.url = reminder.link.flatMap(URL.init(string:))
        saved.priority = reminder.priority.eventKit
        if let due = reminder.due {
            let fields: Set<Calendar.Component> = due.allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .timeZone]
            saved.dueDateComponents = Calendar.current.dateComponents(fields, from: due.date)
            if !due.allDay { saved.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        try events.save(saved, commit: true)
        return saved.calendarItemIdentifier
    }

    func addTodo(_ text: String, to list: String) throws {
        guard let list = events.calendar(withIdentifier: list) ?? events.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: events)
        reminder.title = text
        reminder.calendar = list
        try events.save(reminder, commit: true)
    }

    func complete(_ id: String) throws {
        guard let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try events.save(reminder, commit: true)
    }

    func delete(_ id: String) throws {
        guard let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try events.remove(reminder, commit: true)
    }

    private func incomplete<Item>(in calendars: [EKCalendar]?, _ make: @escaping (EKReminder) -> Item) async -> [Item] {
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        return await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(make))
            }
        }
    }

    private static func agentReminder(_ reminder: EKReminder) -> AgentReminder {
        let due = reminder.dueDateComponents.flatMap { components in
            (components.date ?? Calendar.current.date(from: components)).map { ReminderDue(date: $0, allDay: components.hour == nil) }
        }
        return AgentReminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", list: reminder.calendar?.calendarIdentifier ?? "",
                             due: due, link: reminder.url?.absoluteString, notes: reminder.notes, priority: ReminderPriority(eventKit: reminder.priority),
                             completed: reminder.isCompleted)
    }
}

enum ReminderStoreError: LocalizedError {
    case noList

    var errorDescription: String? { "The Reminders list is gone." }
}
