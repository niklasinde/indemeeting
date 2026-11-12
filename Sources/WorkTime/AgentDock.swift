import SwiftUI

/// The Agent beside a pull request: one model per pull request for this run of the app, in the place of its Claude terminal.
/// The sidecar starts on the first prompt; only the most recently opened few keep theirs, the rest start again on the next prompt.
@MainActor
final class PRAgents: ObservableObject {
    static let shared = PRAgents()
    static let runningLimit = 3

    @Published private(set) var models: [String: AgentModel] = [:]
    @Published private(set) var shown: Set<String> = []
    private var recent: [String] = []

    func model(for key: String) -> AgentModel? { models[key] }

    func isShown(_ key: String) -> Bool { models[key] != nil && shown.contains(key) }

    /// Shows the pull request's agent, made in its checkout with the review prompt waiting the first time. Without the
    /// embedded panes (the swiftc build) it shows on the Main page instead.
    func open(_ target: GitHubLink.Target) {
        guard EmbeddedTerminalModel.available else { return AgentHub.shared.show(target.url) }
        let key = target.url
        if models[key] != nil { return show(key) }
        Task { @MainActor in
            _ = await load(target)
            show(key)
        }
    }

    /// The pull request's agent, made in its checkout (continuing its saved session) when it is not loaded yet.
    func load(_ target: GitHubLink.Target) async -> AgentModel {
        if let model = models[target.url] { return model }
        let checkout = await Task.detached { GitHubClaude.checkout(for: target.repo, under: GitHubClaudeModel.repositoriesRoot) }.value
        if let model = models[target.url] { return model }
        let model = AgentModel()
        model.open(pr: target, checkout: checkout)
        models[target.url] = model
        return model
    }

    /// A prompt from Main for a pull request's agent, sent without showing it; a notification says where it went.
    func deliver(_ request: AgentInbox.Request) async -> AgentInbox.Reply {
        guard let target = GitHubLink.pullRequest(at: request.agent) else {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: "Not a pull request url.")
        }
        return Self.deliver(request, to: await load(target), title: AgentOverview.prTitle(target.url))
    }

    /// Hands Main's prompt to the agent and says how it went; a notification says where it went.
    static func deliver(_ request: AgentInbox.Request, to model: AgentModel, title: String) -> AgentInbox.Reply {
        switch model.deliver(fromMain: request.text) {
        case .reject(let why): return AgentInbox.Reply(id: request.id, status: .rejected, message: why)
        case .start, .queue:
            let queued = !model.queued.isEmpty
            Notifier.postAgentMessage(title: "Main \u{2192} \(title)", body: request.text)
            return AgentInbox.Reply(id: request.id, status: queued ? .queued : .started, sessionID: model.sessionID, message: queued ? "queued" : "started")
        }
    }

    func show(_ key: String) {
        shown.insert(key)
        EmbeddedTerminalModel.shared.setShown(key, false)
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        for old in recent.dropFirst(Self.runningLimit) where models[old]?.busy == false { models[old]?.stopClient() }
    }

    func hide(_ key: String) { shown.remove(key) }

    /// Stops the agent and forgets its transcript; the session stays saved, so opening it again continues it.
    func close(_ key: String) {
        models[key]?.stopClient()
        models[key] = nil
        shown.remove(key)
        recent.removeAll { $0 == key }
    }

    func stopAll() { models.values.forEach { $0.stopClient() } }

    #if DEBUG
    func showSample(_ key: String, model: AgentModel) {
        models[key] = model
        show(key)
    }
    #endif
}

/// The agent's pane on the pull request page: a compact header over the same transcript and composer as the Agent window.
struct AgentDockPane: View {
    let key: String
    @ObservedObject var model: AgentModel
    let page: GitHubDetailModel

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= AgentWorkMap.sideMinWidth
            VStack(spacing: 0) {
                header(wide: wide)
                Divider()
                AgentWorkMapSplit(model: model, wide: wide) { AgentPanel(model: model, gutter: 16) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.reveal = { [weak page] in page?.reveal(file: $0) ?? false } }
    }

    private func header(wide: Bool) -> some View {
        let folder = (model.folder as NSString).abbreviatingWithTildeInPath
        return HStack(spacing: 8) {
            Circle().fill(model.busy ? Color.green : .secondary.opacity(0.5)).frame(width: 7, height: 7)
                .help(model.busy ? "The agent is working" : "The agent is idle")
            Text("Agent").font(.callout.weight(.medium))
            if !model.queued.isEmpty {
                Text("\(model.queued.count) from Main queued").font(.caption).foregroundStyle(.purple)
                    .help("Prompts from Main that start when the current one finishes")
            }
            Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                .help("The agent works in \(folder)")
            AgentWorktreeNote(folder: model.folder)
            Spacer(minLength: 4)
            AgentSessionsButton(model: model).labelStyle(.iconOnly)
            AgentChromeToggle(model: model).labelStyle(.iconOnly)
            AgentPermissionPicker(model: model)
            AgentModelPicker(model: model)
            AgentNewSessionButton(model: model).buttonStyle(.bordered).labelStyle(.titleOnly)
            AgentWorkMapToggle(model: model, wide: wide).labelStyle(.iconOnly)
            AgentOverflowMenu(model: model)
            Divider().frame(height: 14)
            DockPlacementMenu()
            Button { PRAgents.shared.hide(key) } label: { Image(systemName: "chevron.down") }
                .help("Hide the agent; its transcript is kept")
            Button { PRAgents.shared.close(key) } label: { Image(systemName: "xmark") }
                .help("Close the agent and stop it; Open in Agent continues the saved session")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Where the pane goes: picked in the Agent's and the terminal's header and shared by both.
struct DockPlacementMenu: View {
    @AppStorage(DockPlacement.choiceKey) private var choice = DockPlacement.Choice.automatic

    var body: some View {
        Menu {
            Picker("Placement", selection: $choice) {
                ForEach(DockPlacement.Choice.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: choice.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Placement: \(choice.title)")
    }
}

/// A second after the agents change, refreshes the Main page's list and writes `agents.json` for the MCP server, the file
/// only once started by the app (never by previews).
@MainActor
final class AgentStateWriter: ObservableObject {
    static let shared = AgentStateWriter()
    @Published private(set) var revision = 0
    private var url: URL?
    private var scheduled = false

    func start(url: URL = AppPaths.agentState) {
        self.url = url
        changed()
    }

    func changed() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.write() }
    }

    private func write() {
        scheduled = false
        revision += 1
        guard let url else { return }
        let data = AgentOverview.encode(states(), now: Date())
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func states() -> [AgentState] {
        let workspaces = WorkspaceStore.shared
        var states = workspaces.workspaces.compactMap { workspace in
            AgentHub.shared.mains[workspace.id].map { state($0, key: workspace.mainKey, title: "Main \u{00B7} \(workspace.name)") }
        }
        let titles = Dictionary(GitHubModel.shared.prs.values.joined().map { ($0.url, $0.title) }) { first, _ in first }
        for (url, model) in PRAgents.shared.models.sorted(by: { $0.key < $1.key }) {
            states.append(state(model, key: url, title: AgentOverview.prTitle(url, title: titles[url])))
        }
        let sessions = AgentModel.savedSessions
        let topics = TopicAgentStore.shared
        for topic in topics.visible {
            let loaded = topics.models[topic.key].map { state($0, key: topic.key, title: topic.name) }
            states.append(AgentState.topic(topic, loaded: loaded, sessionID: sessions[topic.key]))
        }
        let assistants = AssistantStore.shared
        for entry in assistants.all {
            let loaded = assistants.models[entry.key].map { state($0, key: entry.key, title: entry.role.name) }
            states.append(AgentState.assistant(entry, loaded: loaded, sessionID: sessions[entry.key], folder: assistants.folder(entry)))
        }
        return AgentOverview.withPersisted(states, sessions: sessions, known: Array(AgentSessionStore.all().keys)).map { state in
            var state = state
            if !state.loaded, let title = titles[state.key] { state.title = AgentOverview.prTitle(state.key, title: title) }
            state.workspace = workspaces.assigned(state)
            return state
        }
    }

    private func state(_ model: AgentModel, key: String, title: String) -> AgentState {
        AgentOverview.snapshot(key: key, title: title, prURL: model.prURL, folder: model.folder, sessionID: model.sessionID, items: model.items,
                               busy: model.busy, seen: model.resultSeen, updatedAt: model.updated, queued: model.queued.count)
    }
}

/// Takes the prompts the MCP server's send_to_agent leaves in the inbox folder and answers each with a reply file.
@MainActor
final class AgentInboxWatcher {
    static let shared = AgentInboxWatcher()
    private var timer: Timer?
    private var folder = AppPaths.agentInbox

    func start(folder: URL = AppPaths.agentInbox) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where NoticeLogic.isRequest(name) {
            let url = folder.appendingPathComponent(name)
            let data = try? Data(contentsOf: url)
            try? fileManager.removeItem(at: url)
            guard let request = data.flatMap({ AgentInbox.decode(NoticeRequest.self, from: $0) }) else { continue }
            try? AgentInbox.encode(NoticeCenter.shared.handle(request)).write(to: folder.appendingPathComponent(AgentInbox.replyName(request.id)),
                                                                               options: .atomic)
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where AgentInbox.isRequest(name) {
            let url = folder.appendingPathComponent(name)
            let data = try? Data(contentsOf: url)
            try? fileManager.removeItem(at: url)
            guard let request = data.flatMap({ AgentInbox.decode(AgentInbox.Request.self, from: $0) }) else { continue }
            let replyURL = folder.appendingPathComponent(AgentInbox.replyName(request.id))
            Task { @MainActor in
                let reply: AgentInbox.Reply
                if let problem = AgentInbox.problem(request, now: Date()) {
                    reply = AgentInbox.Reply(id: request.id, status: .rejected, message: problem.message)
                } else if TopicAgents.isKey(request.agent) {
                    reply = TopicAgentStore.shared.deliver(request)
                } else if Assistants.isKey(request.agent) {
                    reply = AssistantStore.shared.deliver(request)
                } else {
                    reply = await PRAgents.shared.deliver(request)
                }
                try? AgentInbox.encode(reply).write(to: replyURL, options: .atomic)
            }
        }
    }
}
