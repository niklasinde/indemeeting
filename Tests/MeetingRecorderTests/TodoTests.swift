import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func withTodoStore(_ body: (MeetingStore) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("todo-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite")))
}

private let now = Date(timeIntervalSince1970: 1_793_700_000)

private func todo(_ id: Int64, position: Int, done: Bool = false, created: TimeInterval = 0) -> TodoItem {
    TodoItem(id: id, text: "todo \(id)", done: done, created: now.addingTimeInterval(created), doneAt: done ? now : nil, position: position)
}

let todoTests: [(name: String, run: () throws -> Void)] = [
    ("open todos leave out the done ones and keep the order they were added in", {
        let items = [todo(1, position: 2), todo(2, position: 0, done: true), todo(3, position: 1), todo(4, position: 1, created: -5)]
        check(TodoLogic.open(items).map(\.id) == [4, 3, 1], "order \(TodoLogic.open(items).map(\.id))")
    }),

    ("a todo's text is trimmed and an empty one is not added", {
        check(TodoLogic.text("  Buy milk \n") == "Buy milk", "trimmed")
        check(TodoLogic.text("   ") == nil, "blank")
    }),

    ("meeting action items reach back 14 days", {
        check(TodoLogic.meetingCutoff(now: now) == now.addingTimeInterval(-14 * 24 * 3600), "cutoff")
    }),

    ("todos round-trip, completing one stamps it and deleting removes it", {
        try withTodoStore { store in
            let first = try store.addTodo("Write the release note", link: nil, now: now)
            let second = try store.addTodo("Book the room", link: "https://example.com", now: now.addingTimeInterval(1))
            check(try store.todos().map(\.text) == ["Write the release note", "Book the room"], "added in order")
            check(second.position == first.position + 1, "positions grow")
            try store.setTodo(first.id, done: true, now: now.addingTimeInterval(60))
            let done = try store.todos().first { $0.id == first.id }
            check(done?.done == true && done?.doneAt == now.addingTimeInterval(60), "done with a date")
            check(TodoLogic.open(try store.todos()).map(\.id) == [second.id], "only the open one is shown")
            try store.setTodo(first.id, done: false, now: now)
            check(try store.todos().first { $0.id == first.id }?.doneAt == nil, "undoing clears the date")
            try store.deleteTodo(second.id)
            check(try store.todos().map(\.id) == [first.id], "deleted")
            check(try store.todos().last?.link == nil, "no link")
        }
    }),

    ("meeting todos are the unchecked action items of recent meetings, and checking one hides it", {
        try withTodoStore { store in
            let summary = ParsedSummary(MeetingSummary(title: "Standup", actionItems: [.init(task: "Send the report", owner: "Anna"), .init(task: "Book a room", owner: nil)],
                                                       topics: []))
            try store.saveSummary("Meeting-2026-10-28-0900.m4a", summary)
            try store.saveSummary("Meeting-2026-09-01-0900.m4a", summary)
            let since = TodoLogic.meetingCutoff(now: ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!)
            let items = try store.meetingTodos(since: since)
            check(items.map(\.task) == ["Send the report", "Book a room"], "recent only \(items.map(\.task))")
            check(items.first?.owner == "Anna", "owner")
            try store.setChecked(actionItem: items[0].id, true)
            check(try store.meetingTodos(since: since).map(\.task) == ["Book a room"], "checked one is gone")
        }
    }),
]
