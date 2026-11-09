import Foundation

struct ClaudeAPIChat: Identifiable, Equatable {
    let id: Int64
    let title: String
    let created: Date
    let updated: Date

    static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "New chat" : String(trimmed.prefix(60))
    }
}

struct ClaudeAPIStoredMessage: Identifiable, Equatable {
    let id: Int64
    let role: ClaudeAPIMessage.Role
    let text: String
    let usage: ClaudeAPIUsage?
    let created: Date
}

/// Claude API chats, kept apart from the Claude Code chats in `chats` so the two never share a list or a query.
extension MeetingStore {
    static let claudeAPIDidChange = Notification.Name("ClaudeAPIDidChange")

    func claudeAPIChats() throws -> [ClaudeAPIChat] {
        try read {
            try db.query("SELECT id, title, created, updated FROM api_chats ORDER BY updated DESC, id DESC") {
                ClaudeAPIChat(id: $0.int64(0), title: $0.string(1), created: Date(timeIntervalSince1970: $0.double(2)),
                              updated: Date(timeIntervalSince1970: $0.double(3)))
            }
        }
    }

    func claudeAPIMessages(chat id: Int64) throws -> [ClaudeAPIStoredMessage] {
        try read {
            try db.query("SELECT id, role, text, input_tokens, output_tokens, created FROM api_messages WHERE chat_id = ? ORDER BY id", [id]) {
                let input = $0.optionalDouble(3).map(Int.init)
                let output = $0.optionalDouble(4).map(Int.init)
                return ClaudeAPIStoredMessage(id: $0.int64(0), role: ClaudeAPIMessage.Role(rawValue: $0.string(1)) ?? .assistant,
                                              text: $0.string(2),
                                              usage: input.flatMap { i in output.map { ClaudeAPIUsage(inputTokens: i, outputTokens: $0) } },
                                              created: Date(timeIntervalSince1970: $0.double(5)))
            }
        }
    }

    @discardableResult
    func createClaudeAPIChat(title: String, now: Date = Date()) throws -> Int64 {
        let stamp = now.timeIntervalSince1970
        return try write(notify: Self.claudeAPIDidChange) {
            try db.run("INSERT INTO api_chats (title, created, updated) VALUES (?, ?, ?)", [title, stamp, stamp])
            return try db.lastInsertID
        }
    }

    func addClaudeAPIMessage(chat id: Int64, role: ClaudeAPIMessage.Role, text: String, usage: ClaudeAPIUsage? = nil, now: Date = Date()) throws {
        let stamp = now.timeIntervalSince1970
        try write(notify: Self.claudeAPIDidChange) {
            try db.run("INSERT INTO api_messages (chat_id, role, text, input_tokens, output_tokens, created) VALUES (?, ?, ?, ?, ?, ?)",
                       [id, role.rawValue, text, usage?.inputTokens, usage?.outputTokens, stamp])
            try db.run("UPDATE api_chats SET updated = ? WHERE id = ?", [stamp, id])
        }
    }

    func deleteClaudeAPIChat(_ id: Int64) throws {
        try write(notify: Self.claudeAPIDidChange) { try db.run("DELETE FROM api_chats WHERE id = ?", [id]) }
    }

    /// Deletes every Claude API chat and returns how many there were. Claude Code chats are not touched.
    func deleteAllClaudeAPIChats() throws -> Int {
        try write(notify: Self.claudeAPIDidChange) {
            let count = try db.query("SELECT count(*) FROM api_chats") { Int($0.int64(0)) }.first ?? 0
            try db.run("DELETE FROM api_chats")
            return count
        }
    }
}
