import Foundation

/// One agent as the app last saw it, written to `agents.json` for the MCP server.
struct AgentState: Codable, Equatable {
    enum Status: String, Codable {
        case idle, working, waiting, error
        case signedOut = "signed_out"
    }

    var key: String
    var title: String
    var prURL: String?
    var folder: String?
    var sessionID: String?
    var status: Status
    var pendingTool: String?
    var pendingInput: String?
    var lastPrompt: String?
    var lastResult: String?
    var error: String?
    var updatedAt: Date?
    var seen = true
    /// Whether the agent is loaded in this run of the app; persisted sessions that are not have only their id.
    var loaded = true
    var queued = 0
    /// A topic agent's links.
    var jiraKey: String?
    var slackURL: String?

    var isTopic: Bool { TopicAgents.isKey(key) }

    /// A topic agent as it stands: its loaded model's state, or its saved session.
    static func topic(_ topic: TopicAgent, loaded: AgentState?, sessionID: String?) -> AgentState {
        var state = loaded ?? AgentState(key: topic.key, title: topic.name, folder: topic.folder, sessionID: sessionID, status: .idle, loaded: false)
        state.jiraKey = topic.jiraKey
        state.slackURL = topic.slackURL
        return state
    }
}

/// The agents' state file shared with the `--mcp` process, and the overview the MCP tools make of it.
enum AgentOverview {
    static let fileName = "agents.json"
    static let mainKey = "main"
    static let promptLimit = 300
    static let resultLimit = 1500

    struct File: Codable, Equatable {
        var written: Date
        var agents: [AgentState]
    }

    /// What an agent's transcript says about it: the pending permission, the last prompt and the reply that followed it.
    static func snapshot(key: String, title: String, prURL: String?, folder: String, sessionID: String?, items: [AgentItem],
                         busy: Bool, seen: Bool, updatedAt: Date?, queued: Int = 0) -> AgentState {
        var state = AgentState(key: key, title: title, prURL: prURL, folder: folder, sessionID: sessionID, status: busy ? .working : .idle,
                               updatedAt: updatedAt, seen: seen, queued: queued)
        let lastUser = items.lastIndex { if case .user = $0.kind { true } else { false } }
        if let lastUser, case .user(let text) = items[lastUser].kind { state.lastPrompt = ActivityLogic.truncate(text, to: promptLimit) }
        let reply = items[(lastUser.map { $0 + 1 } ?? 0)...].compactMap { item -> String? in
            if case .text(let text) = item.kind { return text }
            return nil
        }
        if let last = reply.last { state.lastResult = ActivityLogic.truncate(last, to: resultLimit) }
        if busy, let pending = items.last(where: { if case .permission(_, _, _, _, nil) = $0.kind { true } else { false } }),
           case .permission(let tool, let summary, _, _, _) = pending.kind {
            state.status = .waiting
            state.pendingTool = tool
            state.pendingInput = summary
        } else if !busy, let last = items.last {
            switch last.kind {
            case .signIn: state.status = .signedOut
            case .error(let text):
                state.status = .error
                state.error = ActivityLogic.truncate(text, to: promptLimit)
            default: break
            }
        }
        return state
    }

    /// The loaded agents, then every pull request with a saved session or session history that is not loaded this run.
    static func withPersisted(_ agents: [AgentState], sessions: [String: String], known: [String] = []) -> [AgentState] {
        let loaded = Set(agents.compactMap(\.prURL))
        let urls = Set(sessions.keys).union(known).filter { GitHubLink.pullRequest(at: $0) != nil }
        return agents + urls.sorted().filter { !loaded.contains($0) }.map { url in
            AgentState(key: url, title: prTitle(url), prURL: url, sessionID: sessions[url], status: .idle, loaded: false)
        }
    }

    static func prTitle(_ url: String, title: String? = nil) -> String {
        let reference = GitHubLink.pullRequest(at: url).map { "\($0.repo)#\($0.number)" } ?? url
        return title.map { "\(reference) \($0)" } ?? reference
    }

    static func encode(_ agents: [AgentState], now: Date) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(File(written: now, agents: agents))) ?? Data()
    }

    static func decode(_ data: Data) -> File? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(File.self, from: data)
    }

    enum Need: Int, Comparable {
        case waiting, unseen, error, working, idle

        static func < (lhs: Need, rhs: Need) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .waiting: return "Waiting for your permission"
            case .unseen: return "Finished, not seen yet"
            case .error: return "Stopped with an error"
            case .working: return "Working"
            case .idle: return "Idle"
            }
        }
    }

    static func need(_ state: AgentState) -> Need {
        switch state.status {
        case .waiting: return .waiting
        case .working: return .working
        case .error, .signedOut: return .error
        case .idle: return !state.seen && state.lastResult != nil ? .unseen : .idle
        }
    }

    /// Most urgent first, then newest first.
    static func sorted(_ agents: [AgentState]) -> [AgentState] {
        agents.sorted { lhs, rhs in
            let (left, right) = (need(lhs), need(rhs))
            if left != right { return left < right }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }

    /// The agents as Markdown; `active` leaves out the idle ones and Main itself, for the attention summary.
    static func markdown(_ file: File, now: Date, active: Bool = false, limit: Int = 30) -> String {
        let agents = sorted(file.agents).filter { !active || (need($0) != .idle && $0.key != mainKey) }
        guard !agents.isEmpty else { return active ? "No agent needs you.\n" : "No agents yet.\n" }
        let header = "\(agents.count) agent\(agents.count == 1 ? "" : "s"), state written \(GitHubLogic.updatedText(file.written, now: now))\n"
        return header + agents.prefix(limit).map { line($0, now: now) }.joined()
    }

    static func line(_ state: AgentState, now: Date) -> String {
        let need = need(state)
        var facts = [state.status == .signedOut ? "Signed out of Claude" : need.label]
        if let tool = state.pendingTool { facts.append("asks to run \(AgentLogic.displayName(tool))" + (state.pendingInput.map { ": \($0)" } ?? "")) }
        if state.queued > 0 { facts.append("\(state.queued) queued") }
        if let updated = state.updatedAt { facts.append("updated \(GitHubLogic.updatedText(updated, now: now))") }
        if !state.loaded { facts.append("saved session, not open") }
        var lines = ["- **\(state.title)** \u{00B7} " + facts.joined(separator: " \u{00B7} ")]
        if let url = state.prURL { lines.append("  \(url) \u{00B7} agent: \(GitHubLink.agentLink(for: url))") }
        if state.isTopic {
            lines.append("  topic agent \(state.key)" + [state.jiraKey.map { "Jira \($0)" }, state.slackURL.map { "Slack \($0)" }]
                .compactMap { $0 }.map { " \u{00B7} " + $0 }.joined())
        }
        if let folder = state.folder { lines.append("  folder: \(folder)") }
        if let session = state.sessionID { lines.append("  session: \(session)") }
        if let error = state.error { lines.append("  error: \(oneLine(error))") }
        if let prompt = state.lastPrompt { lines.append("  last prompt: \(oneLine(prompt))") }
        if let result = state.lastResult, need != .idle || state.loaded {
            lines.append("  last result: \(oneLine(ActivityLogic.truncate(result, to: 400)))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
    }
}

/// A Claude Code session transcript (`~/.claude/projects/<folder>/<id>.jsonl`) cut down to prompts, replies and tool calls.
enum AgentTranscript {
    static let defaultLimit = 12_000
    static let entryLimit = 3000

    /// The transcript of `sessionID`: in the folder `cwd` maps to when that is known, else in whichever project folder holds it.
    static func url(sessionID: String, cwd: String?, root: URL = ClaudeTranscripts.projectsFolder,
                    fileManager: FileManager = .default) -> URL? {
        guard ClaudeTranscripts.isSessionID(sessionID) else { return nil }
        if let cwd, let url = ClaudeTranscripts.transcript(id: sessionID, cwd: cwd, root: root), fileManager.fileExists(atPath: url.path) {
            return url
        }
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent(sessionID + ".jsonl") }.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// One line of a transcript that the Agent shows: a prompt, a reply, a tool call or its output. Sidechains, meta lines and
    /// command wrappers are left out.
    enum Line {
        case user(String)
        case assistant(String)
        case toolUse(id: String, name: String, input: [String: Any], cwd: String)
        case toolResult(id: String, content: String, isError: Bool)
    }

    static func lines(jsonl: String) -> [Line] {
        var lines: [Line] = []
        for raw in jsonl.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { continue }
            let cwd = object["cwd"] as? String ?? ""
            let blocks: [[String: Any]]
            if let text = message["content"] as? String {
                blocks = [["type": "text", "text": text]]
            } else {
                blocks = message["content"] as? [[String: Any]] ?? []
            }
            let role = object["type"] as? String
            guard role == "user" || role == "assistant" else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                          role == "assistant" || !text.hasPrefix("<") else { continue }
                    lines.append(role == "user" ? .user(text) : .assistant(text))
                case "tool_use" where role == "assistant":
                    lines.append(.toolUse(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "tool",
                                          input: block["input"] as? [String: Any] ?? [:], cwd: cwd))
                case "tool_result" where role == "user":
                    lines.append(.toolResult(id: block["tool_use_id"] as? String ?? "", content: resultText(block["content"]),
                                             isError: block["is_error"] as? Bool ?? false))
                default: break
                }
            }
        }
        return lines
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let parts = content as? [[String: Any]] ?? []
        return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    static func entries(jsonl: String) -> [String] {
        var entries: [String] = lines(jsonl: jsonl).compactMap { line in
            switch line {
            case .user(let text): return "User: " + ActivityLogic.truncate(text, to: entryLimit)
            case .assistant(let text): return "Assistant: " + ActivityLogic.truncate(text, to: entryLimit)
            case .toolUse(_, let tool, let input, let cwd):
                let summary = AgentLogic.summary(tool: tool, input: input, cwd: cwd)
                return "Tool: \(AgentLogic.displayName(tool))" + (summary.isEmpty ? "" : " \u{2014} \(summary)")
            case .toolResult: return nil
            }
        }
        if let last = entries.last, last.hasPrefix("Assistant: ") {
            entries[entries.count - 1] = "Result: " + last.dropFirst("Assistant: ".count)
        }
        return entries
    }

    /// The transcript as the Agent shows it, for a session continued after a restart or picked from the session list.
    static func items(jsonl: String, cwd: String, resultLimit: Int = 10_000) -> [AgentItem] {
        var items: [AgentItem] = []
        for line in lines(jsonl: jsonl) {
            switch line {
            case .user(let text): items.append(AgentItem(id: "user-\(items.count)", kind: .user(text)))
            case .assistant(let text): AgentLogic.apply(.text(text), to: &items)
            case .toolUse(let id, let tool, let input, let lineCwd):
                AgentLogic.apply(.toolUse(id: id, tool: tool, summary: AgentLogic.summary(tool: tool, input: input, cwd: lineCwd.isEmpty ? cwd : lineCwd),
                                          detail: AgentLogic.detail(tool: tool, input: input)), to: &items)
            case .toolResult(let id, let content, let isError):
                AgentLogic.apply(.toolResult(id: id, content: ActivityLogic.truncate(content, to: resultLimit), isError: isError, auto: false), to: &items)
            }
        }
        return items
    }

    /// The entries, newest kept: earlier ones are dropped until the text fits in `maxChars`.
    static func compact(jsonl: String, maxChars: Int = defaultLimit) -> String {
        let all = entries(jsonl: jsonl)
        guard !all.isEmpty else { return "The session has no prompts or replies yet.\n" }
        var kept: [String] = [], size = 0
        for entry in all.reversed() {
            guard size + entry.count + 2 <= maxChars || kept.isEmpty else { break }
            kept.insert(entry, at: 0)
            size += entry.count + 2
        }
        let cut = all.count - kept.count
        let text = kept.joined(separator: "\n\n")
        return (cut > 0 ? "[\(cut) earlier entr\(cut == 1 ? "y" : "ies") cut]\n\n" : "") + (text.count > maxChars ? String(text.suffix(maxChars)) : text) + "\n"
    }
}

/// Prompts Main hands to a pull request's agent: written by the `--mcp` process into a folder the app watches, and answered
/// with a reply file beside it.
enum AgentInbox {
    static let textLimit = 4000
    static let queueLimit = 5
    static let staleAfter: TimeInterval = 60
    static let prefix = "From Main: "

    struct Request: Codable, Equatable {
        var id: String
        /// A pull request url or a topic agent's key.
        var agent: String
        var text: String
        var created: Date
    }

    struct Reply: Codable, Equatable {
        enum Status: String, Codable { case started, queued, rejected }
        var id: String
        var status: Status
        var sessionID: String?
        var message: String
    }

    enum Decision: Equatable {
        case start, queue, reject(String)
    }

    static func requestName(_ id: String) -> String { "\(id).request.json" }
    static func replyName(_ id: String) -> String { "\(id).reply.json" }

    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".request.json") }

    /// A request for an agent (a pull request url or a topic key) and some text, or why there can be none.
    static func request(agent: String, text: String, now: Date, id: String = UUID().uuidString) -> Result<Request, AgentInboxError> {
        let request = Request(id: id, agent: agent.trimmingCharacters(in: .whitespaces), text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                              created: now)
        return problem(request, now: now).map { .failure($0) } ?? .success(request)
    }

    static func problem(_ request: Request, now: Date) -> AgentInboxError? {
        guard ClaudeTranscripts.isSessionID(request.id) else { return AgentInboxError("The request id is not a UUID.") }
        guard GitHubLink.pullRequest(at: request.agent) != nil || TopicAgents.isKey(request.agent) else {
            return AgentInboxError("agent must be a GitHub pull request url or a topic agent key, not \(request.agent).")
        }
        guard !request.text.isEmpty else { return AgentInboxError("text is empty.") }
        guard request.text.count <= textLimit else { return AgentInboxError("text is \(request.text.count) characters; the limit is \(textLimit).") }
        guard abs(now.timeIntervalSince(request.created)) <= staleAfter else { return AgentInboxError("The request is too old.") }
        return nil
    }

    /// Starts now when the agent is idle, waits its turn while it works, and is turned away while it waits for a permission.
    static func decide(busy: Bool, waitingForPermission: Bool, queued: Int) -> Decision {
        if waitingForPermission { return .reject("The agent is waiting for the user to answer a permission prompt in its pane; nothing was sent.") }
        if queued >= queueLimit { return .reject("\(queued) messages are already queued for this agent; nothing was sent.") }
        return busy || queued > 0 ? .queue : .start
    }

    static func prompt(_ text: String) -> String { prefix + text }

    /// The text of a prompt Main sent, or nil for one the user wrote.
    static func fromMain(_ text: String) -> String? {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func replyText(_ reply: Reply, title target: String) -> String {
        var lines: [String]
        switch reply.status {
        case .started: lines = ["Sent to the agent on \(target); it is working on it now."]
        case .queued: lines = ["Queued for the agent on \(target); it starts when the agent finishes its current prompt."]
        case .rejected: lines = ["Not sent to \(target): \(reply.message)"]
        }
        if reply.status != .rejected {
            lines.append(reply.sessionID.map { "Session: \($0) \u{2014} read the outcome later with agent_session." }
                         ?? "It starts a new session; its id shows in agents_overview once it has begun.")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct AgentInboxError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
