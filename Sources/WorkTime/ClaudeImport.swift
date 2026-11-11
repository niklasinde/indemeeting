import AppKit
import SwiftUI

/// Continuing a Claude Code session in WorkTime, from a `worktime://agent?session=` link or the Import session sheet, and
/// going the other way with Open in Claude Code.
@MainActor
enum ClaudeSessionImporter {
    /// Gives the session to the pull request's agent when its checkout is on that pull request's branch, else to a new topic
    /// agent in the session's folder, and shows it on the Main page. A session an agent already has just shows that agent.
    static func open(session id: String, cwd: String?) async {
        let records = AgentModel.importRecords
        if let key = ClaudeImport.owner(of: id, history: AgentSessionStore.all(), saved: AgentModel.savedSessions, records: records) {
            return AgentHub.shared.show(key)
        }
        guard let summary = await Task.detached(operation: { ClaudeSessionFiles.locate(id, cwd: cwd) }).value else {
            AgentHub.shared.show()
            return Notifier.postAgentMessage(title: "Claude Code session not found", body: "No transcript for the session \(id) on this Mac.")
        }
        let folder = summary.cwd
        let repository = await Task.detached(operation: { ClaudeImport.repository(at: folder) }).value
        var seen = Set<String>()
        let prs = GitHubModel.shared.prs.values.joined().filter { seen.insert($0.url).inserted }
        let store = GitHubModel.shared.store
        let target = ClaudeImport.target(branch: repository?.branch, remotes: repository?.remotes ?? [], prs: prs,
                                         head: { store?.githubHeadBranch($0) }, prompt: summary.prompt)
        AgentModel.importRecords = ClaudeImport.adding(original: id, date: summary.lastActivity, to: records)
        let entry = AgentSessionEntry(id: id, folder: folder, created: summary.lastActivity, lastUsed: Date(),
                                      title: ClaudeImport.agentName(prompt: summary.prompt), model: nil)
        switch target {
        case .pullRequest(let url):
            guard let pr = GitHubLink.pullRequest(at: url) else { return }
            await PRAgents.shared.load(pr).continueImported(entry)
            AgentHub.shared.show(url)
        case .topic(let name):
            let topics = TopicAgentStore.shared
            let topic = topics.make(importing: id, name: name, folder: folder)
            topics.load(topic).continueImported(entry)
            AgentHub.shared.show(topic.key)
        }
    }

    /// Asks first, since the agent and Claude Code must not both continue the session, then runs `claude --resume` in a terminal.
    static func openInClaudeCode(folder: String, session: String) {
        let alert = NSAlert()
        alert.messageText = "Open this session in Claude Code?"
        alert.informativeText = "Claude Code continues the session in a terminal. Don\u{2019}t use this agent while it runs there: "
            + "both would write to the same session and drift apart."
        alert.addButton(withTitle: "Open in Claude Code")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let note = GitHubClaudeModel.shared.runInTerminal(directory: URL(fileURLWithPath: folder), flags: ClaudeImport.resumeFlags(session: session))
        else { return }
        let failed = NSAlert()
        failed.messageText = "Could not open Claude Code"
        failed.informativeText = note.text + (note.copy.map { "\n\n\($0)" } ?? "")
        failed.runModal()
    }
}

/// The agent's own menu in its header: what does not need a button of its own.
struct AgentOverflowMenu: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        Menu {
            Button("Open in Claude Code\u{2026}") {
                if let session = model.sessionID { ClaudeSessionImporter.openInClaudeCode(folder: model.folder, session: session) }
            }
            .disabled(model.sessionID == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

/// Recent Claude Code sessions across every project that no agent has yet; picking one continues it in WorkTime.
struct ImportClaudeSessionSheet: View {
    let done: () -> Void
    @State private var sessions: [ClaudeSessionSummary]?
    @State private var query = ""
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Claude Code Session").font(.headline)
            Text("Continues a session in WorkTime: in its pull request\u{2019}s agent when its folder is on that branch, otherwise in a new "
                 + "agent working in the session\u{2019}s folder. The original session is left as it was; WorkTime continues a copy.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search", text: $query, prompt: Text("Search folders and prompts")).textFieldStyle(.roundedBorder)
            list.frame(height: 340)
            HStack {
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
    }

    @ViewBuilder
    private var list: some View {
        if let sessions {
            let shown = ClaudeImport.filter(sessions, query: query)
            if shown.isEmpty {
                Text(sessions.isEmpty ? "No Claude Code sessions to import." : "No session matches.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let now = Date()
                List(shown) { session in
                    Button { pick(session) } label: { row(session, now: now) }
                        .buttonStyle(.plain)
                        .disabled(importing)
                }
                .listStyle(.bordered)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ session: ClaudeSessionSummary, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title).lineLimit(1)
            HStack(spacing: 6) {
                Text((session.cwd as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text(GitHubLogic.updatedText(session.lastActivity, now: now))
                Text(ByteCountFormatter.string(fromByteCount: session.size, countStyle: .file))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func load() async {
        let known = ClaudeImport.knownIDs(history: AgentSessionStore.all(), saved: AgentModel.savedSessions, records: AgentModel.importRecords)
        sessions = await Task.detached { ClaudeSessionFiles.recent(excluding: known) }.value
    }

    private func pick(_ session: ClaudeSessionSummary) {
        importing = true
        Task {
            await ClaudeSessionImporter.open(session: session.id, cwd: session.cwd)
            done()
        }
    }
}
