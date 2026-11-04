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

enum TodoAccess {
    case unknown
    case granted
    case denied
}

/// Where the notch bar's todos come from: Apple Reminders in the app, a fake in the tests.
protocol TodoStore: AnyObject {
    var access: TodoAccess { get }
    var listTitle: String? { get }
    func requestAccess() async -> Bool
    func todos() async throws -> [TodoItem]
    func addTodo(_ text: String) throws
    func complete(_ id: String) throws
    func delete(_ id: String) throws
}

enum TodoLogic {
    static let meetingDays = 14
    static let todoLimit = 8
    static let meetingLimit = 5

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

    static func load(from store: any TodoStore) async -> [TodoItem] {
        guard store.access == .granted else { return [] }
        return ordered((try? await store.todos()) ?? [])
    }

    static func meetingCutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(meetingDays) * 24 * 3600)
    }
}
