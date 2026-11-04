import Foundation

struct TodoItem: Identifiable, Equatable {
    var id: Int64
    var text: String
    var done: Bool
    var created: Date
    var doneAt: Date?
    var position: Int
    var link: String?
}

struct MeetingTodo: Identifiable, Equatable {
    var id: Int64
    var meeting: Int64
    var date: Date
    var title: String
    var owner: String?
    var task: String
}

/// Where the notch bar's todos are kept: the database for now, so a store backed by Apple Reminders can take its place.
protocol TodoStore: AnyObject {
    func todos() throws -> [TodoItem]
    @discardableResult func addTodo(_ text: String, link: String?, now: Date) throws -> TodoItem
    func setTodo(_ id: Int64, done: Bool, now: Date) throws
    func deleteTodo(_ id: Int64) throws
    func meetingTodos(since: Date) throws -> [MeetingTodo]
    func setChecked(actionItem id: Int64, _ checked: Bool) throws
}

enum TodoLogic {
    static let meetingDays = 14
    static let todoLimit = 8
    static let meetingLimit = 5

    static func text(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The todos still to do, in the order they were added.
    static func open(_ items: [TodoItem]) -> [TodoItem] {
        items.filter { !$0.done }.sorted { ($0.position, $0.created) < ($1.position, $1.created) }
    }

    static func meetingCutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(meetingDays) * 24 * 3600)
    }
}
