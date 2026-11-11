import Foundation

/// A session an agent had, kept so it can be picked again after New Session or a restart.
struct AgentSessionEntry: Codable, Equatable, Identifiable {
    var id: String
    var folder: String
    var created: Date
    var lastUsed: Date
    var title: String
    var model: String?
}

/// Each agent's past sessions, stored per agent (Main or a pull request url), newest first.
enum AgentSessions {
    static let historyKey = "agentSessionHistory"
    static let limit = 30
    static let titleLimit = 60
    static let restoreLimit = 200
    static let untitled = "Untitled session"

    static func key(agent: String?, isMain: Bool, folder: String, workspace: String? = nil) -> String {
        agent ?? (isMain ? workspace.map(Workspaces.mainKey) ?? AgentOverview.mainKey : "folder:" + folder)
    }

    /// What a session is called in the list: its first prompt in one line, with the app's own prompts named.
    static func title(prompt: String) -> String {
        let text = AgentInbox.fromMain(prompt).map { "From Main: " + $0 } ?? prompt
        if text == AgentLogic.catchUpPrompt { return "Catch up" }
        if text.hasPrefix("Review https://"), let url = text.dropFirst("Review ".count).split(separator: " ").first,
           let pr = GitHubLink.pullRequest(at: url.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            return "Review \(pr.repo)#\(pr.number)"
        }
        let line = ActivityLogic.firstLine(of: text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? untitled : ActivityLogic.truncate(line, to: titleLimit)
    }

    /// Adds the session, or updates the one with its id while keeping when it began and its title.
    static func record(_ entry: AgentSessionEntry, in list: [AgentSessionEntry]) -> [AgentSessionEntry] {
        var entry = entry
        if let old = list.first(where: { $0.id == entry.id }) {
            entry.created = min(old.created, entry.created)
            if old.title != untitled { entry.title = old.title }
            entry.model = entry.model ?? old.model
            entry.lastUsed = max(old.lastUsed, entry.lastUsed)
        }
        return Array(([entry] + list.filter { $0.id != entry.id }).sorted { $0.lastUsed > $1.lastUsed }.prefix(limit))
    }

    static func touch(_ id: String, at date: Date, model: String?, in list: [AgentSessionEntry]) -> [AgentSessionEntry] {
        guard var entry = list.first(where: { $0.id == id }) else { return list }
        entry.lastUsed = date
        entry.model = model ?? entry.model
        return record(entry, in: list)
    }

    static func removing(_ id: String, from list: [AgentSessionEntry]) -> [AgentSessionEntry] {
        list.filter { $0.id != id }
    }

    static func decode(_ data: Data?) -> [String: [AgentSessionEntry]] {
        data.flatMap { AgentInbox.decode([String: [AgentSessionEntry]].self, from: $0) } ?? [:]
    }

    static func encode(_ history: [String: [AgentSessionEntry]]) -> Data { AgentInbox.encode(history) }

    /// Transcripts in the agent's folder that its list does not have, newest first.
    static func others(_ files: [(id: String, modified: Date)], excluding known: Set<String>, limit: Int = 20) -> [(id: String, modified: Date)] {
        Array(files.filter { ClaudeTranscripts.isSessionID($0.id) && !known.contains($0.id) }.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// A restored transcript cut to its last `limit` items, with a note saying how many earlier ones are left out. Items are
    /// numbered by position again, so the ones the agent adds next cannot take an id already used.
    static func restored(_ items: [AgentItem], limit: Int = restoreLimit) -> [AgentItem] {
        guard items.count > limit else { return items }
        let cut = items.count - limit
        let kept = [AgentItem(id: "status-0", kind: .status("\(cut) earlier item\(cut == 1 ? "" : "s") of this session not shown"))]
            + items.suffix(limit)
        return kept.enumerated().map { index, item in
            if item.id.hasPrefix("tool-") { return item }
            let prefix = item.id.split(separator: "-").first.map(String.init) ?? "item"
            return AgentItem(id: "\(prefix)-\(index)", kind: item.kind)
        }
    }

    /// The agents for the Main page's list: Main first (of a workspace), then the rest most urgent first and newest first, with the time a
    /// saved session was last used where the agent is not loaded.
    static func sidebar(_ agents: [AgentState], lastUsed: [String: Date]) -> [AgentState] {
        let filled = agents.map { state -> AgentState in
            var state = state
            if state.updatedAt == nil { state.updatedAt = lastUsed[state.key] }
            return state
        }
        let main = filled.filter { Workspaces.isMainKey($0.key) }
        return main + AgentOverview.sorted(filled.filter { !Workspaces.isMainKey($0.key) })
    }

    /// `finq.api#2591` for a pull request url: the repository without its owner, short enough for the agents list.
    static func shortReference(_ url: String) -> String {
        GitHubLink.pullRequest(at: url).map { "\($0.repo.split(separator: "/").last ?? "")#\($0.number)" } ?? url
    }

    static func lastUsed(_ history: [String: [AgentSessionEntry]]) -> [String: Date] {
        history.compactMapValues { $0.map(\.lastUsed).max() }
    }
}
