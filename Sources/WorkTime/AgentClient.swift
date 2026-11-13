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
            if let workspace, prURL == nil { WorkspaceDefaults.setSession(sessionID, for: workspace) }
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
    /// The role this agent is for, when it is an assistant under a Main.
    @Published private(set) var assistant: AssistantEntry?
    private var loadingDefaults = false
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
    /// The workspace a Main is for.
    let workspace: String?
    @Published var model = AgentLogic.storedModel(AgentModel.defaults.string(forKey: AgentLogic.modelKey)) {
        didSet {
            guard !loadingDefaults else { return }
            if assistant != nil { saveAssistantModel() } else { Self.defaults.set(model, forKey: AgentLogic.modelKey) }
        }
    }
    /// How this agent's calls are approved, saved per agent; a change reaches a turn already running too.
    @Published var permissionMode = AgentPermissionMode.ask {
        didSet {
            guard oldValue != permissionMode, !loadingDefaults else { return }
            var modes = Self.defaults.dictionary(forKey: AgentPermissionMode.storageKey) ?? [:]
            modes[historyKey] = permissionMode == .ask && assistant == nil ? nil : permissionMode.rawValue
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
    /// What this session has done since it was shown, for the work map; kept in memory only.
    @Published private(set) var workMap = WorkMap()
    @Published private(set) var problem: String?
    @Published private(set) var files: [String] = []
    @Published var folder: String
    @Published var draft = ""

    /// Beside a pull request: shows a referenced file in the pull request's diff, false when it is not one of its files.
    var reveal: ((String) -> Bool)?
    private var client: AgentClient?
    private var lastModel: String?
    private var rulesChanged: AnyCancellable?

    /// Replaced by the debug preview, so it never writes the app's own settings.
    static var defaults = UserDefaults.standard

    init(folder: String? = nil, main: Workspace? = nil) {
        isMain = main != nil
        workspace = main?.id
        let defaults = Self.defaults
        self.folder = folder ?? main.map { WorkspaceDefaults.folder($0.id) ?? $0.defaultFolder() }
            ?? defaults.string(forKey: AgentLogic.folderKey) ?? NSHomeDirectory()
        history = AgentSessionStore.list(for: historyKey)
        loadMode()
        rulesChanged = AgentRuleStore.shared.$rules.dropFirst().sink { [weak self] in self?.client?.send(.rules($0)) }
        if let main, let session = WorkspaceDefaults.session(main.id) {
            sessionID = session
            remember(session)
            restore()
        }
    }

    /// The pull request url, topic key or assistant key the agent is saved under; nil for Main and a plain folder.
    var agentKey: String? { prURL ?? topic?.key ?? assistant?.key }

    var historyKey: String { AgentSessions.key(agent: agentKey, isMain: isMain, folder: folder, workspace: workspace) }

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
        assistant = nil
        self.folder = folder
        if let workspace { WorkspaceDefaults.setFolder(folder, for: workspace) } else { Self.defaults.set(folder, forKey: AgentLogic.folderKey) }
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

    /// Moves the agent to another folder and keeps its conversation: the sessions' transcripts are copied to where Claude Code
    /// looks for them from the new folder, so the next prompt resumes there.
    func move(to newFolder: String) {
        guard !busy, newFolder != folder, assistant == nil else { return }
        let old = folder, oldKey = historyKey
        let ids = AgentFolders.sessions(current: sessionID, history: history, folder: old, records: Self.importRecords)
        AgentFolders.copy(AgentFolders.plan(sessions: ids, from: old, to: newFolder))
        folder = newFolder
        if let prURL {
            Self.movedFolders[prURL] = newFolder
        } else if let topic {
            self.topic = TopicAgentStore.shared.setFolder(topic.key, to: newFolder) ?? topic
        } else {
            if let workspace { WorkspaceDefaults.setFolder(newFolder, for: workspace) } else { Self.defaults.set(newFolder, forKey: AgentLogic.folderKey) }
        }
        let moved = AgentFolders.moved(history, from: old, to: newFolder), kept = Set(moved.map(\.id))
        if oldKey != historyKey { _ = AgentSessionStore.update(oldKey) { _ in [] } }
        history = AgentSessionStore.update(historyKey) { moved + $0.filter { !kept.contains($0.id) } }
        problem = nil
        items.append(AgentItem(id: "status-\(items.count)", kind: .status("Moved to \((newFolder as NSString).abbreviatingWithTildeInPath)")))
        loadFiles()
    }

    /// Picks the folder to move the agent to, starting from the nearest one that still exists.
    func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Move Here"
        var start = URL(fileURLWithPath: folder)
        while start.path != "/", !FileManager.default.fileExists(atPath: start.path) { start.deleteLastPathComponent() }
        panel.directoryURL = start
        if panel.runModal() == .OK, let url = panel.url { move(to: url.path) }
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
        workMap = WorkMap()
    }

    #if DEBUG
    func preview(workMap: WorkMap) { self.workMap = workMap }
    #endif

    /// Continues an earlier session: its folder, and its transcript read back from Claude Code's file.
    func switchTo(_ entry: AgentSessionEntry) {
        guard !busy, entry.id != sessionID else { return }
        history = AgentSessionStore.update(historyKey) { AgentSessions.record(entry, in: $0) }
        if entry.folder != folder {
            folder = entry.folder
            if let workspace, prURL == nil { WorkspaceDefaults.setFolder(folder, for: workspace) }
            loadFiles()
        }
        lastModel = nil
        queued = []
        problem = nil
        sessionID = entry.id
        restore()
    }

    /// Continues a Claude Code session brought in from outside; while a turn runs it only joins the list.
    func continueImported(_ entry: AgentSessionEntry) {
        guard busy else { return switchTo(entry) }
        history = AgentSessionStore.update(historyKey) { AgentSessions.record(entry, in: $0) }
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
        let note = ClaudeImport.record(for: id, in: Self.importRecords).map { [AgentItem(id: "import-note", kind: .status(ClaudeImport.note($0)))] } ?? []
        replaceItems(note + (restored.flatMap { $0.isEmpty ? nil : $0 }
            ?? [AgentItem(id: "status-0", kind: .status("Continuing the earlier session; its transcript was not found"))]))
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
        let moved = Self.movedFolders[target.url]
        point(prURL: target.url, topic: nil, assistant: nil, folder: moved ?? checkout?.path ?? NSHomeDirectory())
        draft = sessionID == nil ? AgentLogic.reviewPrompt(url: target.url, repo: target.repo, hasCheckout: moved != nil || checkout != nil) : ""
    }

    /// Points the agent at a topic: its folder, the session it had before, and the prompt for its ticket or thread waiting
    /// when there is no session yet. A renamed topic only updates the name.
    func open(topic: TopicAgent) {
        guard self.topic?.id != topic.id || (items.isEmpty && !busy) else { return self.topic = topic }
        point(prURL: nil, topic: topic, assistant: nil, folder: topic.folder)
        draft = sessionID == nil ? TopicAgents.prompt(topic) : ""
    }

    /// Points the agent at an assistant: its folder and the session it had before. A renamed role only updates the entry.
    func open(assistant entry: AssistantEntry, folder: String) {
        guard assistant?.key != entry.key || (items.isEmpty && !busy) else { return assistant = entry }
        point(prURL: nil, topic: nil, assistant: entry, folder: folder)
        draft = ""
    }

    func update(assistant entry: AssistantEntry) {
        if assistant != entry { assistant = entry }
    }

    private func point(prURL: String?, topic: TopicAgent?, assistant: AssistantEntry?, folder: String) {
        if busy { stop() }
        self.prURL = prURL
        self.topic = topic
        self.assistant = assistant
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
        loadingDefaults = true
        defer { loadingDefaults = false }
        permissionMode = AgentPermissionMode.stored(Self.defaults.dictionary(forKey: AgentPermissionMode.storageKey), key: historyKey,
                                                    fallback: assistant.map { Assistants.permissionMode($0.role.permissionMode) } ?? .ask)
        if let assistant {
            let saved = (Self.defaults.dictionary(forKey: Assistants.storedModelsKey) as? [String: String])?[historyKey]
            model = saved.map { AgentLogic.storedModel($0) } ?? Assistants.modelID(assistant.role.model)
        }
        chrome = AgentLogic.chromeEnabled(Self.defaults.dictionary(forKey: AgentLogic.chromeKey), key: historyKey)
        chromeProblem = nil
    }

    private func saveAssistantModel() {
        var saved = Self.defaults.dictionary(forKey: Assistants.storedModelsKey) as? [String: String] ?? [:]
        saved[historyKey] = model
        Self.defaults.set(saved, forKey: Assistants.storedModelsKey)
    }

    /// Reads the role's file again before a prompt, so edits apply at once; false, with the problem shown, when it cannot be used.
    private func refreshAssistant() -> Bool {
        guard let current = assistant else { return true }
        guard let role = AssistantStore.shared.role(of: current) else {
            problem = "The file of the assistant \(current.role.name) is gone."
            return false
        }
        if role != current.role {
            assistant = AssistantEntry(workspace: current.workspace, role: role)
            loadMode()
            if sessionID == nil { folder = AssistantStore.shared.folder(assistant ?? current) }
        }
        guard role.isUsable else {
            problem = "Fix the instructions of \(role.name) first: " + (role.problems.first?.text ?? "")
            return false
        }
        return true
    }

    private var systemPrompt: String? {
        if let assistant { return AssistantStore.shared.systemPrompt(assistant.role, workspace: assistant.workspace, folder: folder) }
        return workspace.flatMap { self.prURL == nil ? WorkspaceStore.shared.mainPrompt(for: $0) : nil } ?? topic.map(TopicAgents.systemPrompt)
    }

    /// The current session of each pull request's and topic's agent, by its key.
    static var savedSessions: [String: String] {
        get { defaults.dictionary(forKey: AgentLogic.prSessionsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: AgentLogic.prSessionsKey) }
    }

    /// The folders pull requests' agents were moved to, by url, used instead of their checkouts.
    static var movedFolders: [String: String] {
        get { defaults.dictionary(forKey: AgentLogic.movedFoldersKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: AgentLogic.movedFoldersKey) }
    }

    /// The Claude Code sessions continued in WorkTime, whose originals are forked rather than written to.
    static var importRecords: [ClaudeImportRecord] {
        get { ClaudeImport.decode(defaults.data(forKey: ClaudeImport.recordsKey)) }
        set { defaults.set(ClaudeImport.encode(newValue), forKey: ClaudeImport.recordsKey) }
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
        let decision = AgentInbox.decide(busy: busy, waitingForPermission: waitingForPermission, queued: queued.count)
        switch decision {
        case .start:
            if !start(AgentInbox.prompt(text)) { return .reject(problem ?? AgentFolders.missingMessage(folder)) }
        case .queue: queued.append(AgentInbox.prompt(text))
        case .reject: break
        }
        return decision
    }

    @discardableResult
    private func start(_ text: String) -> Bool {
        guard FileManager.default.fileExists(atPath: folder) else {
            AgentLogic.apply(.missingFolder(folder), to: &items)
            return false
        }
        guard refreshAssistant(), let client = runningClient() else { return false }
        problem = nil
        items.append(AgentItem(id: "user-\(items.count)", kind: .user(text)))
        workMap.prompt(model: model, at: Date())
        let prompt = AgentLogic.expandMentions(text, cwd: folder) { FileManager.default.fileExists(atPath: $0) }
        busy = true
        let system = systemPrompt, allowedTools = assistant.map { Assistants.allowedTools($0.role) }, delegateFrom = isMain ? workspace : nil
        lastModel = model
        client.send(.prompt(text: prompt, cwd: folder, sessionID: sessionID, model: model,
                            appendSystemPrompt: system, mode: permissionMode, chrome: chrome,
                            fork: ClaudeImport.shouldFork(sessionID, records: Self.importRecords), allowedTools: allowedTools,
                            delegateFrom: delegateFrom))
        return true
    }

    /// `always` first saves the rules the card offers, so this and later calls of every agent that match them run without asking.
    func answer(_ item: AgentItem, allow: Bool, always: Bool = false) {
        guard let id = AgentLogic.permissionID(of: item.id) else { return }
        if always, case .permission(_, _, _, let offer, nil) = item.kind { AgentRuleStore.shared.add(offer) }
        AgentLogic.answer(item.id, allow: allow, in: &items)
        client?.send(.permission(id: id, allow: allow))
    }

    func stop() {
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
    /// Opens a pull request on the GitHub page, the same as a `worktime://pr` link; the app delegate sets it.
    static var openPullRequestLink: ((GitHubLink.Target) -> Void)?

    func open(_ url: URL) -> OpenURLAction.Result {
        if let target = GitHubLink.parseAgent(url.absoluteString), let open = Self.openAgentLink {
            open(target)
            return .handled
        }
        if NSApp.currentEvent?.modifierFlags.contains(.command) != true, url.scheme?.hasPrefix("http") == true,
           let target = GitHubLink.pasted(url.absoluteString), let open = Self.openPullRequestLink {
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
                                                           mcpCommand: Bundle.main.executablePath, workspace: workspace ?? assistant?.workspace,
                                                           agent: isMain ? workspace.map(Workspaces.mainKey) : agentKey)
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
        let object = AgentDelegation.object(line)
        if object?["type"] as? String == "resolve_target", let workspace {
            let key = AgentDelegation.target(object?["input"] as? [String: Any] ?? [:], workspace: workspace)?.key
            client?.send(.target(id: object?["id"] as? String ?? "", key: key))
            return
        }
        if let object { workMap.receive(object, cwd: folder, at: Date()) }
        guard var event = AgentEvent.decode(line, cwd: folder) else { return }
        if case .permissionRequest(let id, let tool, let summary, let detail, _) = event, isMain, let workspace,
           let rule = AgentDelegation.rule(tool: tool, input: object?["input"] as? [String: Any] ?? [:], workspace: workspace) {
            event = .permissionRequest(id: id, tool: tool, summary: summary, detail: detail, offer: [rule])
        }
        if case .chrome(let problem) = event { return chromeProblem = chrome ? problem : nil }
        if let session = AgentLogic.apply(event, to: &items) { adopt(session) }
        if case .idle = event { finishTurn() }
    }

    /// The session the sidecar reports; a fork of an imported original replaces it in the list.
    private func adopt(_ session: String) {
        let previous = sessionID
        sessionID = session
        guard let previous, previous != session, ClaudeImport.shouldFork(previous, records: Self.importRecords) else { return }
        Self.importRecords = ClaudeImport.forked(previous, into: session, in: Self.importRecords)
        forget(previous)
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
        workMap.finish(at: Date())
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
