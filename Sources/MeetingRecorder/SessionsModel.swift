import AppKit
import SwiftUI

/// The transcript of one session as it is written, read a little at a time, with the messages sent to it that Claude has not written yet.
@MainActor
final class TranscriptFeed: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var pending: [PendingMessage] = []
    private(set) var url: URL?
    private var tail = TranscriptTail()
    private var serial = 0

    func setURL(_ url: URL?) {
        guard url != self.url else { return }
        self.url = url
        tail = TranscriptTail()
        entries = []
    }

    func refresh() {
        guard let url, let read = tail.read(url) else { return }
        if read.restarted { entries = [] }
        entries += read.lines.flatMap { line -> [TranscriptEntry] in
            serial += 1
            return SessionTranscript.entries(line: line, id: String(serial))
        }
        pending = SessionTranscript.reconcile(pending, with: entries)
    }

    func expect(_ text: String) {
        pending.append(PendingMessage(text: text.trimmingCharacters(in: .whitespacesAndNewlines), baseline: entries.count))
    }
}

/// The Sessions section: every Claude session the app knows, the transcripts of the selected one, and what is sent to it.
@MainActor
final class SessionsModel: ObservableObject {
    static let shared = SessionsModel()

    enum Tab: Equatable {
        case chat
        case terminal
    }

    @Published var selection: String?
    @Published var query = ""
    @Published var tab = Tab.chat
    /// Shows the Sessions section of the main window; set by the window.
    var reveal: (() -> Void)?
    /// Shows a pull request in the GitHub section; set by the window.
    var showGitHub: ((GitHubLink.Target) -> Void)?
    private var feeds: [String: TranscriptFeed] = [:]

    func feed(for key: String) -> TranscriptFeed {
        if let feed = feeds[key] { return feed }
        let feed = TranscriptFeed()
        feeds[key] = feed
        return feed
    }

    /// Every session the app knows, with its state at `now`: the terminals it runs, the saved ones and the review runs.
    func rows(now: Date) -> [SessionRow] {
        let saved = GitHubClaudeModel.shared.sessions
        let stored = saved.values.map { session in
            SessionRow(id: session.url, url: session.url, title: session.title ?? Self.label(session.url), kind: .saved, state: .done,
                       updated: session.updated, sessionID: session.id)
        }
        let reviews = GitHubClaudeModel.shared.reviews.values.map { review in
            SessionRow(id: SessionRow.reviewID(review.url), url: review.url, title: "\(review.preset.shortTitle) \u{00B7} \(Self.label(review.url))",
                       kind: .review, state: .done, updated: review.created, sessionID: nil)
        }
        return SessionList.merged(terminals: terminalRows(now: now, saved: saved), saved: stored) + reviews
    }

    private static func label(_ url: String) -> String { EmbeddedTerminal.pullRequestLabel(url) ?? url }

    #if canImport(SwiftTerm)
    private func terminalRows(now: Date, saved: [String: GitHubClaudeSession]) -> [SessionRow] {
        EmbeddedTerminalModel.shared.registry.sessions.values.map { session in
            let state = SessionStatus.derive(running: session.isRunning, ended: session.hasEnded, lastOutput: session.lastOutput, now: now,
                                             lastEntry: feeds[session.key]?.entries.last, screen: session.isRunning ? session.screenTail : "")
            return SessionRow(id: session.key, url: session.key, title: saved[session.key]?.title ?? session.title, kind: .terminal,
                              state: state, updated: session.lastOutput ?? (session.startedAt == .distantPast ? now : session.startedAt), sessionID: saved[session.key]?.id)
        }
    }

    /// Brings the feeds of the running sessions and the selected one up to date. Feeds of other sessions are dropped.
    func tick() {
        let running = EmbeddedTerminalModel.shared.registry.sessions.values.filter(\.isRunning).map(\.key)
        let keys = Set(running + [selection].compactMap { $0 })
        feeds = feeds.filter { keys.contains($0.key) }
        for key in keys {
            let feed = feed(for: key)
            feed.setURL(transcriptURL(key))
            feed.refresh()
        }
    }

    /// Writes the text to the session's terminal and shows it in the chat at once. Nothing is sent for empty text or a stopped session.
    @discardableResult
    func send(_ text: String, to key: String) -> Bool {
        guard SessionInput.submission(text) != nil, let session = EmbeddedTerminalModel.shared.session(for: key), session.submit(text) else { return false }
        feed(for: key).expect(text)
        return true
    }

    /// Answers a waiting prompt with y or n. The answer is not shown as a message: Claude does not write it as one.
    func answer(_ key: String, yes: Bool) {
        EmbeddedTerminalModel.shared.session(for: key)?.submit(SessionInput.answer(yes: yes))
    }

    func stop(_ key: String) { EmbeddedTerminalModel.shared.session(for: key)?.stop() }

    func restart(_ key: String) { EmbeddedTerminalModel.shared.session(for: key)?.restart() }

    /// The question Claude waits on in a running session; nil when none does.
    func question(for key: String) -> String? {
        guard let session = EmbeddedTerminalModel.shared.session(for: key), session.isRunning else { return nil }
        return WaitingPrompt.question(lastEntry: feeds[key]?.entries.last, screen: session.screenTail)
    }
    #else
    private func terminalRows(now: Date, saved: [String: GitHubClaudeSession]) -> [SessionRow] { [] }

    func tick() {}

    @discardableResult
    func send(_ text: String, to key: String) -> Bool { false }

    func answer(_ key: String, yes: Bool) {}

    func stop(_ key: String) {}

    func restart(_ key: String) {}

    func question(for key: String) -> String? { nil }
    #endif

    private func transcriptURL(_ key: String) -> URL? {
        GitHubClaudeModel.shared.sessions[key].flatMap { ClaudeTranscripts.transcript(id: $0.id, cwd: $0.cwd) }
    }

    /// The chat of a row: the review run's answer, or the transcript read so far.
    func entries(for row: SessionRow) -> [TranscriptEntry] {
        if row.kind == .review, let review = GitHubClaudeModel.shared.review(for: row.url) {
            return [TranscriptEntry(id: row.id, kind: .assistant, text: review.text)]
        }
        return feed(for: row.id).entries
    }

    /// Shows the session on the Sessions section.
    func show(_ key: String) {
        selection = key
        reveal?()
    }

    func openPullRequest(_ url: String) {
        guard let target = SessionList.pullRequest(url) else { return }
        showGitHub?(target)
    }

    /// Picks up the saved session of a pull request in the chosen destination.
    func resume(_ url: String) {
        let listed = GitHubModel.shared.prs.values.lazy.flatMap { $0 }.first { $0.url == url }
        guard let pr = listed ?? SessionList.pullRequest(url).map({ GitHubPR(url: $0.url, number: $0.number, title: "", repo: $0.repo, updated: .distantPast) })
        else { return }
        GitHubClaudeModel.shared.resumeInClaude(pr, GitHubModel.shared.page?.pr.url == url ? GitHubModel.shared.page?.detail : nil)
    }

    /// Forgets the saved session of a pull request and closes its finished terminal. A running one is not touched.
    func forget(_ url: String) {
        guard EmbeddedTerminalModel.shared.isRunning(url) == false else { return }
        EmbeddedTerminalModel.shared.close(url)
        GitHubClaudeModel.shared.forgetSession(url)
    }

    func transcriptText(for row: SessionRow) -> String {
        SessionTranscript.plainText(entries(for: row))
    }

    #if DEBUG
    /// Shows the given rows' selection and tab, for the previews.
    func showSample(selecting key: String?, tab: Tab) {
        selection = key
        self.tab = tab
    }
    #endif
}
