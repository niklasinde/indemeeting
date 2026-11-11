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
    /// embedded panes (the swiftc build) the Agent window opens instead.
    func open(_ target: GitHubLink.Target) {
        guard EmbeddedTerminalModel.available else { return AgentWindow.shared.show(pr: target) }
        let key = target.url
        if models[key] != nil { return show(key) }
        Task { @MainActor in
            let checkout = await Task.detached { GitHubClaude.checkout(for: target.repo, under: GitHubClaudeModel.repositoriesRoot) }.value
            if models[key] == nil {
                let model = AgentModel()
                model.open(pr: target, checkout: checkout)
                models[key] = model
            }
            show(key)
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
        VStack(spacing: 0) {
            header
            Divider()
            AgentPanel(model: model, gutter: 16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.reveal = { [weak page] in page?.reveal(file: $0) ?? false } }
    }

    private var header: some View {
        let folder = (model.folder as NSString).abbreviatingWithTildeInPath
        return HStack(spacing: 8) {
            Circle().fill(model.busy ? Color.green : .secondary.opacity(0.5)).frame(width: 7, height: 7)
                .help(model.busy ? "The agent is working" : "The agent is idle")
            Text("Agent").font(.callout.weight(.medium))
            Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                .help("The agent works in \(folder)")
            Spacer(minLength: 4)
            AgentModelPicker(model: model)
            AgentNewSessionButton(model: model).buttonStyle(.bordered)
            Divider().frame(height: 14)
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
