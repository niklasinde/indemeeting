import Foundation

extension MeetingStore: TodoStore {
    static let todosDidChange = Notification.Name("TodosDidChange")

    func todos() throws -> [TodoItem] {
        try read { try db.query("SELECT id, text, done, created, done_at, position, link FROM todos ORDER BY position", [], Self.todo) }
    }

    @discardableResult func addTodo(_ text: String, link: String?, now: Date) throws -> TodoItem {
        try write(notify: Self.todosDidChange) {
            let position = try db.query("SELECT coalesce(max(position), -1) + 1 FROM todos") { Int($0.int64(0)) }.first ?? 0
            try db.run("INSERT INTO todos (text, created, position, link) VALUES (?, ?, ?, ?)", [text, now.timeIntervalSince1970, position, link])
            let id = try db.query("SELECT last_insert_rowid()") { $0.int64(0) }.first ?? 0
            return TodoItem(id: id, text: text, done: false, created: now, doneAt: nil, position: position, link: link)
        }
    }

    func setTodo(_ id: Int64, done: Bool, now: Date) throws {
        try write(notify: Self.todosDidChange) {
            try db.run("UPDATE todos SET done = ?, done_at = ? WHERE id = ?", [done, done ? now.timeIntervalSince1970 : nil, id])
        }
    }

    func deleteTodo(_ id: Int64) throws {
        try write(notify: Self.todosDidChange) { try db.run("DELETE FROM todos WHERE id = ?", [id]) }
    }

    func meetingTodos(since: Date) throws -> [MeetingTodo] {
        try openActionItems(limit: 100, since: since)
    }

    private static func todo(_ row: SQLRow) -> TodoItem {
        TodoItem(id: row.int64(0), text: row.string(1), done: row.bool(2), created: Date(timeIntervalSince1970: row.double(3)),
                 doneAt: row.optionalDouble(4).map(Date.init(timeIntervalSince1970:)), position: Int(row.int64(5)), link: row.optionalString(6))
    }
}
