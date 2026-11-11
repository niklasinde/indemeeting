import AppKit
import SwiftUI

/// The topic agents: kept in a file the MCP server reads too, each with its own folder in the app's data folder. Their
/// models are made when first shown and live for this run of the app, like the pull requests' agents.
@MainActor
final class TopicAgentStore: ObservableObject {
    static let shared = TopicAgentStore()

    @Published private(set) var topics: [TopicAgent]
    @Published private(set) var models: [String: AgentModel] = [:]
    private var recent: [String] = []
    private var file: URL
    private var root: URL

    init(file: URL = AppPaths.topicAgents, root: URL = AppPaths.topicFolders) {
        self.file = file
        self.root = root
        topics = TopicAgents.decode(try? Data(contentsOf: file))
    }

    var visible: [TopicAgent] { topics.filter { !$0.archived } }
    var archived: [TopicAgent] { topics.filter(\.archived) }

    func topic(_ key: String) -> TopicAgent? { topics.first { $0.key == key } }

    /// Makes the topic and its folder, or says what is wrong with what was typed.
    func make(name: String, jira: String, slack: String) -> Result<TopicAgent, TopicAgentError> {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let taken = Set(topics.map { URL(fileURLWithPath: $0.folder).lastPathComponent } + folders)
        let made = TopicAgents.make(name: name, jira: jira, slack: slack, root: root, taken: taken, now: Date())
        if case .success(let topic) = made {
            try? FileManager.default.createDirectory(atPath: topic.folder, withIntermediateDirectories: true)
            topics.append(topic)
            save()
        }
        return made
    }

    func show(_ key: String) { AgentHub.shared.show(key) }

    /// Open in Agent on a Jira ticket: its topic agent, made the first time with the prompt to read the ticket waiting.
    func open(ticket: JiraTicket) {
        if let topic = TopicAgents.existing(jiraKey: ticket.key, in: topics) { return reopen(topic) }
        if case .success(let topic) = make(name: TopicAgents.name(ticket: ticket.key, summary: ticket.summary), jira: ticket.key, slack: "") {
            show(topic.key)
        }
    }

    /// Open in Agent on a Slack message: the topic agent for its thread, made the first time.
    func open(slack message: SlackMessage, link: URL?) {
        let thread = link.flatMap { SlackLogic.threadLink($0.absoluteString) }
        if let thread, let topic = TopicAgents.existing(slack: thread, in: topics) { return reopen(topic) }
        if case .success(let topic) = make(name: TopicAgents.name(slackPlace: message.place, author: message.author), jira: "", slack: thread?.url ?? "") {
            if thread == nil { load(topic).draft = "Help me with this Slack message from \(message.author ?? message.place): \(message.text)" }
            show(topic.key)
        }
    }

    private func reopen(_ topic: TopicAgent) {
        if topic.archived { setArchived(topic.key, false) }
        show(topic.key)
    }

    /// The topic's agent, made in its folder (continuing its saved session) when it is not loaded yet.
    @discardableResult
    func load(_ topic: TopicAgent) -> AgentModel {
        let model = models[topic.key] ?? AgentModel(folder: topic.folder)
        if models[topic.key] == nil {
            try? FileManager.default.createDirectory(atPath: topic.folder, withIntermediateDirectories: true)
            model.open(topic: topic)
            models[topic.key] = model
        }
        recent.removeAll { $0 == topic.key }
        recent.insert(topic.key, at: 0)
        for old in recent.dropFirst(PRAgents.runningLimit) where models[old]?.busy == false { models[old]?.stopClient() }
        return model
    }

    /// Hidden from the lists; the folder and the sessions stay, so unarchiving continues where it was.
    func setArchived(_ key: String, _ archived: Bool) {
        guard let index = topics.firstIndex(where: { $0.key == key }) else { return }
        if archived { unload(key) }
        topics[index].archived = archived
        save()
    }

    /// Forgets the topic and removes its folder; Claude Code's own transcripts of its sessions are left alone.
    func delete(_ key: String) {
        guard let topic = topic(key) else { return }
        unload(key)
        if let folder = TopicAgents.ownedFolder(topic, root: root) { try? FileManager.default.removeItem(at: folder) }
        AgentModel.savedSessions[key] = nil
        _ = AgentSessionStore.update(key) { _ in [] }
        topics.removeAll { $0.key == key }
        save()
    }

    func deliver(_ request: AgentInbox.Request) -> AgentInbox.Reply {
        guard let topic = topic(request.agent), !topic.archived else {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: "No topic agent \(request.agent) in WorkTime.")
        }
        return PRAgents.deliver(request, to: load(topic), title: topic.name)
    }

    func stopAll() { models.values.forEach { $0.stopClient() } }

    private func unload(_ key: String) {
        models[key]?.stopClient()
        models[key] = nil
        recent.removeAll { $0 == key }
        if AgentHub.shared.selected == key { AgentHub.shared.selected = AgentOverview.mainKey }
    }

    private func save() {
        let data = TopicAgents.encode(topics), file = file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        AgentStateWriter.shared.changed()
    }

    #if DEBUG
    /// Points the store at a folder of its own, for the previews.
    func useSample(file: URL, root: URL) {
        models.values.forEach { $0.stopClient() }
        self.file = file
        self.root = root
        topics = []
        models = [:]
    }
    #endif
}

/// A topic's agent on the Main page, loaded the first time it is picked.
struct AgentTopicPage: View {
    let key: String
    @Binding var listHidden: Bool
    @ObservedObject private var store = TopicAgentStore.shared

    var body: some View {
        if let model = store.models[key] {
            AgentView(model: model, listHidden: $listHidden)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: key) { if let topic = store.topic(key) { store.load(topic) } }
        }
    }
}

/// The topic agent's name and links in its header.
struct AgentTopicHeader: View {
    let topic: TopicAgent
    @ObservedObject private var jira = JiraModel.shared

    var body: some View {
        Label { Text(topic.name).lineLimit(1) } icon: { AgentTopicIcon(kind: topic.kind) }
            .font(.system(size: 15, weight: .medium))
        if let key = topic.jiraKey {
            Button { jira.site.flatMap { JiraLogic.browseURL(site: $0, key: key) }.map { _ = NSWorkspace.shared.open($0) } } label: { Text(key) }
                .disabled(jira.site == nil)
                .help(jira.site == nil ? "Set up Jira in Settings to open the ticket" : "Open \(key) in Jira")
        }
        if let url = topic.slackURL.flatMap(URL.init(string:)) {
            Button { NSWorkspace.shared.open(url) } label: { Label("Thread", systemImage: "arrow.up.forward.square") }
                .help("Open the Slack thread")
        }
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: topic.folder)]) } label: { Image(systemName: "folder") }
            .buttonStyle(.borderless)
            .help("The agent\u{2019}s own folder: \((topic.folder as NSString).abbreviatingWithTildeInPath)")
    }
}

struct AgentTopicIcon: View {
    let kind: TopicAgent.Kind

    var body: some View {
        switch kind {
        case .ticket: BrandMark.jira.resizable().scaledToFit().frame(width: 12, height: 12)
        case .slack: BrandMark.slack.resizable().scaledToFit().frame(width: 12, height: 12)
        case .topic: Image(systemName: "text.bubble").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The New agent sheet: a name, and optionally the Jira ticket and Slack thread the topic is about.
struct NewTopicAgentSheet: View {
    @State var name = ""
    @State var jira = ""
    @State var slack = ""
    @State var problem: String?
    var store = TopicAgentStore.shared
    let done: (TopicAgent?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Agent").font(.headline)
            Text("An agent for a support case or any other topic, working in its own folder rather than a repository. It reads the "
                 + "linked ticket and thread, and drafts replies for you to post.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            field("Name", text: $name, prompt: "Support: Intrum UAT", hint: nil)
            field("Jira ticket", text: $jira, prompt: "ISD-123 (optional)",
                  hint: jira.trimmingCharacters(in: .whitespaces).isEmpty || JiraLogic.issueKey(jira) != nil ? nil : "Not a key like ISD-123")
            field("Slack thread", text: $slack, prompt: "https://acme.slack.com/archives/C0123/p1700000000123456 (optional)",
                  hint: slack.trimmingCharacters(in: .whitespaces).isEmpty || SlackLogic.threadLink(slack) != nil ? nil : "Not a Slack message link")
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).labelsHidden()
            if let hint { Text(hint).font(.caption).foregroundStyle(.red) }
        }
    }

    private func create() {
        switch store.make(name: name, jira: jira, slack: slack) {
        case .success(let topic): done(topic)
        case .failure(let error): problem = error.message
        }
    }
}
