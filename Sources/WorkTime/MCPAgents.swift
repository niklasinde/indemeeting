import Foundation

/// The agent tools of the MCP server: the overview the app writes, session transcripts, what needs the user across the
/// sources the `--mcp` process can read on its own, and handing a prompt to a pull request's agent in the running app.
extension MCPServer {
    /// The workspaces the app saved and the one the calling Main belongs to (`WORKTIME_WORKSPACE`), which tools default to.
    struct WorkspaceSource {
        var file: () -> WorkspaceFile = { Workspaces.decode(try? Data(contentsOf: AppPaths.workspaceFile)) }
        var environment: () -> String? = { ProcessInfo.processInfo.environment[Workspaces.envKey] }

        func scope(_ args: [String: Any]) throws -> WorkspaceScope {
            switch Workspaces.scope(argument: args["workspace"], environment: environment(), in: file().workspaces) {
            case .success(let scope): return scope
            case .failure(let error): throw MCPToolError(error.message)
            }
        }
    }

    static let workspaceProperty: [String: Any] = [
        "type": "string",
        "description": "A workspace id or name, or all. Left out, the calling Main's own workspace, or all outside a Main.",
    ]

    struct AgentSources {
        var stateFile = AppPaths.agentState
        var inbox = AppPaths.agentInbox
        var projects = ClaudeTranscripts.projectsFolder
        var topics = AppPaths.topicAgents
        var assistants = AssistantFiles()
        var workspaces = WorkspaceSource()
        var notices = NoticeSources()
        var replyTimeout: TimeInterval = 10
        /// Slack mentions and unread DMs as Markdown, nil when Slack is not signed in.
        var slack: () -> String? = { MCPServer.slackAttention() }

        func agents() -> [AgentState] { (try? Data(contentsOf: stateFile)).flatMap(AgentOverview.decode)?.agents ?? [] }

        func assistantEntries(_ args: [String: Any]) throws -> [AssistantEntry] {
            let scope = try workspaces.scope(args)
            return workspaces.file().workspaces.filter { Workspaces.includes($0.id, in: scope) }.flatMap { workspace in
                assistants.list(workspace.id).map { AssistantEntry(workspace: workspace.id, role: $0) }
            }
        }

        /// The agent `agent` or `pr_url` names: an assistant, a pull request or a topic, nil when neither is given.
        func target(_ args: [String: Any]) throws -> AgentTarget? {
            guard let text = [args["agent"], args["pr_url"]].compactMap({ $0 as? String })
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            switch Assistants.resolve(text, in: try assistantEntries(args)) {
            case .success(let target)?: return target
            case .failure(let error)?: throw MCPToolError(error.message)
            case nil: break
            }
            switch TopicAgents.resolve(text, topics: TopicAgents.decode(try? Data(contentsOf: topics))) {
            case .success(let target): return target
            case .failure(let error): throw MCPToolError(error.message)
            }
        }

        func workspace(of target: AgentTarget, in agents: [AgentState]) -> String? {
            if let id = Assistants.parse(key: target.key)?.workspace { return id }
            if let state = agents.first(where: { $0.key == target.key }) { return state.workspace }
            let saved = workspaces.file()
            return GitHubLink.pullRequest(at: target.key) != nil
                ? Workspaces.assign(Workspaces.prSubject(target.key, override: saved.overrides[target.key]), in: saved.workspaces) : nil
        }

        func checkDelegation(_ target: AgentTarget, args: [String: Any], agents: [AgentState]) throws {
            let scope = try workspaces.scope(args)
            if let problem = Workspaces.delegationProblem(target: workspace(of: target, in: agents), scope: scope,
                                                         workspaces: workspaces.file().workspaces) {
                throw MCPToolError(problem)
            }
        }

        /// The agent a Main of `workspace` would send to with these arguments, as send_to_agent resolves it; nil when it is
        /// unclear, belongs to another workspace or the call names a workspace itself.
        func delegation(_ args: [String: Any], from workspace: String) -> AgentTarget? {
            var sources = self
            sources.workspaces.environment = { workspace }
            guard (args["workspace"] as? String)?.trimmingCharacters(in: .whitespaces).isEmpty ?? true,
                  let target = try? sources.target(args), (try? sources.checkDelegation(target, args: args, agents: sources.agents())) != nil else { return nil }
            return GitHubLink.pullRequest(at: target.key).map { AgentTarget(key: $0.url, title: target.title) } ?? target
        }
    }

    static let attentionSections = ["pull_requests", "agents", "notifications", "slack", "meetings"]

    static let agentProperty: [String: Any] = ["type": "string",
                                               "description": "A pull request url, a topic agent's key (topic:<id>) or name, or an assistant's role name or key, as agents_overview lists them."]

    static func agentTools(_ opened: Result<MeetingStore, Error>, sources: AgentSources = AgentSources(),
                           github: [MCPTool] = [], now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func stateFile() throws -> AgentOverview.File {
            guard let data = try? Data(contentsOf: sources.stateFile) else {
                throw MCPToolError("WorkTime has not written its agents yet (\(sources.stateFile.path)). Open WorkTime.")
            }
            guard let file = AgentOverview.decode(data) else { throw MCPToolError("\(sources.stateFile.path) could not be read.") }
            return file
        }
        func scoped(_ args: [String: Any]) throws -> (scope: WorkspaceScope, file: AgentOverview.File) {
            var file = try stateFile()
            let scope = try sources.workspaces.scope(args)
            file.agents = Workspaces.filter(file.agents, in: scope)
            return (scope, file)
        }
        return [
            MCPTool(name: "agents_overview",
                    description: "Every Claude agent WorkTime knows (Main, its assistants, one per pull request and the topic agents), most urgent first: waiting for the "
                        + "user's permission (with the tool it asks for), finished with a result the user has not seen, errored, working, "
                        + "idle. Each with its pull request url, worktime://agent link, folder, session id, last prompt and last result.",
                    properties: ["active_only": ["type": "boolean", "description": "Leave out idle agents. False when left out."],
                                 "workspace": workspaceProperty].merging(AgentFilter.properties) { $1 }) { args in
                let filter = try AgentFilter(args)
                var file = try scoped(args).file
                file.agents = file.agents.filter(filter.matches)
                return FilterLogic.header(filter.applied) + AgentOverview.markdown(file, now: now(), active: args["active_only"] as? Bool ?? false)
            },
            MCPTool(name: "agent_session",
                    description: "A compact transcript of one agent's Claude Code session: the user's prompts, the assistant's replies, "
                        + "tool calls in one line each and the final result, without thinking or tool output. Newest kept when cut.",
                    properties: ["agent": agentProperty,
                                 "pr_url": ["type": "string", "description": "The pull request whose agent to read; the same as agent."],
                                 "workspace": workspaceProperty,
                                 "session_id": ["type": "string", "description": "A session id from agents_overview, instead of agent."],
                                 "max_chars": ["type": "integer", "minimum": 1000, "maximum": outputLimit,
                                               "description": "Keep at most this many characters, \(AgentTranscript.defaultLimit) when left out."]]) { args in
                var session = (args["session_id"] as? String)?.trimmingCharacters(in: .whitespaces)
                var cwd: String?
                let agents = (try? stateFile())?.agents ?? []
                if let target = try sources.target(args) {
                    guard let agent = agents.first(where: { $0.key == target.key }) else {
                        throw MCPToolError("No agent for \(target.title) in agents_overview.")
                    }
                    try sources.checkDelegation(target, args: args, agents: agents)
                    guard let id = agent.sessionID else { throw MCPToolError("The agent \(target.title) has no session yet.") }
                    session = id
                    cwd = agent.folder
                } else if let id = session {
                    cwd = agents.first { $0.sessionID == id }?.folder
                }
                guard let session, !session.isEmpty else { throw MCPToolError("agent or session_id is required.") }
                guard let url = AgentTranscript.url(sessionID: session, cwd: cwd, root: sources.projects),
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    throw MCPToolError("No transcript for session \(session).")
                }
                let limit = min(max(Int(number(args["max_chars"]) ?? Double(AgentTranscript.defaultLimit)), 1000), outputLimit)
                return "Session \(session)\n\n" + AgentTranscript.compact(jsonl: text, maxChars: limit)
            },
            MCPTool(name: "attention",
                    description: "What needs the user right now, in one place: pull requests waiting on them, agents waiting for permission "
                        + "or with unseen results, Slack mentions they have not answered, read or dismissed and unread DMs (when signed in), and open action items from the last "
                        + "two weeks of meetings. Start here for \u{201C}what do I need to look at\u{201D}. Optional filters: section "
                        + "limits it to one of those parts, kind and status narrow its agents; the answer says which applied.",
                    properties: ["workspace": workspaceProperty,
                                 "section": ["type": "string", "enum": attentionSections, "description": "Only this part."],
                                 "kind": AgentFilter.properties["kind"]!, "status": AgentFilter.properties["status"]!]) { args in
                let scope = try sources.workspaces.scope(args)
                let workspaces = sources.workspaces.file().workspaces
                let only = try FilterLogic.choice(args, "section", allowed: attentionSections)
                let filter = try AgentFilter(args, names: ["kind", "status"])
                func wanted(_ section: String) -> Bool { only == nil || only == section }
                var sections: [String] = []
                if wanted("pull_requests"), let tool = github.first(where: { $0.name == "github_needs_attention" }) {
                    sections.append("## Pull requests\n" + ((try? tool.run(["limit": 8, "workspace": scope.id ?? Workspaces.allChoice]))
                                                            ?? "The GitHub cache could not be read.\n"))
                }
                if wanted("agents") {
                    sections.append("## Agents\n" + ((try? scoped(args).file).map { file in
                        var file = file
                        file.agents = file.agents.filter(filter.matches)
                        return AgentOverview.markdown(file, now: now(), active: true, limit: 10)
                    } ?? "WorkTime has not written its agents yet.\n"))
                }
                if wanted("notifications"), let notices = noticeAttention(sources.notices) { sections.append("## Notifications from agents\n" + notices) }
                if wanted("slack"), scope.id == nil || Workspaces.workspace(scope.id, in: workspaces)?.slack != nil, let slack = sources.slack() {
                    sections.append("## Slack\n" + slack)
                }
                if wanted("meetings"), let items = try? openedStore(opened).openActionItems(limit: 10, since: TodoLogic.meetingCutoff(now: now())) {
                    sections.append("## Meeting action items (not tied to a workspace)\n" + (items.isEmpty ? "None open.\n" : items.map {
                        "- \(ActivityLogic.dateText($0.date)) \u{00B7} \($0.title) (meeting id \($0.meeting)) \u{00B7} "
                            + ($0.owner.map { "\($0): " } ?? "") + $0.task
                    }.joined(separator: "\n") + "\n"))
                }
                return cut(FilterLogic.header(FilterLogic.applied(["section": only]) + filter.applied) + sections.joined(separator: "\n"), at: outputLimit)
            },
            MCPTool(name: "send_to_agent",
                    description: "Sends a prompt to an agent in WorkTime, marked as from Main: a pull request's agent, a topic agent "
                        + "(a support case or other topic, by its key or name) or one of the workspace's assistants (by role name, like Developer). It starts when the agent is idle "
                        + "and queues while it works; it is refused while the agent waits for a permission. The agent asks the user in its "
                        + "own pane for anything it wants to run. Returns the session id to read the outcome with agent_session later.",
                    properties: ["agent": agentProperty,
                                 "pr_url": ["type": "string", "description": "A pull request's GitHub url; the same as agent."],
                                 "workspace": workspaceProperty,
                                 "text": ["type": "string", "maxLength": AgentInbox.textLimit, "description": "The prompt for that agent."]],
                    required: ["text"], readOnly: false) { args in
                guard let target = try sources.target(args) else { throw MCPToolError("agent is required.") }
                try sources.checkDelegation(target, args: args, agents: sources.agents())
                let request: AgentInbox.Request
                switch AgentInbox.request(agent: target.key, text: args["text"] as? String ?? "", now: now()) {
                case .success(let made): request = made
                case .failure(let error): throw MCPToolError(error.message)
                }
                let reply = try deliver(request, inbox: sources.inbox, timeout: sources.replyTimeout)
                if reply.status == .rejected { throw MCPToolError(AgentInbox.replyText(reply, title: target.title)) }
                return AgentInbox.replyText(reply, title: target.title)
            },
        ]
    }

    /// Writes the request where the app looks and waits for its answer.
    static func deliver(_ request: AgentInbox.Request, inbox: URL, timeout: TimeInterval) throws -> AgentInbox.Reply {
        try exchange(AgentInbox.encode(request), id: request.id, name: AgentInbox.requestName(request.id), inbox: inbox, timeout: timeout,
                     what: "the prompt")
    }

    /// Leaves `data` in the inbox under `name` and waits for the app's reply file with the same id.
    static func exchange<Reply: Decodable>(_ data: Data, id: String, name: String, inbox: URL, timeout: TimeInterval, what: String) throws -> Reply {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let requestURL = inbox.appendingPathComponent(name)
        let replyURL = inbox.appendingPathComponent(AgentInbox.replyName(id))
        do { try data.write(to: requestURL, options: .atomic) } catch {
            throw MCPToolError("Could not hand \(what) to WorkTime: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: replyURL), let reply = AgentInbox.decode(Reply.self, from: data) {
                try? fileManager.removeItem(at: replyURL)
                return reply
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? fileManager.removeItem(at: requestURL)
        throw MCPToolError("WorkTime did not take \(what) within \(Int(timeout)) seconds. Is the app running?")
    }

    /// Slack mentions still needing the user and unread DMs, with the token the app saved, read without renewing it; nil when Slack is not set up.
    static func slackAttention(secrets: URL = AppPaths.secrets, now: Date = Date()) -> String? {
        let store = FileSecretStore(folder: secrets, name: TokenStore.slackService)
        guard let stored = store.key(for: TokenStore.slack.account).flatMap({ String(data: $0, encoding: .utf8) }),
              let auth = SlackAuth(stored: stored) else { return nil }
        if SlackLogic.needsRefresh(auth, now: now) { return "The Slack sign-in needs renewing; open the Slack panel in WorkTime.\n" }
        let client = SlackClient(token: auth.accessToken)
        let marks = SlackLogic.marks(CFPreferencesCopyAppValue(SlackLogic.marksKey as CFString, appDomain as CFString), now: now)
        let fetched = blocking(timeout: 25) { () async throws -> String in
            let me = try await client.identity()
            let mentions = await client.annotate(try await client.mentions(of: me, now: now), me: me.userID, marks: marks).mentions
                .filter { $0.handled == nil }
            let direct = try await client.directMessages(of: me, names: [:], now: now)
            var names = direct.names
            let wanted = Set((mentions + direct.messages).flatMap { SlackLogic.mentionedUsers(in: $0.text) + [$0.author].compactMap { $0 } })
            for id in wanted.filter({ names[$0] == nil }).prefix(20) { names[id] = try? await client.userName(id) }
            let messages = SlackLogic.merged(mentions: mentions, direct: direct.messages).prefix(10)
            guard !messages.isEmpty else { return "No mentions or unread DMs.\n" }
            return messages.map { message in
                let who = message.author.map { names[$0] ?? $0 } ?? "someone"
                let kind = message.kind == .direct ? "DM" + (message.unread.map { " (\($0) unread)" } ?? "") : "mention in \(message.place)"
                let link = SlackLogic.webLink(message, workspace: me.url).map { "\n  \($0.absoluteString)" } ?? ""
                return "- \(kind) from \(who), \(GitHubLogic.updatedText(message.date, now: now)): "
                    + AgentOverview.oneLine(ActivityLogic.truncate(SlackLogic.clean(message.text, names: names), to: 200)) + link
            }.joined(separator: "\n") + "\n"
        }
        switch fetched {
        case .success(let text): return text
        case .failure(let error): return "Slack could not be read: \(SlackError.from(error).message)\n"
        case nil: return "Slack did not answer in time.\n"
        }
    }

    /// Runs async work from the synchronous tool handlers; nil when it takes longer than `timeout`.
    static func blocking(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> String) -> Result<String, Error>? {
        let box = ResultBox(), done = DispatchSemaphore(value: 0)
        let task = Task {
            do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            return nil
        }
        return box.value
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<String, Error>?
}
