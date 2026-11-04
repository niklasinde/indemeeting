import Foundation

struct TodoItem: Identifiable, Equatable {
    var id: String
    var text: String
    var due: Date?
    var created: Date?
}

struct MeetingTodo: Identifiable, Equatable {
    var id: Int64
    var meeting: Int64
    var date: Date
    var title: String
    var owner: String?
    var task: String
}

struct TodoList: Identifiable, Equatable {
    var id: String
    var title: String
    var source: String
}

enum TodoAccess {
    case unknown
    case granted
    case denied
}

/// Where the notch bar's todos come from: Apple Reminders in the app, a fake in the tests.
protocol TodoStore: AnyObject {
    var access: TodoAccess { get }
    var lists: [TodoList] { get }
    var defaultListID: String? { get }
    func requestAccess() async -> Bool
    /// The incomplete todos of one list, or of every list when the id is `TodoLogic.allLists`.
    func todos(in list: String) async throws -> [TodoItem]
    func addTodo(_ text: String, to list: String) throws
    func complete(_ id: String) throws
    func delete(_ id: String) throws
}

enum TodoLogic {
    static let meetingDays = 14
    static let todoLimit = 8
    static let meetingLimit = 5
    static let allLists = "all"
    static let listKey = "todoListID"

    static func text(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// As Reminders lists them: those with a due date first, soonest first, then the rest by when they were made.
    static func ordered(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture)
            }
        }
    }

    /// The stored list while it still exists, otherwise the default list, otherwise the first one.
    static func selectedList(stored: String?, lists: [TodoList], defaultID: String?) -> String? {
        if stored == allLists || lists.contains(where: { $0.id == stored }) { return stored }
        return lists.contains { $0.id == defaultID } ? defaultID : lists.first?.id
    }

    static func title(of list: String?, in lists: [TodoList]) -> String {
        list == allLists ? "All" : lists.first { $0.id == list }?.title ?? "Reminders"
    }

    /// The lists grouped by account, in the order the accounts first appear.
    static func grouped(_ lists: [TodoList]) -> [(source: String, lists: [TodoList])] {
        var order: [String] = []
        for list in lists where !order.contains(list.source) { order.append(list.source) }
        return order.map { source in (source, lists.filter { $0.source == source }) }
    }

    static func load(from store: any TodoStore, list: String?) async -> [TodoItem] {
        guard store.access == .granted, let list else { return [] }
        return ordered((try? await store.todos(in: list)) ?? [])
    }

    static func meetingCutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(meetingDays) * 24 * 3600)
    }
}
