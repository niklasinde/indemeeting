import Foundation

extension MeetingStore {
    static let chatsDidChange = Notification.Name("ChatsDidChange")

    private static let chatColumns = "id, title, created, updated, scope_kind, scope_id, scope_from, scope_to, scope_label"

    func chats() throws -> [Chat] {
        try read { try db.query("SELECT \(Self.chatColumns) FROM chats ORDER BY updated DESC, id DESC", [], Self.chat) }
    }

    func chat(id: Int64) throws -> Chat? {
        try read { try db.query("SELECT \(Self.chatColumns) FROM chats WHERE id = ?", [id], Self.chat).first }
    }

    func chatCount(meeting id: Int64) throws -> Int {
        try read {
            try db.query("SELECT count(*) FROM chats WHERE scope_kind IN ('meeting', 'notes') AND scope_id = ?", [id]) { Int($0.int64(0)) }.first ?? 0
        }
    }

    func messages(ofChat id: Int64) throws -> [ChatMessage] {
        try read {
            try db.query("SELECT id, role, text, tool_note, created FROM chat_messages WHERE chat_id = ? ORDER BY id", [id]) {
                ChatMessage(id: $0.int64(0), role: ChatRole(rawValue: $0.string(1)) ?? .assistant, text: $0.string(2),
                            toolNote: $0.optionalString(3), created: Date(timeIntervalSince1970: $0.double(4)))
            }
        }
    }

    func createChat(title: String, scope: ChatScope, now: Date = Date()) throws -> Chat {
        let stamp = now.timeIntervalSince1970
        let id = try write(notify: Self.chatsDidChange) {
            try db.run("""
                INSERT INTO chats (title, created, updated, scope_kind, scope_id, scope_from, scope_to, scope_label)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [title, stamp, stamp, scope.kind.rawValue, scope.id, scope.from?.timeIntervalSince1970,
                      scope.to?.timeIntervalSince1970, scope.label])
            return try db.lastInsertID
        }
        return Chat(id: id, title: title, created: now, updated: now, scope: scope)
    }

    @discardableResult
    func addMessage(chat id: Int64, role: ChatRole, text: String, toolNote: String? = nil, now: Date = Date()) throws -> ChatMessage {
        let stamp = now.timeIntervalSince1970
        let messageID = try write(notify: Self.chatsDidChange) {
            try db.run("INSERT INTO chat_messages (chat_id, role, text, tool_note, created) VALUES (?, ?, ?, ?, ?)",
                       [id, role.rawValue, text, toolNote, stamp])
            let messageID = try db.lastInsertID
            try db.run("UPDATE chats SET updated = ? WHERE id = ?", [stamp, id])
            return messageID
        }
        return ChatMessage(id: messageID, role: role, text: text, toolNote: toolNote, created: now)
    }

    func renameChat(_ id: Int64, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try write(notify: Self.chatsDidChange) { try db.run("UPDATE chats SET title = ? WHERE id = ?", [trimmed, id]) }
    }

    /// Makes a chat general, or gives it another subject.
    func setScope(ofChat id: Int64, _ scope: ChatScope) throws {
        try write(notify: Self.chatsDidChange) {
            try db.run("UPDATE chats SET scope_kind = ?, scope_id = ?, scope_from = ?, scope_to = ?, scope_label = ? WHERE id = ?",
                       [scope.kind.rawValue, scope.id, scope.from?.timeIntervalSince1970, scope.to?.timeIntervalSince1970, scope.label, id])
        }
    }

    func deleteChat(_ id: Int64) throws {
        try write(notify: Self.chatsDidChange) { try db.run("DELETE FROM chats WHERE id = ?", [id]) }
    }

    /// Deletes every chat and returns how many there were.
    func deleteAllChats() throws -> Int {
        try write(notify: Self.chatsDidChange) {
            let count = try db.query("SELECT count(*) FROM chats") { Int($0.int64(0)) }.first ?? 0
            try db.run("DELETE FROM chats")
            return count
        }
    }

    private static func chat(_ row: SQLRow) -> Chat {
        Chat(id: row.int64(0), title: row.string(1), created: Date(timeIntervalSince1970: row.double(2)),
             updated: Date(timeIntervalSince1970: row.double(3)),
             scope: ChatScope(kind: ChatScope.Kind(rawValue: row.string(4)) ?? .general, id: row.isNull(5) ? nil : row.int64(5),
                              from: row.optionalDouble(6).map(Date.init(timeIntervalSince1970:)),
                              to: row.optionalDouble(7).map(Date.init(timeIntervalSince1970:)), label: row.optionalString(8)))
    }
}

extension MeetingStore {
    /// Action items nobody has ticked off, newest meeting first.
    func openActionItems(limit: Int) throws -> [(meeting: Int64, date: Date, title: String, owner: String?, task: String)] {
        try read {
            try db.query("""
                SELECT m.id, m.created, m.title_override, m.ai_title, a.owner, a.task
                FROM action_items a JOIN meetings m ON m.id = a.meeting_id
                WHERE a.checked = 0 ORDER BY m.created DESC, a.position LIMIT ?
                """, [limit]) {
                ($0.int64(0), Date(timeIntervalSince1970: $0.double(1)),
                 LibraryLogic.title(override: $0.optionalString(2), aiTitle: $0.optionalString(3)), $0.optionalString(4), $0.string(5))
            }
        }
    }
}
