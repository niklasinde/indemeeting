import AppKit
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
    @Published private(set) var items: [AgentItem] = []
    @Published private(set) var busy = false
    @Published private(set) var sessionID: String? {
        didSet { if let prURL, let sessionID { Self.prSessions[prURL] = sessionID } }
    }
    @Published private(set) var prURL: String?
    @Published var model = AgentLogic.storedModel(UserDefaults.standard.string(forKey: AgentLogic.modelKey)) {
        didSet { UserDefaults.standard.set(model, forKey: AgentLogic.modelKey) }
    }
    @Published private(set) var problem: String?
    @Published private(set) var files: [String] = []
    @Published var folder: String
    /// Starting a prompt on Auto loads Ministral, so it is ready to route the prompt once it is sent.
    @Published var draft = "" {
        didSet { if oldValue.isEmpty, !draft.isEmpty, model == AgentLogic.auto, !OllamaSummarizer.isForced() { LocalLLM.shared.prepare() } }
    }

    private let tokens: TokenStore
    private var client: AgentClient?
    private var routing: Task<Void, Never>?
    private var lastModel: String?
    private var turnIsAuto = false

    init(folder: String? = nil, tokens: TokenStore = .claudeOAuth) {
        self.tokens = tokens
        self.folder = folder ?? UserDefaults.standard.string(forKey: AgentLogic.folderKey) ?? NSHomeDirectory()
        guard let didChange = tokens.didChange else { return }
        NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopClient() }
        }
    }

    var mentionMatches: [String] {
        AgentLogic.mentionQuery(draft).map { AgentLogic.fuzzyMatches($0, in: files) } ?? []
    }

    func preview(_ items: [AgentItem], files: [String] = []) {
        self.items = items
        self.files = files
    }

    func choose(folder: String) {
        guard folder != self.folder else { return }
        prURL = nil
        self.folder = folder
        UserDefaults.standard.set(folder, forKey: AgentLogic.folderKey)
        newSession()
        loadFiles()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { choose(folder: url.path) }
    }

    func newSession() {
        if busy { stop() }
        if let prURL { Self.prSessions[prURL] = nil }
        sessionID = nil
        lastModel = nil
        items = []
        problem = nil
    }

    /// Points the window at a pull request: its checkout (or the home folder), the session it had before, and a review
    /// prompt waiting to be sent when there is no session yet. Opening the one already shown changes nothing.
    func open(pr target: GitHubLink.Target, checkout: URL?) {
        guard prURL != target.url || (items.isEmpty && !busy) else { return }
        if busy { stop() }
        prURL = target.url
        folder = checkout?.path ?? NSHomeDirectory()
        lastModel = nil
        problem = nil
        sessionID = Self.prSessions[target.url]
        items = sessionID == nil ? [] : [AgentItem(id: "status-0", kind: .status("Continuing the earlier session on this pull request"))]
        draft = sessionID == nil ? AgentLogic.reviewPrompt(url: target.url, repo: target.repo, hasCheckout: checkout != nil) : ""
        loadFiles()
    }

    private static var prSessions: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: AgentLogic.prSessionsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: AgentLogic.prSessionsKey) }
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
        guard !text.isEmpty, !busy, let client = runningClient() else { return }
        draft = ""
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
            client.send(.prompt(text: prompt, cwd: cwd, sessionID: sessionID, model: picked))
        }
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

    func answer(_ item: AgentItem, allow: Bool) {
        guard let id = AgentLogic.permissionID(of: item.id) else { return }
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

    func open(_ url: URL) -> OpenURLAction.Result {
        guard let target = AgentLogic.codeTarget(url) else { return .systemAction }
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
        let token = tokens.token()
        let childEnvironment = AgentLogic.childEnvironment(environment, nodeFolder: node.deletingLastPathComponent().path, token: token,
                                                           mcpCommand: Bundle.main.executablePath)
        do {
            let client = try AgentClient(node: node, script: script, environment: childEnvironment, onLine: { [weak self] line in
                Task { @MainActor [weak self] in self?.receive(line) }
            }, onExit: { [weak self] status, errors in
                Task { @MainActor [weak self] in self?.exited(status: status, errors: SecretRedaction.redact(errors, key: token)) }
            })
            self.client = client
            return client
        } catch {
            problem = "The agent could not start: \(error.localizedDescription)"
            return nil
        }
    }

    private func receive(_ line: String) {
        guard let event = AgentEvent.decode(line, cwd: folder) else { return }
        if case .idle = event { busy = false }
        if let session = AgentLogic.apply(event, to: &items, auto: turnIsAuto) { sessionID = session }
    }

    private func exited(status: Int32, errors: String) {
        client = nil
        guard busy else { return }
        busy = false
        if AgentLogic.needsSignIn(errors) { return AgentLogic.appendSignIn(to: &items) }
        let tail = errors.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        items.append(AgentItem(id: "error-\(items.count)", kind: .error("The agent stopped (exit \(status)). \(tail)")))
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
