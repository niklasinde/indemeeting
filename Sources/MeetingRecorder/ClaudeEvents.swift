import Foundation

/// One line of the inbox the Claude Code plugin's hooks append to (`plugin/hooks/record-event.sh`).
struct ClaudeHookEvent: Equatable {
    enum Kind: String {
        case sessionStart = "SessionStart"
        case prompt = "UserPromptSubmit"
        case tool = "PostToolUse"
        case notification = "Notification"
        case subagentStop = "SubagentStop"
        case stop = "Stop"
        case sessionEnd = "SessionEnd"
    }

    var time: Date
    var kind: Kind
    var sessionID: String
    var cwd: String?
    var transcriptPath: String?
    /// Only there when the user let the hook keep prompt text.
    var prompt: String?

    init(time: Date, kind: Kind, sessionID: String, cwd: String? = nil, transcriptPath: String? = nil, prompt: String? = nil) {
        self.time = time
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.prompt = prompt
    }

    init?(line: Substring) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let time = object["time"] as? Double, let kind = (object["event"] as? String).flatMap(Kind.init),
              let id = object["session_id"] as? String, !id.isEmpty else { return nil }
        func text(_ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(time: Date(timeIntervalSince1970: time), kind: kind, sessionID: id, cwd: text("cwd"),
                  transcriptPath: text("transcript_path"), prompt: text("prompt"))
    }

    /// The events of whole lines; unreadable lines are skipped.
    static func parse(_ text: Substring) -> [ClaudeHookEvent] {
        text.split(whereSeparator: \.isNewline).compactMap { ClaudeHookEvent(line: $0) }
    }
}

/// Reads what the hooks appended since the last read. A line still being written waits for the next read. Past
/// `rotateBytes` the file is moved to `<name>.1` (replacing the previous one) and its rest read, so hooks start a
/// new file and the inbox stays small.
struct ClaudeInbox {
    let url: URL
    var rotateBytes: UInt64 = 256_000
    private(set) var offset: UInt64 = 0

    init(url: URL, rotateBytes: UInt64 = 256_000) {
        self.url = url
        self.rotateBytes = rotateBytes
    }

    var rotated: URL { url.appendingPathExtension("1") }

    mutating func read() -> [ClaudeHookEvent] {
        var events = Self.lines(of: url, from: &offset)
        guard offset >= rotateBytes else { return events }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: rotated)
        guard (try? fileManager.moveItem(at: url, to: rotated)) != nil else { return events }
        events += Self.lines(of: rotated, from: &offset)
        offset = 0
        return events
    }

    /// When the hooks last wrote, from the inbox or the file it was rotated to.
    static func lastWrite(at url: URL) -> Date? {
        [url, url.appendingPathExtension("1")].compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }

    private static func lines(of url: URL, from offset: inout UInt64) -> [ClaudeHookEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        if size < offset { offset = 0 }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let whole = data[data.startIndex...end]
        offset += UInt64(whole.count)
        return ClaudeHookEvent.parse(Substring(String(decoding: whole, as: UTF8.self)))
    }
}

/// A session as its hook events tell it: working from a prompt until it stops, ends, waits for the user or has been
/// quiet for `ClaudeSessions.workingTimeout` (an interrupted turn sends no Stop).
struct ClaudeSessionState: Equatable {
    let id: String
    var cwd: String
    var transcriptPath: String?
    var lastEvent: Date
    var lastPrompt: Date?
    var prompt: String?
    var working = false
    var ended = false
}

struct ClaudeSessions: Equatable {
    static let workingTimeout: TimeInterval = 600
    /// Ended and quiet sessions are forgotten after this long.
    static let keep: TimeInterval = 86_400

    private(set) var sessions: [String: ClaudeSessionState] = [:]
    private(set) var lastEvent: Date?

    var ids: Set<String> { Set(sessions.keys) }

    mutating func apply(_ events: [ClaudeHookEvent]) {
        events.forEach { apply($0) }
    }

    mutating func apply(_ event: ClaudeHookEvent) {
        lastEvent = max(lastEvent ?? event.time, event.time)
        var state = sessions[event.sessionID] ?? ClaudeSessionState(id: event.sessionID, cwd: event.cwd ?? "", lastEvent: event.time)
        if let cwd = event.cwd { state.cwd = cwd }
        if let path = event.transcriptPath { state.transcriptPath = path }
        state.lastEvent = max(state.lastEvent, event.time)
        state.ended = false
        switch event.kind {
        case .sessionStart:
            state.working = false
        case .prompt:
            state.working = true
            state.lastPrompt = event.time
            state.prompt = event.prompt
        case .tool, .subagentStop:
            state.working = true
        case .notification, .stop:
            state.working = false
        case .sessionEnd:
            state.working = false
            state.ended = true
        }
        sessions[event.sessionID] = state
    }

    func isWorking(_ state: ClaudeSessionState, now: Date) -> Bool {
        state.working && now.timeIntervalSince(state.lastEvent) < Self.workingTimeout
    }

    /// The sessions working now, and those the user prompted within `lookback`, so the one being typed into is found.
    func active(now: Date, lookback: TimeInterval) -> [(state: ClaudeSessionState, working: Bool)] {
        sessions.values.sorted { $0.id < $1.id }.compactMap { state in
            guard !state.ended else { return nil }
            let working = isWorking(state, now: now)
            let prompted = state.lastPrompt.map { now.timeIntervalSince($0) <= lookback } ?? false
            return working || prompted ? (state, working) : nil
        }
    }

    mutating func forget(before date: Date) {
        sessions = sessions.filter { $0.value.lastEvent >= date }
    }
}
