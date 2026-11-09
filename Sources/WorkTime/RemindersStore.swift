import EventKit

/// The user's default Reminders list, through EventKit.
final class RemindersStore: TodoStore {
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
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        return await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map {
                    TodoItem(id: $0.calendarItemIdentifier, text: $0.title ?? "", due: $0.dueDateComponents?.date, created: $0.creationDate)
                })
            }
        }
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
}
