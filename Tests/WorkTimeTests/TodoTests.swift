import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_793_700_000)

private func item(_ id: String, due: TimeInterval? = nil, created: TimeInterval? = nil) -> TodoItem {
    TodoItem(id: id, text: id, due: due.map { now.addingTimeInterval($0) }, created: created.map { now.addingTimeInterval($0) })
}

private final class FakeTodos: TodoStore {
    var access: TodoAccess
    var items: [TodoItem]
    var lists = [TodoList(id: "home", title: "Home", source: "iCloud")]
    var defaultListID: String? { "home" }

    init(access: TodoAccess, items: [TodoItem]) {
        self.access = access
        self.items = items
    }

    func requestAccess() async -> Bool { access == .granted }
    func todos(in list: String) async throws -> [TodoItem] { items }
    func addTodo(_ text: String, to list: String) throws { items.append(TodoItem(id: text, text: text, due: nil, created: now.addingTimeInterval(100))) }
    func complete(_ id: String) throws { items.removeAll { $0.id == id } }
    func delete(_ id: String) throws { items.removeAll { $0.id == id } }
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private func waiting<T>(_ work: @escaping () async -> T) -> T? {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await work()
        done.signal()
    }
    done.wait()
    return box.value
}

let todoTests: [(name: String, run: () throws -> Void)] = [
    ("reminders are ordered as Reminders lists them: due ones soonest first, then by when they were made", {
        let items = [item("late", created: 30), item("due later", due: 200, created: 0), item("early", created: 10),
                     item("due soon", due: 100, created: 50), item("no dates")]
        check(TodoLogic.ordered(items).map(\.id) == ["due soon", "due later", "early", "late", "no dates"],
              "order \(TodoLogic.ordered(items).map(\.id))")
    }),

    ("a reminder's text is trimmed and an empty one is not added", {
        check(TodoLogic.text("  Buy milk \n") == "Buy milk", "trimmed")
        check(TodoLogic.text("   ") == nil, "blank")
    }),

    ("the stored Reminders list is kept while it exists, otherwise the default list, otherwise the first", {
        let lists = [TodoList(id: "work", title: "Work", source: "Exchange"), TodoList(id: "home", title: "Home", source: "iCloud"),
                     TodoList(id: "shop", title: "Shopping", source: "iCloud")]
        check(TodoLogic.selectedList(stored: "shop", lists: lists, defaultID: "home") == "shop", "stored")
        check(TodoLogic.selectedList(stored: "gone", lists: lists, defaultID: "home") == "home", "deleted list falls back to the default")
        check(TodoLogic.selectedList(stored: nil, lists: lists, defaultID: "missing") == "work", "then the first")
        check(TodoLogic.selectedList(stored: TodoLogic.allLists, lists: lists, defaultID: "home") == TodoLogic.allLists, "All is kept")
        check(TodoLogic.selectedList(stored: nil, lists: [], defaultID: nil) == nil, "no lists")
        check(TodoLogic.title(of: "shop", in: lists) == "Shopping" && TodoLogic.title(of: TodoLogic.allLists, in: lists) == "All", "titles")
        check(TodoLogic.grouped(lists).map(\.source) == ["Exchange", "iCloud"] && TodoLogic.grouped(lists)[1].lists.count == 2, "grouped by account")
    }),

    ("meeting action items reach back 14 days", {
        check(TodoLogic.meetingCutoff(now: now) == now.addingTimeInterval(-14 * 24 * 3600), "cutoff")
    }),

    ("the list loads only with access, ordered, and follows adds and completions", {
        let store = FakeTodos(access: .granted, items: [item("b", created: 20), item("a", created: 10)])
        check(waiting { await TodoLogic.load(from: store, list: "home") }?.map(\.id) == ["a", "b"], "ordered")
        try store.addTodo("c", to: "home")
        try store.complete("a")
        check(waiting { await TodoLogic.load(from: store, list: "home") }?.map(\.id) == ["b", "c"], "after add and complete")
        store.access = .denied
        check(waiting { await TodoLogic.load(from: store, list: "home") }?.isEmpty == true, "nothing without access")
        store.access = .granted
        check(waiting { await TodoLogic.load(from: store, list: nil) }?.isEmpty == true, "nothing without a list")
    }),

    ("meeting todos are the unchecked action items of recent meetings, and checking one hides it", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("todo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let summary = ParsedSummary(MeetingSummary(title: "Standup", actionItems: [.init(task: "Send the report", owner: "Anna"), .init(task: "Book a room", owner: nil)],
                                                   topics: []))
        try store.saveSummary("Meeting-2026-10-28-0900.m4a", summary)
        try store.saveSummary("Meeting-2026-09-01-0900.m4a", summary)
        let since = TodoLogic.meetingCutoff(now: ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!)
        let items = try store.openActionItems(limit: 100, since: since)
        check(items.map(\.task) == ["Send the report", "Book a room"], "recent only \(items.map(\.task))")
        check(items.first?.owner == "Anna", "owner")
        try store.setChecked(actionItem: items[0].id, true)
        check(try store.openActionItems(limit: 100, since: since).map(\.task) == ["Book a room"], "checked one is gone")
        check(try store.schemaVersion() == MeetingStore.migrations.count, "the todos table is created and dropped again")
    }),
]
