import Foundation

/// The kinds of work an agent does, each a node around Claude on the work map.
enum WorkMapCategory: String, CaseIterable {
    case you, model, memory, files, shell, network, browser, agents, skills, hooks

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var symbol: String {
        switch self {
        case .you: "person"
        case .model: "sparkles"
        case .memory: "brain"
        case .files: "doc.text"
        case .shell: "terminal"
        case .network: "network"
        case .browser: "globe"
        case .agents: "person.2"
        case .skills: "wand.and.stars"
        case .hooks: "link"
        }
    }
}

struct WorkMapEvent: Equatable, Identifiable {
    let id: String
    let category: WorkMapCategory
    var text: String
    let started: Date
    var ended: Date?

    var running: Bool { ended == nil }

    /// `673 ms`, `1.8 s`, `2 min 5 s`; nothing for a moment such as a new message.
    var durationText: String? {
        guard let ended, ended > started else { return nil }
        return WorkMap.duration(ended.timeIntervalSince(started))
    }
}

/// What one agent's session has done so far: the events newest last, a count per kind and how full the context is.
struct WorkMap: Equatable {
    static let limit = 200
    /// How long a node stays tinted after its last event.
    static let fade: TimeInterval = 20

    private(set) var events: [WorkMapEvent] = []
    private(set) var counts: [WorkMapCategory: Int] = [:]
    private(set) var lastUsed: [WorkMapCategory: Date] = [:]
    private(set) var step = 0
    private(set) var contextPercent: Int?
    private(set) var contextTokens: Int?
    private(set) var model: String?
    private var next = 0

    /// The kind of the newest event still running.
    var active: WorkMapCategory? { events.last { $0.running }?.category }

    var isEmpty: Bool { events.isEmpty }

    /// The model of the last turn, else the one picked for the next.
    func modelLabel(selected: String = AgentLogic.defaultModel) -> String { AgentLogic.modelName(model ?? selected).lowercased() }

    /// `Model: opus 5.5 · step 4 · context 10%`, or `Model: sonnet 5.5 · no turns yet`.
    func status(selected: String = AgentLogic.defaultModel) -> String {
        (["Model: \(modelLabel(selected: selected))", step == 0 ? "no turns yet" : "step \(step)"] + [contextText.map { "context \($0)" }])
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    var contextText: String? {
        if let contextPercent { return "\(contextPercent)%" }
        return contextTokens.map { $0 >= 1000 ? "\($0 / 1000)k" : "\($0)" }
    }

    /// How strongly a node is tinted: 1 while it runs, fading to 0 after its last event.
    func warmth(_ category: WorkMapCategory, at now: Date) -> Double {
        if events.contains(where: { $0.running && $0.category == category }) { return 1 }
        guard let used = lastUsed[category] else { return 0 }
        return max(0, min(1, 1 - now.timeIntervalSince(used) / Self.fade))
    }

    // MARK: Events

    /// The user's prompt, after which the model starts thinking.
    mutating func prompt(model: String, at now: Date) {
        use(model: model)
        add(.you, text: "new message", started: now, ended: now)
        startStep(at: now)
    }

    mutating func use(model: String) { self.model = model }

    /// One line the sidecar sent.
    mutating func receive(_ object: [String: Any], cwd: String, at now: Date) {
        let id = object["id"] as? String ?? ""
        switch object["type"] as? String {
        case "text":
            endStep(at: now)
        case "tool_use":
            endStep(at: now)
            let tool = object["tool"] as? String ?? "", input = object["input"] as? [String: Any] ?? [:]
            add(Self.category(tool: tool, input: input), text: Self.description(tool: tool, input: input, cwd: cwd), started: now, id: "tool-" + id)
        case "tool_result":
            end("tool-" + id, at: now)
            if !events.contains(where: { $0.running }) { startStep(at: now) }
        case "hook":
            if object["phase"] as? String == "started" {
                add(.hooks, text: object["name"] as? String ?? "hook", started: now, id: "hook-" + id)
            } else {
                end("hook-" + id, at: now)
            }
        case "context":
            contextPercent = (object["percent"] as? NSNumber)?.intValue
            contextTokens = (object["tokens"] as? NSNumber)?.intValue ?? contextTokens
        case "result":
            if let used = object["model"] as? String, !used.isEmpty { model = used }
        case "idle":
            finish(at: now)
        default: break
        }
    }

    /// The turn is over: a model step that never answered goes, whatever else still runs ends now.
    mutating func finish(at now: Date) {
        if let waiting = events.lastIndex(where: { $0.running && $0.category == .model }) {
            events.remove(at: waiting)
            step -= 1
            counts[.model, default: 1] -= 1
        }
        for index in events.indices where events[index].running { events[index].ended = now }
    }

    private mutating func startStep(at now: Date) {
        step += 1
        add(.model, text: "", started: now, id: "step-\(step)")
    }

    private mutating func endStep(at now: Date) {
        guard let index = events.lastIndex(where: { $0.running && $0.category == .model }) else { return }
        events[index].ended = now
        lastUsed[.model] = now
    }

    private mutating func end(_ id: String, at now: Date) {
        guard let index = events.lastIndex(where: { $0.id == id && $0.running }) else { return }
        events[index].ended = now
        lastUsed[events[index].category] = now
    }

    private mutating func add(_ category: WorkMapCategory, text: String, started: Date, ended: Date? = nil, id: String? = nil) {
        next += 1
        events.append(WorkMapEvent(id: id ?? "event-\(next)", category: category, text: text, started: started, ended: ended))
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
        counts[category, default: 0] += 1
        lastUsed[category] = started
    }

    /// What a row says: a model step names the model as it is known now.
    func text(_ event: WorkMapEvent) -> String {
        guard event.category == .model, event.id.hasPrefix("step-") else { return event.text }
        return "\(modelLabel()) \u{00B7} step \(event.id.dropFirst("step-".count))"
    }

    // MARK: Classification

    private static let fileTools: Set<String> = ["Read", "Edit", "MultiEdit", "Write", "Glob", "Grep", "LS", "NotebookEdit", "NotebookRead"]
    private static let shellTools: Set<String> = ["Bash", "BashOutput", "KillShell", "KillBash"]
    private static let agentTools: Set<String> = ["Agent", "Task", "SendMessage"]
    private static let memoryFiles: Set<String> = ["claude.md", "claude.local.md", "agents.md", "memory.md", WorkspaceInstructions.fileName.lowercased()]
    private static let browserServers = ["chrome", "browser", "playwright", "puppeteer"]
    /// WorkTime's own tools that read what is stored on this Mac rather than a remote service.
    private static let localTools = ["activity", "time_report", "meeting", "resume", "agents_overview", "agent_session", "attention"]
    private static let networkPrograms: Set<String> = ["gh", "glab", "curl", "wget", "ssh", "scp", "sftp", "rsync", "ping", "dig", "nslookup", "nc",
                                                       "telnet", "ftp", "http", "https", "aws", "az", "kubectl", "helm", "terraform"]
    private static let networkSubcommands: [String: Set<String>] = [
        "git": ["fetch", "pull", "push", "clone", "ls-remote"],
        "npm": ["install", "i", "ci", "update", "publish", "view", "outdated", "audit"],
        "pnpm": ["install", "i", "add", "update", "publish"],
        "yarn": ["install", "add", "upgrade", "publish"],
        "bun": ["install", "add", "update"],
        "npx": [],
        "pip": ["install", "download"],
        "pip3": ["install", "download"],
        "uv": ["sync", "add"],
        "poetry": ["install", "add", "update"],
        "brew": ["install", "update", "upgrade", "fetch", "tap"],
        "cargo": ["install", "fetch", "update", "publish"],
        "go": ["get", "install"],
        "docker": ["pull", "push", "login"],
        "pod": ["install", "update"],
        "gem": ["install", "update"],
    ]

    static func category(tool: String, input: [String: Any]) -> WorkMapCategory {
        if fileTools.contains(tool) {
            let path = ["file_path", "notebook_path", "path"].compactMap { input[$0] as? String }.first ?? ""
            return isMemory(path: path) ? .memory : .files
        }
        if shellTools.contains(tool) { return isNetwork(command: input["command"] as? String ?? "") ? .network : .shell }
        if agentTools.contains(tool) { return .agents }
        switch tool {
        case "WebFetch", "WebSearch": return .network
        case "Skill": return .skills
        default: break
        }
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return .model }
        let server = parts[1].lowercased(), name = parts.dropFirst(2).joined(separator: "__").lowercased()
        if browserServers.contains(where: server.contains) { return .browser }
        if name == "send_to_agent" { return .agents }
        if server.hasSuffix("worktime"), localTools.contains(where: name.contains) { return .memory }
        return .network
    }

    /// A memory directory, an instructions file (CLAUDE.md, MAIN.md, AGENTS.md) or an assistant's own file.
    static func isMemory(path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        if memoryFiles.contains(name) { return true }
        let folders = parts.dropLast()
        return folders.contains("memory") || folders.contains("memories") || (folders.last == "assistants" && name.hasSuffix(".md"))
    }

    /// Whether any command in the line is a program that talks to the network: `gh`, `curl`, `git push`, `npm install`.
    static func isNetwork(command: String) -> Bool {
        command.components(separatedBy: CharacterSet(charactersIn: "|&;\n")).contains { segment in
            var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
                .drop { $0.contains("=") || ["sudo", "env", "time", "command", "exec", "nohup", "("].contains($0) }
            guard let first = words.popFirst() else { return false }
            let program = (first as NSString).lastPathComponent
            if networkPrograms.contains(program) { return true }
            guard let subcommands = networkSubcommands[program] else { return false }
            if subcommands.isEmpty { return true }
            while let option = words.first, option.hasPrefix("-") { words = words.dropFirst(["-C", "-c"].contains(option) ? 2 : 1) }
            return words.first.map(subcommands.contains) ?? false
        }
    }

    /// The call's own `description` when it has one, else the tool and what it works on.
    static func description(tool: String, input: [String: Any], cwd: String) -> String {
        if let given = (input["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty { return given }
        let summary = AgentLogic.summary(tool: tool, input: input, cwd: cwd)
        if tool.hasPrefix("mcp__") {
            let name = AgentLogic.displayName(tool)
            return summary.isEmpty ? name : "\(name): \(summary)"
        }
        if shellTools.contains(tool) { return summary.isEmpty ? tool : summary }
        return summary.isEmpty ? tool : "\(tool) \(summary)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        if milliseconds < 1000 { return "\(max(1, milliseconds)) ms" }
        if seconds < 60 { return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), seconds) }
        let whole = Int(seconds.rounded())
        return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(whole % 60) s"
    }
}
