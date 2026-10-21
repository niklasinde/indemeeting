import Foundation

/// What a session shows about itself: Claude is writing, it asks for you, or it is done or has ended.
enum SessionState: Equatable {
    case working
    case waiting
    case done
    case ended

    var title: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .done: return "Done"
        case .ended: return "Ended"
        }
    }
}

enum SessionStatus {
    /// Ended wins; a session that is not running is done; a running one is working while it wrote in the last few seconds, waiting when
    /// its last line asks something, and done otherwise.
    static func derive(running: Bool, ended: Bool, lastOutput: Date?, now: Date, lastEntry: TranscriptEntry?, screen: String) -> SessionState {
        if ended { return .ended }
        guard running else { return .done }
        if EmbeddedTerminal.activity(running: running, ended: ended, lastOutput: lastOutput, now: now) == .working { return .working }
        return WaitingPrompt.question(lastEntry: lastEntry, screen: screen) == nil ? .done : .waiting
    }
}

enum WaitingPrompt {
    static let screenLines = 8
    static let screenPrompts = ["Do you want", "Would you like", "(y/n)", "[y/N]", "[Y/n]"]

    /// The question Claude waits on, verbatim: a permission prompt on the screen, else the last line of Claude's message when it asks
    /// something. Nil when nothing waits for the person.
    static func question(lastEntry: TranscriptEntry?, screen: String) -> String? {
        if let line = screenPrompt(screen) { return line }
        guard let entry = lastEntry, entry.kind == .assistant, let last = lastLine(entry.text), isQuestion(last) else { return nil }
        return last
    }

    static func isQuestion(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`\"")).lowercased()
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasSuffix("?") || trimmed.contains("(y/n)") || trimmed.contains("[y/n]")
    }

    private static func screenPrompt(_ screen: String) -> String? {
        let lines = screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(screenLines).last { line in screenPrompts.contains { line.contains($0) } }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2502} ")) }
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

enum SessionGroup: Int, CaseIterable, Identifiable {
    case running
    case waiting
    case saved
    case done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting for you"
        case .saved: return "Saved"
        case .done: return "Done"
        }
    }
}

/// A row of the Sessions list: a Claude session on a pull request, a saved one that can be resumed, or a review run.
struct SessionRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case terminal
        case saved
        case review
    }

    /// The pull request's address for a terminal or a saved session; `review:` and the address for a review run.
    let id: String
    let url: String
    let title: String
    let kind: Kind
    let state: SessionState
    let updated: Date
    let sessionID: String?

    static func reviewID(_ url: String) -> String { "review:" + url }

    var prLabel: String? { EmbeddedTerminal.pullRequestLabel(url) }

    var group: SessionGroup {
        switch kind {
        case .terminal where state == .waiting: return .waiting
        case .terminal where state != .ended: return .running
        case .saved: return .saved
        case .terminal, .review: return .done
        }
    }
}

enum SessionList {
    struct Section: Identifiable {
        let group: SessionGroup
        let rows: [SessionRow]

        var id: Int { group.rawValue }
    }

    /// The rows of each group in order, empty groups left out, newest first within a group.
    static func grouped(_ rows: [SessionRow]) -> [Section] {
        SessionGroup.allCases.compactMap { group in
            let members = rows.filter { $0.group == group }.sorted { $0.updated > $1.updated }
            return members.isEmpty ? nil : Section(group: group, rows: members)
        }
    }

    /// The rows whose title, pull request, address or state contain every word of the query, ignoring case.
    static func matching(_ rows: [SessionRow], query: String) -> [SessionRow] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let haystack = [row.title, row.prLabel ?? "No PR", row.url, row.state.title].joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    /// One terminal or saved session per pull request, the terminal winning; review runs are listed beside them.
    static func merged(terminals: [SessionRow], saved: [SessionRow]) -> [SessionRow] {
        let live = Set(terminals.map(\.url))
        return terminals + saved.filter { !live.contains($0.url) }
    }

    /// The sessions of one pull request, its review run included.
    static func sessions(for url: String, in rows: [SessionRow]) -> [SessionRow] {
        rows.filter { $0.url == url }
    }

    /// The pull request a chip names: its address through the same link the `meetingrecorder://` links use.
    static func pullRequest(_ url: String) -> GitHubLink.Target? {
        GitHubLink.parse(GitHubLink.appLink(for: url))
    }
}

enum SessionInput {
    static let paste = (start: "\u{1B}[200~", end: "\u{1B}[201~")

    /// What a send writes to the terminal: the text followed by Return. Several lines go as one bracketed paste, so the CLI keeps them as
    /// one message. Nil for empty input, which is never sent.
    static func submission(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("\n") { return paste.start + trimmed + paste.end + "\r" }
        return trimmed + "\r"
    }

    /// The answer to a waiting prompt: `y` or `n`, sent like any other line.
    static func answer(yes: Bool) -> String { yes ? "y" : "n" }
}
