import Foundation

/// The agent tools of the MCP server: the overview the app writes, session transcripts, what needs the user across the
/// sources the `--mcp` process can read on its own, and handing a prompt to a pull request's agent in the running app.
extension MCPServer {
    struct AgentSources {
        var stateFile = AppPaths.agentState
        var inbox = AppPaths.agentInbox
        var projects = ClaudeTranscripts.projectsFolder
        var topics = AppPaths.topicAgents
        var replyTimeout: TimeInterval = 10
        /// Slack mentions and unread DMs as Markdown, nil when Slack is not signed in.
        var slack: () -> String? = { MCPServer.slackAttention() }
    }

    static let agentProperty: [String: Any] = ["type": "string",
                                               "description": "A pull request url, or a topic agent's key (topic:<id>) or name, as agents_overview lists them."]

    static func agentTools(_ opened: Result<MeetingStore, Error>, sources: AgentSources = AgentSources(),
                           github: [MCPTool] = [], now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func stateFile() throws -> AgentOverview.File {
            guard let data = try? Data(contentsOf: sources.stateFile) else {
                throw MCPToolError("WorkTime has not written its agents yet (\(sources.stateFile.path)). Open WorkTime.")
            }
            guard let file = AgentOverview.decode(data) else { throw MCPToolError("\(sources.stateFile.path) could not be read.") }
            return file
        }
        func target(_ args: [String: Any]) throws -> AgentTarget? {
            guard let text = [args["agent"], args["pr_url"]].compactMap({ $0 as? String })
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            switch TopicAgents.resolve(text, topics: TopicAgents.decode(try? Data(contentsOf: sources.topics))) {
            case .success(let target): return target
            case .failure(let error): throw MCPToolError(error.message)
            }
        }
        return [
            MCPTool(name: "agents_overview",
                    description: "Every Claude agent WorkTime knows (Main, one per pull request and the topic agents), most urgent first: waiting for the "
                        + "user's permission (with the tool it asks for), finished with a result the user has not seen, errored, working, "
                        + "idle. Each with its pull request url, worktime://agent link, folder, session id, last prompt and last result.",
                    properties: ["active_only": ["type": "boolean", "description": "Leave out idle agents. False when left out."]]) {
                AgentOverview.markdown(try stateFile(), now: now(), active: $0["active_only"] as? Bool ?? false)
            },
            MCPTool(name: "agent_session",
                    description: "A compact transcript of one agent's Claude Code session: the user's prompts, the assistant's replies, "
                        + "tool calls in one line each and the final result, without thinking or tool output. Newest kept when cut.",
                    properties: ["agent": agentProperty,
                                 "pr_url": ["type": "string", "description": "The pull request whose agent to read; the same as agent."],
                                 "session_id": ["type": "string", "description": "A session id from agents_overview, instead of agent."],
                                 "max_chars": ["type": "integer", "minimum": 1000, "maximum": outputLimit,
                                               "description": "Keep at most this many characters, \(AgentTranscript.defaultLimit) when left out."]]) { args in
                var session = (args["session_id"] as? String)?.trimmingCharacters(in: .whitespaces)
                var cwd: String?
                let agents = (try? stateFile())?.agents ?? []
                if let target = try target(args) {
                    guard let agent = agents.first(where: { $0.key == target.key }) else {
                        throw MCPToolError("No agent for \(target.title) in agents_overview.")
                    }
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
                        + "or with unseen results, Slack mentions and unread DMs (when signed in), and open action items from the last "
                        + "two weeks of meetings. Start here for \u{201C}what do I need to look at\u{201D}.",
                    properties: [:]) { _ in
                var sections: [String] = []
                if let tool = github.first(where: { $0.name == "github_needs_attention" }) {
                    sections.append("## Pull requests\n" + ((try? tool.run(["limit": 8])) ?? "The GitHub cache could not be read.\n"))
                }
                sections.append("## Agents\n" + ((try? AgentOverview.markdown(stateFile(), now: now(), active: true, limit: 10))
                                                  ?? "WorkTime has not written its agents yet.\n"))
                if let slack = sources.slack() { sections.append("## Slack\n" + slack) }
                if let items = try? openedStore(opened).openActionItems(limit: 10, since: TodoLogic.meetingCutoff(now: now())) {
                    sections.append("## Meeting action items\n" + (items.isEmpty ? "None open.\n" : items.map {
                        "- \(ActivityLogic.dateText($0.date)) \u{00B7} \($0.title) (meeting id \($0.meeting)) \u{00B7} "
                            + ($0.owner.map { "\($0): " } ?? "") + $0.task
                    }.joined(separator: "\n") + "\n"))
                }
                return cut(sections.joined(separator: "\n"), at: outputLimit)
            },
            MCPTool(name: "send_to_agent",
                    description: "Sends a prompt to an agent in WorkTime, marked as from Main: a pull request's agent, or a topic agent "
                        + "(a support case or other topic, by its key or name). It starts when the agent is idle "
                        + "and queues while it works; it is refused while the agent waits for a permission. The agent asks the user in its "
                        + "own pane for anything it wants to run. Returns the session id to read the outcome with agent_session later.",
                    properties: ["agent": agentProperty,
                                 "pr_url": ["type": "string", "description": "A pull request's GitHub url; the same as agent."],
                                 "text": ["type": "string", "maxLength": AgentInbox.textLimit, "description": "The prompt for that agent."]],
                    required: ["text"], readOnly: false) { args in
                guard let target = try target(args) else { throw MCPToolError("agent is required.") }
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
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let requestURL = inbox.appendingPathComponent(AgentInbox.requestName(request.id))
        let replyURL = inbox.appendingPathComponent(AgentInbox.replyName(request.id))
        do { try AgentInbox.encode(request).write(to: requestURL, options: .atomic) } catch {
            throw MCPToolError("Could not hand the prompt to WorkTime: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: replyURL), let reply = AgentInbox.decode(AgentInbox.Reply.self, from: data) {
                try? fileManager.removeItem(at: replyURL)
                return reply
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? fileManager.removeItem(at: requestURL)
        throw MCPToolError("WorkTime did not take the prompt within \(Int(timeout)) seconds. Is the app running?")
    }

    /// Slack mentions and unread DMs with the token the app saved, read without renewing it; nil when Slack is not set up.
    static func slackAttention(secrets: URL = AppPaths.secrets, now: Date = Date()) -> String? {
        let store = FileSecretStore(folder: secrets, name: TokenStore.slackService)
        guard let stored = store.key(for: TokenStore.slack.account).flatMap({ String(data: $0, encoding: .utf8) }),
              let auth = SlackAuth(stored: stored) else { return nil }
        if SlackLogic.needsRefresh(auth, now: now) { return "The Slack sign-in needs renewing; open the Slack panel in WorkTime.\n" }
        let client = SlackClient(token: auth.accessToken)
        let fetched = blocking(timeout: 15) { () async throws -> String in
            let me = try await client.identity()
            let mentions = try await client.mentions(of: me, now: now)
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
