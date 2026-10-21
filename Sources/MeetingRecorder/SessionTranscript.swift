import Foundation

/// One thing a session's chat shows: what the person wrote, what Claude said, or a tool Claude ran.
struct TranscriptEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        case user
        case assistant
        case tool(name: String)
    }

    let id: String
    let kind: Kind
    /// The message text, or the command, path or pattern a tool was given.
    let text: String
}

/// A line the person sent from the send box, shown at once and dropped when its transcript line arrives. `baseline` is how many
/// entries existed when it was sent, so only later user lines can match it.
struct PendingMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let baseline: Int
}

/// Turns the lines of a Claude Code transcript (`~/.claude/projects/<folder>/<id>.jsonl`) into chat entries. Pure: a line that is not
/// JSON, has an unknown shape, is a sidechain or meta line, or holds nothing to show gives no entries.
enum SessionTranscript {
    static func entries(line: String, id: String) -> [TranscriptEntry] {
        guard let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return [] }
        switch object["type"] as? String {
        case "user": return user(message, id: id)
        case "assistant": return assistant(message, id: id)
        default: return []
        }
    }

    private static func user(_ message: [String: Any], id: String) -> [TranscriptEntry] {
        let text: String
        if let plain = message["content"] as? String {
            text = plain
        } else {
            text = (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        let shown = visibleText(text)
        return shown.isEmpty ? [] : [TranscriptEntry(id: id, kind: .user, text: shown)]
    }

    private static func assistant(_ message: [String: Any], id: String) -> [TranscriptEntry] {
        (message["content"] as? [[String: Any]] ?? []).enumerated().compactMap { index, block -> TranscriptEntry? in
            let blockID = "\(id)-\(index)"
            switch block["type"] as? String {
            case "text":
                let shown = visibleText(block["text"] as? String ?? "")
                return shown.isEmpty ? nil : TranscriptEntry(id: blockID, kind: .assistant, text: shown)
            case "tool_use":
                return TranscriptEntry(id: blockID, kind: .tool(name: block["name"] as? String ?? "tool"),
                                       text: toolDetail(block["input"] as? [String: Any] ?? [:]))
            default:
                return nil
            }
        }
    }

    private static let hiddenTags = ["system-reminder", "local-command-stdout", "local-command-stderr", "local-command-caveat",
                                     "command-message", "command-args"]

    /// The text without the reminders and command plumbing Claude Code wraps around what was typed. A slash command shows as its name.
    static func visibleText(_ text: String) -> String {
        if let name = firstMatch(in: text, pattern: "<command-name>([\\s\\S]*?)</command-name>") {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var shown = text
        for tag in hiddenTags {
            shown = shown.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        return shown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a tool was asked to do, in the first of its inputs that names it.
    static func toolDetail(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// What the chat shows for the transcript's lines. A pending send is matched by a later user line with the same text.
    static func reconcile(_ pending: [PendingMessage], with entries: [TranscriptEntry]) -> [PendingMessage] {
        pending.filter { message in
            !entries.enumerated().contains { index, entry in
                index >= message.baseline && entry.kind == .user && entry.text == message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// The transcript as text to copy: one paragraph per entry, tool activity on a line of its own.
    static func plainText(_ entries: [TranscriptEntry]) -> String {
        entries.map { entry -> String in
            switch entry.kind {
            case .user: return "You: " + entry.text
            case .assistant: return "Claude: " + entry.text
            case .tool(let name): return "[\(name)] " + entry.text
            }
        }
        .joined(separator: "\n\n")
    }
}

/// Where a read of a transcript file has got to. The caller reads the bytes; this decides where to read from, what a shrunken or
/// replaced file means, and which complete lines the bytes give. A line without its newline waits for the next read.
struct TranscriptTail {
    /// The first read of a bigger file starts this far from its end, so opening a long session stays quick.
    static let window: UInt64 = 4_000_000

    private(set) var offset: UInt64 = 0
    private(set) var fileID: UInt64?
    private var carry = Data()
    private var started = false
    private var skipsFirstLine = false

    /// Where to read from, given the file's size and identity now. A file that shrank or changed identity starts again.
    mutating func readStart(size: UInt64, fileID: UInt64?) -> (from: UInt64, restarted: Bool) {
        var restarted = false
        if started, size < offset || (self.fileID != nil && fileID != nil && self.fileID != fileID) {
            started = false
            restarted = true
        }
        if !started {
            started = true
            offset = 0
            carry = Data()
            self.fileID = fileID
            if size > Self.window {
                offset = size - Self.window
                skipsFirstLine = true
            }
        }
        return (offset, restarted)
    }

    /// The complete lines among the bytes read from the offset. Advances the offset over all of them.
    mutating func consume(_ data: Data) -> [String] {
        offset += UInt64(data.count)
        let buffer = carry + data
        carry = Data()
        var lines: [String] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[start..<newline], as: UTF8.self))
            start = buffer.index(after: newline)
        }
        carry = Data(buffer[start...])
        if skipsFirstLine, !lines.isEmpty {
            lines.removeFirst()
            skipsFirstLine = false
        }
        return lines.filter { !$0.isEmpty }
    }

    /// Reads what the file gained since the last read; nil when the file cannot be read.
    mutating func read(_ url: URL, fileManager: FileManager = .default) -> (lines: [String], restarted: Bool)? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let (from, restarted) = readStart(size: size, fileID: identity)
        guard size > from else { return ([], restarted) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: from)
        return (consume(handle.readData(ofLength: Int(size - from))), restarted)
    }
}
