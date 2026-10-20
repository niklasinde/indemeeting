import AppKit
import SwiftUI

/// Starts Claude on a pull request: an interactive session in a terminal or the Claude app, or a headless, read-only review
/// run here, one at a time, whose answer is saved per pull request. Nothing starts without a click; nothing is written to GitHub.
@MainActor
final class GitHubClaudeModel: ObservableObject {
    static let shared = GitHubClaudeModel()
    static let enabledKey = "githubClaudeReviews"
    static let destinationKey = "githubClaudeDestination"
    static let presetKey = "githubClaudePreset"
    static let rememberKey = "githubClaudeRemember"
    static let modelKey = "githubClaudeModel"
    static let rememberSessionsKey = "githubClaudeRememberSessions"
    /// How long after a terminal starts its transcript is looked for, and how often.
    static let captureWindow: TimeInterval = 4 * 3600
    static let capturePoll: UInt64 = 2_000_000_000

    nonisolated static let repositoriesRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("git")

    struct Job: Equatable {
        let pr: GitHubPR
        let detail: GitHubPRDetail?
        let preset: GitHubClaude.Preset
    }

    struct Running: Equatable {
        let preset: GitHubClaude.Preset
        let started: Date
        var text = ""
        var status: String?
    }

    enum State: Equatable {
        case queued(GitHubClaude.Preset)
        case running(Running)
        case failed(GitHubClaude.Failure, GitHubClaude.Preset)
    }

    struct Note: Equatable {
        let text: String
        var copy: String?
    }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var live: [String: State] = [:]
    @Published private(set) var reviews: [String: GitHubReview] = [:]
    @Published private(set) var outdated: [String: Bool] = [:]
    /// The interactive session to resume per pull request, only while its transcript is still on this Mac.
    @Published private(set) var sessions: [String: GitHubClaudeSession] = [:]
    @Published private(set) var note: Note?
    @Published var confirming: Job?

    private var queue: [Job] = []
    private var process: ClaudeProcess?
    private var running: String?
    private var captures: [String: Task<Void, Never>] = [:]
    private let defaults = UserDefaults.standard
    private var store: MeetingStore? { GitHubModel.shared.store }

    var destination: GitHubClaude.Destination {
        get { GitHubClaude.Destination.stored(defaults.string(forKey: Self.destinationKey), isAvailable: isInstalled) }
        set { defaults.set(newValue.rawValue, forKey: Self.destinationKey); objectWillChange.send() }
    }

    var remember: Bool {
        get { defaults.object(forKey: Self.rememberKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.rememberKey); objectWillChange.send() }
    }

    var remembersSessions: Bool {
        get { defaults.object(forKey: Self.rememberSessionsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.rememberSessionsKey); objectWillChange.send() }
    }

    var modelName: String {
        get { defaults.string(forKey: Self.modelKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.modelKey); objectWillChange.send() }
    }

    /// What the main button does: the preset used last when the choice is remembered, otherwise the review.
    var primaryPreset: GitHubClaude.Preset {
        guard remember else { return .review }
        return defaults.string(forKey: Self.presetKey).flatMap(GitHubClaude.Preset.init(rawValue:)) ?? .review
    }

    var isRunning: Bool {
        guard let running, case .running = live[running] else { return false }
        return true
    }

    /// `repo #n` of the pull request being reviewed now.
    var runningLabel: String? {
        running.flatMap { url in
            let parts = GitHubLogic.address(url).split(separator: "/")
            return parts.count >= 5 ? "\(parts[2]) #\(parts[4])" : nil
        }
    }

    func installedDestinations() -> [GitHubClaude.Destination] {
        GitHubClaude.Destination.allCases.filter(isInstalled)
    }

    private func isInstalled(_ destination: GitHubClaude.Destination) -> Bool {
        if destination == .inApp { return EmbeddedTerminalModel.available }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: destination.bundleID) != nil
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        enabled = on
    }

    // MARK: Saved reviews

    func load() {
        reviews = Dictionary(((try? store?.githubReviews()) ?? []).map { ($0.url, $0) }) { $1 }
        outdated = (try? store?.githubReviewOutdated()) ?? [:]
        let saved = remembersSessions ? ((try? store?.githubSessions()) ?? []) : []
        sessions = Dictionary(saved.filter { $0.kind == .interactive && ClaudeTranscripts.exists(id: $0.id, cwd: $0.cwd) }.map { ($0.url, $0) }) { $1 }
    }

    func review(for url: String) -> GitHubReview? { reviews[url] }

    func isOutdated(_ url: String, head: String?) -> Bool {
        guard let review = reviews[url] else { return false }
        return GitHubClaude.isOutdated(reviewed: review.headSHA, current: head) || (head == nil && outdated[url] == true)
    }

    // MARK: Headless

    func ask(_ pr: GitHubPR, _ detail: GitHubPRDetail?, _ preset: GitHubClaude.Preset) {
        let job = Job(pr: pr, detail: detail, preset: preset)
        guard enabled else { confirming = job; return }
        switch live[pr.url] {
        case .queued, .running: return
        case .failed, nil: break
        }
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        live[pr.url] = .queued(preset)
        queue.append(job)
        startNext()
    }

    func confirmAllowing() {
        setEnabled(true)
        guard let job = confirming else { return }
        confirming = nil
        ask(job.pr, job.detail, job.preset)
    }

    func cancel(_ url: String) {
        if running == url { process?.cancel() } else {
            queue.removeAll { $0.pr.url == url }
            live[url] = nil
        }
    }

    func dismissFailure(_ url: String) {
        if case .failed = live[url] { live[url] = nil }
    }

    private func startNext() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let url = job.pr.url
        running = url
        let process = ClaudeProcess()
        self.process = process
        let started = Date()
        live[url] = .running(Running(preset: job.preset, started: started))
        Task {
            let finish = await self.execute(job, process: process, started: started)
            self.finish(job, finish, started: started)
        }
    }

    private enum Finish {
        case answer(String, cost: Double?, session: GitHubClaudeSession?)
        case cancelled
        case failed(GitHubClaude.Failure)
    }

    private func execute(_ job: Job, process: ClaudeProcess, started: Date) async -> Finish {
        guard let cli = ClaudePlugin.findCLI() else { return .failed(.cliMissing) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let repo = job.pr.repo
        let checkout = await Task.detached { GitHubClaude.checkout(for: repo, under: Self.repositoriesRoot) }.value
        let prompt = GitHubClaude.prompt(job.preset, context(job.pr, job.detail, hasCheckout: checkout != nil))
        let arguments = GitHubClaude.headlessArguments(prompt: prompt, model: modelName)
        let box = StreamBox()
        let url = job.pr.url
        let outcome = await process.run(cli: cli, arguments: arguments, directory: checkout ?? home, environment: ClaudePluginModel.environment(for: cli),
                                        timeout: GitHubClaude.timeLimit) { line in
            let snapshot = box.consume(line)
            Task { @MainActor in self.progress(url, snapshot) }
        }
        let stream = box.stream
        if outcome.cancelled { return .cancelled }
        if outcome.timedOut { return .failed(.timedOut) }
        let session = stream.sessionID.map {
            GitHubClaudeSession(url: url, id: $0, cwd: (checkout ?? home).path, kind: .review, preset: job.preset, title: nil, updated: Date())
        }
        if let result = stream.result, !result.isError, !result.text.isEmpty { return .answer(result.text, cost: result.cost, session: session) }
        if outcome.status == 0, !stream.text.isEmpty, stream.result?.isError != true {
            return .answer(stream.text, cost: stream.result?.cost, session: session)
        }
        return .failed(GitHubClaude.failure(stream.result?.text ?? outcome.stderr))
    }

    private func progress(_ url: String, _ snapshot: (text: String, status: String?)) {
        guard case .running(var running)? = live[url] else { return }
        running.text = snapshot.text
        running.status = snapshot.status
        live[url] = .running(running)
    }

    private func finish(_ job: Job, _ finish: Finish, started: Date) {
        let url = job.pr.url
        switch finish {
        case .cancelled: live[url] = nil
        case .failed(let failure): live[url] = .failed(failure, job.preset)
        case .answer(let text, let cost, let session):
            let review = GitHubReview(url: url, headSHA: job.detail?.headOid, preset: job.preset, text: text, created: Date(),
                                      duration: Date().timeIntervalSince(started), cost: cost)
            try? store?.saveGitHubReview(review)
            reviews[url] = review
            outdated[url] = false
            live[url] = nil
            if let session { remember(session) }
        }
        process = nil
        running = nil
        startNext()
    }

    // MARK: Interactive

    func openInClaude(_ pr: GitHubPR, _ detail: GitHubPRDetail?, _ preset: GitHubClaude.Preset) {
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        startInteractive(pr, detail, preset, resuming: false)
    }

    /// Picks up the pull request's saved session where it was; starts a new one with the usual preset when there is none to pick up.
    func resumeInClaude(_ pr: GitHubPR, _ detail: GitHubPRDetail?) {
        startInteractive(pr, detail, primaryPreset, resuming: true)
    }

    private func startInteractive(_ pr: GitHubPR, _ detail: GitHubPRDetail?, _ preset: GitHubClaude.Preset, resuming: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let checkout = GitHubClaude.checkout(for: pr.repo, under: Self.repositoriesRoot)
        let prompt = GitHubClaude.prompt(preset, context(pr, detail, hasCheckout: checkout != nil))
        var note = checkout == nil ? Note(text: "No local checkout of \(pr.repo) found, so Claude starts in your home folder and reads it with gh.",
                                           copy: GitHubClaude.cloneCommand(pr.repo)) : nil
        let saved = resuming && destination != .claudeApp ? sessions[pr.url] : nil
        let decision = GitHubClaude.resumption(running: destination == .inApp && EmbeddedTerminalModel.shared.runningSince(pr.url) != nil,
                                               storedID: resuming ? saved?.id : nil,
                                               transcriptExists: saved.map { ClaudeTranscripts.exists(id: $0.id, cwd: $0.cwd) } ?? false)
        var folder = checkout ?? home
        var resume: GitHubClaude.Resume?
        switch decision {
        case .reattach, .startNew(forget: false): break
        case .resume(let id):
            resume = GitHubClaude.Resume(id: id, title: saved?.title)
            if var refreshed = saved {
                folder = URL(fileURLWithPath: refreshed.cwd)
                refreshed.updated = Date()
                remember(refreshed)
            }
        case .startNew(forget: true):
            forgetSession(pr.url)
            note = Note(text: "The saved Claude session is no longer on this Mac, so a new one starts.")
        }
        let started = Date()
        if destination == .inApp {
            openEmbedded(pr, preset, folder: folder, prompt: prompt, hint: note, resume: resume)
            watchSession(pr.url, folder: folder, preset: preset) { EmbeddedTerminalModel.shared.runningSince(pr.url) }
        } else {
            let verb = resume == nil ? "Started" : "Resumed"
            show(start(prompt, checkout: folder, resume: resume) ?? note ?? Note(text: "\(verb) Claude in \(destination.title)."))
            watchSession(pr.url, folder: folder, preset: preset) { started }
        }
    }

    private func openEmbedded(_ pr: GitHubPR, _ preset: GitHubClaude.Preset, folder: URL, prompt: String, hint: Note?, resume: GitHubClaude.Resume?) {
        let name = GitHubLogic.repoName(pr.repo).name
        EmbeddedTerminalModel.shared.open(pr.url, title: "\(preset.shortTitle) \u{00B7} \(name) #\(pr.number)", directory: folder,
                                          prompt: prompt, cli: ClaudePlugin.findCLI(), hint: hint, preset: preset, resume: resume)
    }

    /// Starts Claude again in the same folder without the saved session, as the pane's "Start new session instead" does.
    func startNewSession(_ url: String, folder: URL, preset: GitHubClaude.Preset?) {
        EmbeddedTerminalModel.shared.startNew(url)
        watchSession(url, folder: folder, preset: preset) { EmbeddedTerminalModel.shared.runningSince(url) }
    }

    // MARK: Session ids

    /// Finds the session a terminal produces: the newest transcript in its folder created since it started that mentions the
    /// pull request, polled while the terminal runs (or for the capture window, for a terminal app it cannot see).
    private func watchSession(_ url: String, folder: URL, preset: GitHubClaude.Preset?, since probe: @escaping @MainActor () -> Date?) {
        guard remembersSessions else { return }
        captures[url]?.cancel()
        captures[url] = Task {
            while let started = probe(), Date() < started.addingTimeInterval(Self.captureWindow) {
                let id = await Task.detached { ClaudeTranscripts.newestSession(in: folder, since: started, containing: url) }.value
                if let id {
                    let title = await Task.detached { ClaudeTranscripts.title(in: folder, id: id) }.value
                    remember(GitHubClaudeSession(url: url, id: id, cwd: folder.path, kind: .interactive, preset: preset, title: title, updated: Date()))
                    break
                }
                try? await Task.sleep(nanoseconds: Self.capturePoll)
            }
            captures[url] = nil
        }
    }

    private func remember(_ session: GitHubClaudeSession) {
        guard remembersSessions else { return }
        try? store?.saveGitHubSession(session)
        if session.kind == .interactive { sessions[session.url] = session }
    }

    func forgetSession(_ url: String) {
        try? store?.forgetGitHubSessions(url)
        sessions[url] = nil
    }

    func forgetAllSessions() {
        try? store?.forgetGitHubSessions()
        sessions = [:]
    }

    /// The saved session that the chosen destination can pick up; the Claude app cannot resume one.
    func resumable(_ url: String) -> GitHubClaudeSession? { destination == .claudeApp ? nil : sessions[url] }

    /// A Claude session about a meeting, through the MCP tools of the MeetingRecorder plugin. Returns what went wrong, if anything.
    func openInClaude(_ meeting: Meeting, title: String) -> String? {
        start(GitHubClaude.meetingPrompt(id: meeting.id, title: title, date: meeting.created), checkout: nil)?.text
    }

    /// Opens the prompt in the chosen destination; the note says what went wrong or what the user still has to do.
    private func start(_ prompt: String, checkout: URL?, resume: GitHubClaude.Resume? = nil) -> Note? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let destination = destination == .inApp ? .terminal : destination
        switch GitHubClaude.plan(destination, cli: ClaudePlugin.findCLI(), checkout: checkout, home: home, prompt: prompt, isInstalled: isInstalled) {
        case .cliMissing:
            return Note(text: "The Claude CLI was not found. Install it with npm install -g @anthropic-ai/claude-code.",
                        copy: "npm install -g @anthropic-ai/claude-code")
        case .terminal(let terminal, let directory, let cli):
            do {
                let script = try GitHubClaude.writeLaunchFiles(prompt: resume == nil ? prompt : nil, directory: directory, cli: cli,
                                                               flags: resume?.flags ?? [], folder: GitHubClaude.promptFolder())
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleID) else { return Note(text: "\(terminal.title) was not found.") }
                NSWorkspace.shared.open([script], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return nil
            } catch {
                return Note(text: "Could not start Claude: \(error.localizedDescription)")
            }
        case .embedded:
            return nil
        case .appLink(let link):
            NSWorkspace.shared.open(link)
            return Note(text: "Opened a new session in the Claude app.")
        case .copyAndOpenApp:
            GitHubModel.copy(prompt)
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: GitHubClaude.Destination.claudeApp.bundleID)
                .map { NSWorkspace.shared.openApplication(at: $0, configuration: NSWorkspace.OpenConfiguration()) }
            return Note(text: "Prompt copied. Paste it in a new chat.")
        }
    }

    func dismissNote() { note = nil }

    private func show(_ note: Note) {
        self.note = note
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if self.note == note { self.note = nil }
        }
    }

    private func context(_ pr: GitHubPR, _ detail: GitHubPRDetail?, hasCheckout: Bool) -> GitHubClaude.Context {
        GitHubClaude.Context(url: pr.url, repo: pr.repo, number: pr.number, title: detail?.title ?? pr.title, base: detail?.base ?? "",
                             head: detail?.head ?? "", ticket: detail?.ticket ?? pr.ticket, hasCheckout: hasCheckout)
    }

    #if DEBUG
    func showSample(live: [String: State] = [:], reviews: [String: GitHubReview] = [:], outdated: [String: Bool] = [:], enabled: Bool = true) {
        self.live = live
        self.reviews = reviews
        self.outdated = outdated
        self.enabled = enabled
    }
    #endif
}

/// The stream parser shared between the process's reader thread and the main actor.
private final class StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = GitHubClaude.Stream()

    var stream: GitHubClaude.Stream {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func consume(_ line: String) -> (text: String, status: String?) {
        lock.lock()
        defer { lock.unlock() }
        current.consume(line)
        return (current.text, current.status)
    }
}
