import AppKit
import Combine
import SwiftUI

/// The agent sidecar: `node agent/dist/main.js`, spoken to in JSON lines over stdin and stdout.
final class AgentClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()

    init(node: URL, script: URL, environment: [String: String], onLine: @escaping @Sendable (String) -> Void,
         onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        process.executableURL = node
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.environment = environment
        process.standardInput = input
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let lines = LineBuffer(), errorText = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            lines.append(data).forEach(onLine)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            errorText.collect(data)
        }
        process.terminationHandler = { ended in onExit(ended.terminationStatus, String(errorText.all().suffix(2000))) }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func send(_ request: AgentRequest) {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data(request.line.utf8))
    }

    func terminate() {
        guard process.isRunning else { return }
        ClaudeProcess.terminateTree(process.processIdentifier)
    }
}

/// The Agent window: the transcript, the folder it works in and the session it continues.
@MainActor
final class AgentModel: ObservableObject {
    @Published private(set) var items: [AgentItem] = [] {
        didSet { touch() }
    }
    @Published private(set) var busy = false {
        didSet { touch() }
    }
    @Published private(set) var sessionID: String? {
        didSet {
            if let agentKey, let sessionID { Self.savedSessions[agentKey] = sessionID }
            if isMain, prURL == nil { Self.defaults.set(sessionID, forKey: AgentLogic.mainSessionKey) }
            if let sessionID, oldValue != sessionID { remember(sessionID) }
            touch()
        }
    }
    /// This agent's earlier sessions, newest first; New Session keeps the current one here.
    @Published private(set) var history: [AgentSessionEntry] = []
    private var restoring: String?
    @Published private(set) var prURL: String?
    /// The topic this agent is for, when it is a topic agent.
    @Published private(set) var topic: TopicAgent?
    /// Whether the user has seen the latest reply: false when a turn ends while no pane shows this agent.
    @Published private(set) var resultSeen = true {
        didSet { if oldValue != resultSeen { touch() } }
    }
    /// Prompts from Main waiting for the current turn to end.
    @Published private(set) var queued: [String] = []
    private(set) var updated: Date?
    private var visiblePanes = 0
    /// The overview session of the Agent window, kept across launches.
    let isMain: Bool
    @Published var model = AgentLogic.storedModel(AgentModel.defaults.string(forKey: AgentLogic.modelKey)) {
        didSet { Self.defaults.set(model, forKey: AgentLogic.modelKey) }
    }
    /// How this agent's calls are approved, saved per agent; a change reaches a turn already running too.
    @Published var permissionMode = AgentPermissionMode.ask {
        didSet {
            guard oldValue != permissionMode else { return }
            var modes = Self.defaults.dictionary(forKey: AgentPermissionMode.storageKey) ?? [:]
            modes[historyKey] = permissionMode == .ask ? nil : permissionMode.rawValue
            Self.defaults.set(modes, forKey: AgentPermissionMode.storageKey)
            if busy { client?.send(.mode(permissionMode)) }
        }
    }
    /// Whether this agent's sessions get the Claude in Chrome tools, saved per agent; the next prompt starts with the change.
    @Published var chrome = false {
        didSet {
            guard oldValue != chrome else { return }
            var enabled = Self.defaults.dictionary(forKey: AgentLogic.chromeKey) ?? [:]
            enabled[historyKey] = chrome ? true : nil
            Self.defaults.set(enabled, forKey: AgentLogic.chromeKey)
            if !chrome { chromeProblem = nil }
        }
    }
    /// Why the Chrome tools failed last, usually the extension not being connected; cleared when one works.
    @Published private(set) var chromeProblem: String?
    /// Bumped when the transcript is replaced rather than added to: another session, a restored one, a new one.
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var problem: String?
    @Published private(set) var files: [String] = []
    @Published var folder: String
    /// Starting a prompt on Auto loads Ministral, so it is ready to route the prompt once it is sent.
    @Published var draft = "" {
        didSet { if oldValue.isEmpty, !draft.isEmpty, model == AgentLogic.auto, !OllamaSummarizer.isForced() { LocalLLM.shared.prepare() } }
    }

    /// Beside a pull request: shows a referenced file in the pull request's diff, false when it is not one of its files.
    var reveal: ((String) -> Bool)?
    private var client: AgentClient?
    private var routing: Task<Void, Never>?
    private var lastModel: String?
    private var turnIsAuto = false
    private var rulesChanged: AnyCancellable?

    /// Replaced by the debug preview, so it never writes the app's own settings.
    static var defaults = UserDefaults.standard

    init(folder: String? = nil, main: Bool = false) {
        isMain = main
        let defaults = Self.defaults
        self.folder = folder ?? (main ? defaults.string(forKey: AgentLogic.mainFolderKey) ?? GitHubClaudeModel.repositoriesRoot.path
                                      : defaults.string(forKey: AgentLogic.folderKey) ?? NSHomeDirectory())
        history = AgentSessionStore.list(for: historyKey)
        loadMode()
        rulesChanged = AgentRuleStore.shared.$rules.dropFirst().sink { [weak self] in self?.client?.send(.rules($0)) }
        if main, let session = defaults.string(forKey: AgentLogic.mainSessionKey) {
            sessionID = session
            remember(session)
            restore()
        }
    }

    /// The pull request url or topic key the agent is saved under; nil for Main and a plain folder.
    var agentKey: String? { prURL ?? topic?.key }

    var historyKey: String { AgentSessions.key(agent: agentKey, isMain: isMain, folder: folder) }

    var waitingForPermission: Bool {
        busy && items.contains { if case .permission(_, _, _, _, nil) = $0.kind { true } else { false } }
    }

    private func touch() {
        updated = Date()
        AgentStateWriter.shared.changed()
    }

    /// A pane showing this agent appeared or went away; showing it counts as seeing its latest reply.
    func setVisible(_ visible: Bool) {
        visiblePanes = max(visiblePanes + (visible ? 1 : -1), 0)
        if visiblePanes > 0 { resultSeen = true }
    }

    var mentionMatches: [String] {
        AgentLogic.mentionQuery(draft).map { AgentLogic.fuzzyMatches($0, in: files) } ?? []
    }

    func preview(_ items: [AgentItem], files: [String] = [], busy: Bool = false, seen: Bool = true, chromeProblem: String? = nil) {
        restoring = nil
        self.chromeProblem = chromeProblem
        replaceItems(items)
        self.files = files
        self.busy = busy
        resultSeen = seen
    }

    func choose(folder: String) {
        guard folder != self.folder else { return }
        prURL = nil
        topic = nil
        self.folder = folder
        Self.defaults.set(folder, forKey: isMain ? AgentLogic.mainFolderKey : AgentLogic.folderKey)
        newSession()
        loadMode()
        loadFiles()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { choose(folder: url.path) }
    }

    /// Starts afresh; the session so far stays in the history, so it can be picked again.
    func newSession() {
        if busy { stop() }
        if let agentKey { Self.savedSessions[agentKey] = nil }
        sessionID = nil
        lastModel = nil
        restoring = nil
        replaceItems([])
        queued = []
        problem = nil
    }

    private func replaceItems(_ new: [AgentItem]) {
        items = new
        transcriptRevision += 1
    }

    /// Continues an earlier session: its folder, and its transcript read back from Claude Code's file.
    func switchTo(_ entry: AgentSessionEntry) {
        guard !busy, entry.id != sessionID else { return }
        history = AgentSessionStore.update(historyKey) { AgentSessions.record(entry, in: $0) }
        if entry.folder != folder {
            folder = entry.folder
            if isMain, prURL == nil { Self.defaults.set(folder, forKey: AgentLogic.mainFolderKey) }
            loadFiles()
        }
        lastModel = nil
        queued = []
        problem = nil
        sessionID = entry.id
        restore()
    }

    func forget(_ id: String) {
        guard id != sessionID else { return }
        history = AgentSessionStore.update(historyKey) { AgentSessions.removing(id, from: $0) }
    }

    /// Sessions in this agent's folder that its list does not have, for picking one Claude Code or another agent started.
    func otherSessions() async -> [AgentSessionEntry] {
        let folder = folder, known = Set(history.map(\.id)).union([sessionID].compactMap { $0 })
        return await Task.detached { AgentSessionStore.others(in: folder, excluding: known) }.value
    }

    private func remember(_ id: String) {
        guard !history.contains(where: { $0.id == id }) else { return }
        let prompt = items.lazy.compactMap { if case .user(let text) = $0.kind { text } else { nil } }.first
        let now = Date()
        let entry = AgentSessionEntry(id: id, folder: folder, created: now, lastUsed: now,
                                      title: prompt.map(AgentSessions.title(prompt:)) ?? AgentSessions.untitled, model: lastModel)
        history = AgentSessionStore.update(historyKey) { AgentSessions.record(entry, in: $0) }
    }

    /// Reads the current session's transcript back; work started meanwhile wins over it.
    private func restore() {
        guard let id = sessionID else { return }
        restoring = id
        replaceItems([AgentItem(id: "status-0", kind: .status("Loading the earlier session\u{2026}"))])
        let folder = folder
        Task.detached {
            let text = AgentTranscript.url(sessionID: id, cwd: folder).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let restored = text.map { AgentSessions.restored(AgentTranscript.items(jsonl: $0, cwd: folder)) }
            let title = text.flatMap { ActivityLogic.claudeSession(id: id, jsonl: $0, titleLimit: AgentSessions.titleLimit)?.title }
            await MainActor.run { [weak self] in self?.restored(id, items: restored, title: title) }
        }
    }

    private func restored(_ id: String, items restored: [AgentItem]?, title: String?) {
        guard restoring == id, sessionID == id, !busy else { return }
        restoring = nil
        replaceItems(restored.flatMap { $0.isEmpty ? nil : $0 }
            ?? [AgentItem(id: "status-0", kind: .status("Continuing the earlier session; its transcript was not found"))])
        updated = history.first { $0.id == id }?.lastUsed ?? updated
        guard let title, history.first(where: { $0.id == id })?.title == AgentSessions.untitled else { return }
        history = AgentSessionStore.update(historyKey) { list in
            list.map { entry in
                var entry = entry
                if entry.id == id { entry.title = title }
                return entry
            }
        }
    }

    /// Points the window at a pull request: its checkout (or the home folder), the session it had before, and a review
    /// prompt waiting to be sent when there is no session yet. Opening the one already shown changes nothing.
    func open(pr target: GitHubLink.Target, checkout: URL?) {
        guard prURL != target.url || (items.isEmpty && !busy) else { return }
        point(prURL: target.url, topic: nil, folder: checkout?.path ?? NSHomeDirectory())
        draft = sessionID == nil ? AgentLogic.reviewPrompt(url: target.url, repo: target.repo, hasCheckout: checkout != nil) : ""
    }

    /// Points the agent at a topic: its folder, the session it had before, and the prompt for its ticket or thread waiting
    /// when there is no session yet. A renamed topic only updates the name.
    func open(topic: TopicAgent) {
        guard self.topic?.id != topic.id || (items.isEmpty && !busy) else { return self.topic = topic }
        point(prURL: nil, topic: topic, folder: topic.folder)
        draft = sessionID == nil ? TopicAgents.prompt(topic) : ""
    }

    private func point(prURL: String?, topic: TopicAgent?, folder: String) {
        if busy { stop() }
        self.prURL = prURL
        self.topic = topic
        self.folder = folder
        lastModel = nil
        problem = nil
        history = AgentSessionStore.list(for: historyKey)
        restoring = nil
        replaceItems([])
        sessionID = agentKey.flatMap { Self.savedSessions[$0] }
        restore()
        loadMode()
        loadFiles()
    }

    private func loadMode() {
        permissionMode = AgentPermissionMode.stored(Self.defaults.dictionary(forKey: AgentPermissionMode.storageKey), key: historyKey)
        chrome = AgentLogic.chromeEnabled(Self.defaults.dictionary(forKey: AgentLogic.chromeKey), key: historyKey)
        chromeProblem = nil
    }

    /// The current session of each pull request's and topic's agent, by its key.
    static var savedSessions: [String: String] {
        get { defaults.dictionary(forKey: AgentLogic.prSessionsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: AgentLogic.prSessionsKey) }
    }

    /// Return in the prompt: picks the first file while an `@` mention is being typed, sends otherwise.
    func submit() {
        if let first = mentionMatches.first {
            draft = AgentLogic.insertMention(first, into: draft)
        } else {
            send()
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, restoring == nil else { return }
        if start(text) { draft = "" }
    }

    func catchUp() {
        guard !busy else { return }
        _ = start(AgentLogic.catchUpPrompt)
    }

    /// A prompt from Main: started now or after the current turn, or refused while a permission prompt waits.
    func deliver(fromMain text: String) -> AgentInbox.Decision {
        let decision = AgentInbox.decide(busy: busy || routing != nil, waitingForPermission: waitingForPermission, queued: queued.count)
        switch decision {
        case .start:
            if !start(AgentInbox.prompt(text)) { return .reject(problem ?? "The agent could not start.") }
        case .queue: queued.append(AgentInbox.prompt(text))
        case .reject: break
        }
        return decision
    }

    @discardableResult
    private func start(_ text: String) -> Bool {
        guard let client = runningClient() else { return false }
        problem = nil
        items.append(AgentItem(id: "user-\(items.count)", kind: .user(text)))
        let prompt = AgentLogic.expandMentions(text, cwd: folder) { FileManager.default.fileExists(atPath: $0) }
        busy = true
        let auto = model == AgentLogic.auto, chosen = model, previous = lastModel, cwd = folder
        let signals = AgentLogic.RouteSignals(mentions: AgentLogic.mentions(in: text).count, isReview: prURL != nil,
                                              turns: items.filter { if case .user = $0.kind { true } else { false } }.count - 1)
        routing = Task { @MainActor [weak self] in
            let picked = auto ? await AgentLogic.route(prompt: text, signals: signals, previous: previous, ask: Self.classify) : chosen
            guard let self, !Task.isCancelled else { return }
            routing = nil
            lastModel = picked
            turnIsAuto = auto
            client.send(.prompt(text: prompt, cwd: cwd, sessionID: sessionID, model: picked,
                                appendSystemPrompt: isMain && prURL == nil ? AgentLogic.mainSystemPrompt : topic.map(TopicAgents.systemPrompt),
                                mode: permissionMode, chrome: chrome))
        }
        return true
    }

    /// The built-in model, or Ollama when testing with it; Auto runs on Sonnet when neither answers.
    @Sendable nonisolated static func classify(system: String, user: String) async throws -> String {
        if !OllamaSummarizer.isForced(), LocalLLM.isAvailable {
            return try await LocalLLM.shared.generate(system: system, prompt: user, schema: AgentLogic.routeSchema, maxTokens: 32,
                                                      temperature: 0, urgent: true).text
        }
        guard OllamaSummarizer.isAllowed() else { throw LocalLLMError.notInstalled }
        return try await OllamaSummarizer.chat(system: system, prompt: user, schema: AgentLogic.routeSchema, temperature: 0,
                                               keepAlive: "10m", timeout: AgentLogic.routeTimeout)
    }

    /// `always` first saves the rules the card offers, so this and later calls of every agent that match them run without asking.
    func answer(_ item: AgentItem, allow: Bool, always: Bool = false) {
        guard let id = AgentLogic.permissionID(of: item.id) else { return }
        if always, case .permission(_, _, _, let offer, nil) = item.kind { AgentRuleStore.shared.add(offer) }
        AgentLogic.answer(item.id, allow: allow, in: &items)
        client?.send(.permission(id: id, allow: allow))
    }

    func stop() {
        if let routing {
            routing.cancel()
            self.routing = nil
            busy = false
            return
        }
        client?.send(.interrupt)
    }

    func stopClient() {
        client?.terminate()
        client = nil
        busy = false
    }

    func loadFiles() {
        let folder = folder
        Task.detached {
            let files = AgentFiles.list(in: folder)
            await MainActor.run { [weak self] in if self?.folder == folder { self?.files = files } }
        }
    }

    /// Opens a pull request page with its agent; the app delegate sets it, the same as for `worktime://agent` links from outside.
    static var openAgentLink: ((GitHubLink.Target) -> Void)?

    func open(_ url: URL) -> OpenURLAction.Result {
        if let target = GitHubLink.parseAgent(url.absoluteString), let open = Self.openAgentLink {
            open(target)
            return .handled
        }
        guard let target = AgentLogic.codeTarget(url) else { return .systemAction }
        if reveal?(AgentLogic.relative(target.path, to: folder)) == true { return .handled }
        AgentFiles.open(path: target.path, line: target.line)
        return .handled
    }

    private func runningClient() -> AgentClient? {
        if let client, client.isRunning { return client }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let nvm = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".nvm/versions/node").path)) ?? []
        guard let node = AgentLogic.nodeCandidates(path: environment["PATH"], home: home, nvmVersions: nvm)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            problem = "Node.js was not found. Install it (brew install node) so the agent can run."
            return nil
        }
        guard let script = AgentLogic.sidecarCandidates(environment: environment, resources: Bundle.main.resourceURL, sourceFile: #filePath)
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            problem = "The agent sidecar is not built. Run `npm ci && npm run build` in the agent folder of the WorkTime checkout."
            return nil
        }
        let childEnvironment = AgentLogic.childEnvironment(environment, nodeFolder: node.deletingLastPathComponent().path,
                                                           mcpCommand: Bundle.main.executablePath)
        do {
            let client = try AgentClient(node: node, script: script, environment: childEnvironment, onLine: { [weak self] line in
                Task { @MainActor [weak self] in self?.receive(line) }
            }, onExit: { [weak self] status, errors in
                Task { @MainActor [weak self] in self?.exited(status: status, errors: SecretRedaction.redact(errors, key: nil)) }
            })
            self.client = client
            client.send(.rules(AgentRuleStore.shared.rules))
            return client
        } catch {
            problem = "The agent could not start: \(error.localizedDescription)"
            return nil
        }
    }

    private func receive(_ line: String) {
        guard let event = AgentEvent.decode(line, cwd: folder) else { return }
        if case .chrome(let problem) = event { return chromeProblem = chrome ? problem : nil }
        if let session = AgentLogic.apply(event, to: &items, auto: turnIsAuto) { sessionID = session }
        if case .idle = event { finishTurn() }
    }

    private func finishTurn() {
        busy = false
        if let sessionID { history = AgentSessionStore.update(historyKey) { AgentSessions.touch(sessionID, at: Date(), model: lastModel, in: $0) } }
        resultSeen = visiblePanes > 0
        if !queued.isEmpty { start(queued.removeFirst()) }
    }

    private func exited(status: Int32, errors: String) {
        client = nil
        guard busy else { return }
        busy = false
        resultSeen = visiblePanes > 0
        if AgentLogic.needsSignIn(errors) { return AgentLogic.appendSignIn(to: &items) }
        let tail = errors.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        items.append(AgentItem(id: "error-\(items.count)", kind: .error("The agent stopped (exit \(status)). \(tail)")))
    }
}

/// The calls the user always allows, shared by every agent and sent to each sidecar when it starts and when they change.
@MainActor
final class AgentRuleStore: ObservableObject {
    static let shared = AgentRuleStore()

    @Published private(set) var rules = AgentRules.decode(AgentModel.defaults.data(forKey: AgentRules.key)) {
        didSet { AgentModel.defaults.set(AgentRules.encode(rules), forKey: AgentRules.key) }
    }

    func add(_ new: [AgentRule]) {
        let added = AgentRules.adding(new, to: rules)
        if added != rules { rules = added }
    }

    func remove(_ rule: AgentRule) { rules.removeAll { $0 == rule } }

    func removeAll() { rules = [] }
}

/// The session history of every agent, in the app's settings.
@MainActor
enum AgentSessionStore {
    static func all() -> [String: [AgentSessionEntry]] {
        AgentSessions.decode(AgentModel.defaults.data(forKey: AgentSessions.historyKey))
    }

    static func list(for key: String) -> [AgentSessionEntry] { all()[key] ?? [] }

    static func update(_ key: String, _ change: ([AgentSessionEntry]) -> [AgentSessionEntry]) -> [AgentSessionEntry] {
        var history = all()
        let list = change(history[key] ?? [])
        history[key] = list.isEmpty ? nil : list
        AgentModel.defaults.set(AgentSessions.encode(history), forKey: AgentSessions.historyKey)
        return list
    }

    nonisolated static func others(in folder: String, excluding known: Set<String>, fileManager: FileManager = .default) -> [AgentSessionEntry] {
        let directory = ClaudeTranscripts.folder(cwd: folder)
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let files = urls.filter { $0.pathExtension == "jsonl" }.map { url in
            (id: url.deletingPathExtension().lastPathComponent,
             modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        return AgentSessions.others(files, excluding: known).map { file in
            AgentSessionEntry(id: file.id, folder: folder, created: file.modified, lastUsed: file.modified,
                              title: ClaudeTranscripts.title(in: directory, id: file.id).map { ActivityLogic.truncate($0, to: AgentSessions.titleLimit) }
                                  ?? AgentSessions.untitled, model: nil)
        }
    }
}

/// Listing the folder's files for `@` mentions and opening references in an editor.
enum AgentFiles {
    static let limit = 20_000

    static func list(in folder: String) -> [String] {
        if let tracked = run("/usr/bin/git", ["ls-files", "-co", "--exclude-standard"], in: folder) {
            return Array(tracked.split(separator: "\n").map(String.init).prefix(limit))
        }
        let base = URL(fileURLWithPath: folder)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [String] = []
        for case let url as URL in walker {
            if AgentLogic.skippedFolders.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            files.append(AgentLogic.relative(url.path, to: base.path))
            if files.count >= limit { break }
        }
        return files
    }

    static func open(path: String, line: Int?) {
        let environment = ProcessInfo.processInfo.environment
        let goto = (environment["PATH"] ?? "").split(separator: ":").flatMap { folder in ["cursor", "code"].map { "\(folder)/\($0)" } }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let hasXcode = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        let command = AgentLogic.openCommand(path: path, line: line, hasXcode: hasXcode, gotoCLI: goto.map { URL(fileURLWithPath: $0) })
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        if (try? process.run()) == nil { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    private static func run(_ executable: String, _ arguments: [String], in folder: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
