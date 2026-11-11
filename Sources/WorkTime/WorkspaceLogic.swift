import Foundation

/// A set of the user's things (folders, GitHub owners, Jira projects, Slack) with a Main agent of its own.
struct Workspace: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var color: String
    var roots: [String]
    var githubOwners: [String]
    var jiraProjects: [String]
    /// The Slack workspace this one reads; nil leaves Slack out.
    var slack: String?
    /// Files whose contents follow MAIN.md in the Main's system prompt.
    var extraFiles: [String]

    var mainKey: String { Workspaces.mainKey(id) }

    func defaultFolder(home: String = NSHomeDirectory()) -> String {
        roots.first.map { Workspaces.expand($0, home: home) } ?? home
    }
}

/// What the app saves in `workspaces.json` and the `--mcp` process reads.
struct WorkspaceFile: Codable, Equatable, Sendable {
    var workspaces: [Workspace]
    /// An agent's key (a pull request url or topic key) to the workspace the user moved it to.
    var overrides: [String: String] = [:]
}

enum WorkspaceError: Error, Equatable {
    case unknown(String, [String])

    var message: String {
        switch self {
        case .unknown(let text, let names): return "No workspace \u{201C}\(text)\u{201D}; use one of \(names.joined(separator: ", ")) or all."
        }
    }
}

/// Which workspace a tool call is about: the one named, else the calling Main's, else everything.
struct WorkspaceScope: Equatable, Sendable {
    var id: String?
    /// Whether the call named the workspace itself rather than taking the Main's own.
    var named = false

    static let all = WorkspaceScope(id: nil, named: true)
}

enum Workspaces {
    static let defaultID = "work"
    static let envKey = "WORKTIME_WORKSPACE"
    static let mainPrefix = "main:"
    static let legacyMainKey = "main"
    static let allChoice = "all"
    static let selectedKey = "agentWorkspaceSelected"
    static let collapsedKey = "agentWorkspaceCollapsed"
    static let mainSessionsKey = "agentMainSessions"
    static let mainFoldersKey = "agentMainFolders"

    static let defaults = [
        Workspace(id: "work", name: "Work", symbol: "briefcase.fill", color: "blue", roots: ["~/git/quiddly"], githubOwners: ["quiddly-com"],
                  jiraProjects: ["QDLY", "ISD", "QPB"], slack: "Quiddly", extraFiles: []),
        Workspace(id: "personal", name: "Personal", symbol: "person.fill", color: "green", roots: ["~/git/inde"], githubOwners: ["niklasinde"],
                  jiraProjects: [], slack: nil, extraFiles: []),
    ]

    // MARK: Keys

    static func mainKey(_ id: String) -> String { mainPrefix + id }

    static func isMainKey(_ key: String) -> Bool { key == legacyMainKey || key.hasPrefix(mainPrefix) }

    /// The workspace a Main's key names; the old `main` key is the default workspace's.
    static func id(ofMainKey key: String) -> String? {
        if key == legacyMainKey { return defaultID }
        return key.hasPrefix(mainPrefix) ? String(key.dropFirst(mainPrefix.count)) : nil
    }

    // MARK: File

    static func encode(_ file: WorkspaceFile) -> Data { AgentInbox.encode(file) }

    /// The saved file, with the default workspaces when there is none or it holds no workspace.
    static func decode(_ data: Data?) -> WorkspaceFile {
        guard let file = data.flatMap({ AgentInbox.decode(WorkspaceFile.self, from: $0) }), !file.workspaces.isEmpty else {
            return WorkspaceFile(workspaces: defaults)
        }
        return file
    }

    static func workspace(_ id: String?, in workspaces: [Workspace]) -> Workspace? {
        workspaces.first { $0.id == id } ?? workspaces.first { $0.id == defaultID } ?? workspaces.first
    }

    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return home }
        let expanded = trimmed.hasPrefix("~/") ? home + trimmed.dropFirst(1) : trimmed
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }

    // MARK: Assignment

    /// What decides where a thing belongs.
    struct Subject: Sendable {
        var folders: [String] = []
        /// A repository's folder name, looked for under each root when no folder matches.
        var repo: String?
        var owner: String?
        var jiraKey: String?
        var override: String?
    }

    /// An override that names a workspace; else the workspace whose root holds the longest matching folder, or holds the
    /// repository; else the one owning the GitHub owner or Jira project; else the default.
    static func assign(_ subject: Subject, in workspaces: [Workspace], home: String = NSHomeDirectory(),
                       exists: (String) -> Bool = { _ in false }) -> String {
        if let id = subject.override, workspaces.contains(where: { $0.id == id }) { return id }
        var best: (id: String, length: Int)?
        for workspace in workspaces {
            for root in workspace.roots.map({ expand($0, home: home) }) {
                for folder in subject.folders where folder == root || folder.hasPrefix(root + "/") {
                    if root.count > (best?.length ?? -1) { best = (workspace.id, root.count) }
                }
            }
        }
        if let best { return best.id }
        if let repo = subject.repo, let found = workspaces.first(where: { workspace in
            workspace.roots.contains { exists(expand($0, home: home) + "/" + repo) }
        }) { return found.id }
        if let owner = subject.owner?.lowercased(), let found = workspaces.first(where: { $0.githubOwners.contains { $0.lowercased() == owner } }) {
            return found.id
        }
        if let project = subject.jiraKey?.split(separator: "-").first.map({ $0.uppercased() }),
           let found = workspaces.first(where: { $0.jiraProjects.contains { $0.uppercased() == project } }) {
            return found.id
        }
        return workspace(defaultID, in: workspaces)?.id ?? defaultID
    }

    static func prSubject(_ url: String, override: String?) -> Subject {
        Subject(owner: GitHubLink.pullRequest(at: url)?.repo.split(separator: "/").first.map(String.init), override: override)
    }

    static func assigned(_ state: AgentState, in file: WorkspaceFile, home: String = NSHomeDirectory()) -> String {
        if let id = id(ofMainKey: state.key) { return file.workspaces.contains { $0.id == id } ? id : (workspace(nil, in: file.workspaces)?.id ?? id) }
        let subject = Subject(folders: state.folder.map { [$0] } ?? [], owner: state.prURL.flatMap { prSubject($0, override: nil).owner },
                              jiraKey: state.jiraKey, override: file.overrides[state.key])
        return assign(subject, in: file.workspaces, home: home)
    }

    // MARK: Grouping

    struct Group: Equatable {
        let workspace: Workspace
        let main: AgentState?
        let agents: [AgentState]

        var all: [AgentState] { (main.map { [$0] } ?? []) + agents }
        var needing: Int { agents.filter { AgentOverview.need($0) < .working }.count }
    }

    /// The agents of each workspace in the order of the file, each with its Main first.
    static func groups(_ states: [AgentState], file: WorkspaceFile, lastUsed: [String: Date], home: String = NSHomeDirectory()) -> [Group] {
        let members = Dictionary(grouping: states) { assigned($0, in: file, home: home) }
        return file.workspaces.map { workspace in
            let rows = AgentSessions.sidebar(members[workspace.id] ?? [], lastUsed: lastUsed)
            let main = rows.first { isMainKey($0.key) }
            return Group(workspace: workspace, main: main, agents: rows.filter { !isMainKey($0.key) })
        }
    }

    // MARK: Scope

    /// The workspace a tool call is about: `argument` when it names one (`all` for everything), else the calling Main's own
    /// from `environment`, else everything.
    static func scope(argument: Any?, environment: String?, in workspaces: [Workspace]) -> Result<WorkspaceScope, WorkspaceError> {
        func match(_ text: String) -> Workspace? {
            workspaces.first { $0.id.caseInsensitiveCompare(text) == .orderedSame || $0.name.caseInsensitiveCompare(text) == .orderedSame }
        }
        if let text = (argument as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            if text.lowercased() == allChoice { return .success(.all) }
            guard let found = match(text) else { return .failure(.unknown(text, workspaces.map(\.id))) }
            return .success(WorkspaceScope(id: found.id, named: true))
        }
        if let environment, let found = match(environment) { return .success(WorkspaceScope(id: found.id)) }
        return .success(.all)
    }

    static func includes(_ id: String?, in scope: WorkspaceScope) -> Bool {
        scope.id == nil || scope.id == (id ?? defaultID)
    }

    static func filter(_ agents: [AgentState], in scope: WorkspaceScope) -> [AgentState] {
        agents.filter { includes($0.workspace, in: scope) }
    }

    static func filter(_ prs: [GitHubPR], in scope: WorkspaceScope, file: WorkspaceFile) -> [GitHubPR] {
        prs.filter { includes(assign(prSubject($0.url, override: file.overrides[$0.url]), in: file.workspaces), in: scope) }
    }

    static func filter(_ blocks: [ActivityBlock], in scope: WorkspaceScope, file: WorkspaceFile, home: String = NSHomeDirectory(),
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [ActivityBlock] {
        blocks.filter { block in
            let subject = Subject(folders: block.key.claude.map(\.folder), repo: block.key.repo, owner: block.key.owner, jiraKey: block.key.ticket)
            return includes(assign(subject, in: file.workspaces, home: home, exists: exists), in: scope)
        }
    }

    /// Why a prompt for an agent in `target` is refused: the calling Main's scope was not named and is another workspace.
    static func delegationProblem(target: String?, scope: WorkspaceScope, workspaces: [Workspace]) -> String? {
        guard let own = scope.id, !scope.named, own != (target ?? defaultID) else { return nil }
        let name = workspace(target, in: workspaces)?.name ?? target ?? defaultID
        return "That agent belongs to the \(name) workspace, not yours. Pass workspace: \u{201C}\(target ?? defaultID)\u{201D} only if the user named it."
    }

    // MARK: Migration

    /// The old single Main's session and folder moved under the default workspace; what is already saved there wins.
    static func migratedMain(sessions: [String: String], folders: [String: String], session: String?, folder: String?)
        -> (sessions: [String: String], folders: [String: String]) {
        var (sessions, folders) = (sessions, folders)
        if let session, sessions[defaultID] == nil { sessions[defaultID] = session }
        if let folder, folders[defaultID] == nil { folders[defaultID] = folder }
        return (sessions, folders)
    }

    /// A dictionary keyed by the old Main key, saved under the default workspace's Main key instead.
    static func renamedMain<Value>(_ dictionary: [String: Value]) -> [String: Value] {
        guard let old = dictionary[legacyMainKey] else { return dictionary }
        var renamed = dictionary
        renamed[legacyMainKey] = nil
        if renamed[mainKey(defaultID)] == nil { renamed[mainKey(defaultID)] = old }
        return renamed
    }

    // MARK: Main's prompt

    static func mainScope(_ workspace: Workspace, others: [Workspace]) -> String {
        let roots = workspace.roots.isEmpty ? "its working folder" : workspace.roots.joined(separator: ", ")
        var lines = ["You are Main for the \(workspace.name) workspace. Its repositories are under \(roots)"
                     + (workspace.githubOwners.isEmpty ? "" : " and its GitHub owner\(workspace.githubOwners.count == 1 ? " is" : "s are") "
                        + workspace.githubOwners.joined(separator: ", ")) + "."]
        lines.append(workspace.jiraProjects.isEmpty ? "It has no Jira projects." : "Its Jira projects are \(workspace.jiraProjects.joined(separator: ", ")).")
        lines.append(workspace.slack.map { "Its Slack workspace is \($0)." } ?? "Slack is not part of it; leave Slack alone unless the user asks.")
        lines.append("attention, agents_overview, github_needs_attention, agent_session, send_to_agent and resume_context show only this "
                     + "workspace unless you pass their workspace argument. Never use it, or delegate to another workspace's agents"
                     + (others.isEmpty ? "" : " (" + others.map(\.name).joined(separator: ", ") + ")") + ", unless the user names that workspace.")
        return lines.joined(separator: "\n")
    }
}

/// Main's own instructions: MAIN.md in the workspace's folder and the extra files its settings list, added to the prompt.
enum WorkspaceInstructions {
    static let limit = 20_000
    static let fileName = "MAIN.md"
    static let cutNote = "[Instructions cut here: they are limited to \(limit) characters.]"

    static func template(for workspace: Workspace) -> String {
        """
        # Main for \(workspace.name)

        ## Purpose
        What this workspace is for and what Main should help with.

        ## Catch up
        What to put first when I ask what to look at: reviews waiting on me, failing checks, agents waiting for permission, \
        messages that need an answer.

        ## Tone
        Short, direct, one line per item with the reason.

        ## Standing rules
        - Never post to Jira, Slack or GitHub without my approval; draft the text for me instead.
        - Do not change files or run commands that change anything unless I ask.
        """
    }

    /// The scope text, then MAIN.md, then each extra file that exists, all cut to `limit` characters after the scope.
    static func compose(scope: String, main: String?, extras: [(path: String, text: String?)], limit: Int = limit) -> String {
        var sections: [String] = []
        if let main = main?.trimmingCharacters(in: .whitespacesAndNewlines), !main.isEmpty {
            sections.append("The user's instructions for this workspace (\(fileName)):\n" + main)
        }
        for extra in extras {
            if let text = extra.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                sections.append("The user's instructions from \(extra.path):\n" + text)
            }
        }
        guard !sections.isEmpty else { return scope }
        var added = sections.joined(separator: "\n\n")
        if added.count > limit { added = String(added.prefix(limit)) + "\n" + cutNote }
        return scope + "\n\n" + added
    }

    /// Whether Main has instructions of its own: MAIN.md changed from the template, or an extra file that exists.
    static func isCustom(main: String?, template: String, extras: [(path: String, text: String?)]) -> Bool {
        let edited = main.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.map { !$0.isEmpty && $0 != template.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false
        return edited || extras.contains { $0.text != nil }
    }
}

/// MAIN.md and the extra files on disk, read each time a prompt is made so edits apply at once.
struct WorkspaceInstructionFiles: Sendable {
    var folder: URL = AppPaths.workspaceFolders
    var home = NSHomeDirectory()

    func url(for workspace: Workspace) -> URL {
        folder.appendingPathComponent(workspace.id, isDirectory: true).appendingPathComponent(WorkspaceInstructions.fileName)
    }

    /// The file, written from the template when it does not exist yet.
    @discardableResult
    func ensure(_ workspace: Workspace) -> URL {
        let url = url(for: workspace)
        if !FileManager.default.fileExists(atPath: url.path) { reset(workspace) }
        return url
    }

    func reset(_ workspace: Workspace) {
        let url = url(for: workspace)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(WorkspaceInstructions.template(for: workspace).utf8).write(to: url, options: .atomic)
    }

    func write(_ text: String, for workspace: Workspace) {
        let url = ensure(workspace)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    func read(_ workspace: Workspace) -> String? {
        try? String(contentsOf: ensure(workspace), encoding: .utf8)
    }

    func extras(_ workspace: Workspace) -> [(path: String, text: String?)] {
        workspace.extraFiles.map { path in
            (path, try? String(contentsOfFile: Workspaces.expand(path, home: home), encoding: .utf8))
        }
    }

    func prompt(for workspace: Workspace, others: [Workspace]) -> String {
        WorkspaceInstructions.compose(scope: AgentLogic.mainSystemPrompt(workspace: workspace, others: others), main: read(workspace),
                                      extras: extras(workspace))
    }

    func isCustom(_ workspace: Workspace) -> Bool {
        WorkspaceInstructions.isCustom(main: read(workspace), template: WorkspaceInstructions.template(for: workspace), extras: extras(workspace))
    }
}
