import Foundation

/// A line the agent sidecar (`agent/`) writes to stdout, with tool inputs already reduced to what the window shows.
enum AgentEvent: Equatable {
    case ready(model: String)
    case session(String)
    case text(String)
    case toolUse(id: String, tool: String, summary: String, detail: String)
    case toolResult(id: String, content: String, isError: Bool, auto: Bool)
    case permissionRequest(id: String, tool: String, summary: String, detail: String)
    case result(sessionID: String?, isError: Bool, text: String, turns: Int?, model: String?)
    case error(String)
    case signIn
    case idle

    static func decode(_ line: String, cwd: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let string = { (key: String) in object[key] as? String ?? "" }
        let input = object["input"] as? [String: Any] ?? [:]
        switch type {
        case "ready": return .ready(model: string("model"))
        case "session": return .session(string("sessionId"))
        case "text": return .text(string("text"))
        case "tool_use":
            return .toolUse(id: string("id"), tool: string("tool"), summary: AgentLogic.summary(tool: string("tool"), input: input, cwd: cwd),
                            detail: AgentLogic.detail(tool: string("tool"), input: input))
        case "tool_result":
            return .toolResult(id: string("id"), content: string("content"), isError: object["isError"] as? Bool ?? false,
                               auto: object["auto"] as? Bool ?? false)
        case "permission_request":
            return .permissionRequest(id: string("id"), tool: string("tool"), summary: AgentLogic.summary(tool: string("tool"), input: input, cwd: cwd),
                                      detail: AgentLogic.detail(tool: string("tool"), input: input))
        case "result":
            return .result(sessionID: object["sessionId"] as? String, isError: object["isError"] as? Bool ?? false, text: string("text"),
                           turns: object["turns"] as? Int, model: object["model"] as? String)
        case "error": return object["auth"] as? Bool == true || AgentLogic.needsSignIn(string("message")) ? .signIn : .error(string("message"))
        case "idle": return .idle
        default: return nil
        }
    }
}

/// What the window sends the sidecar, one JSON object per line.
enum AgentRequest {
    case prompt(text: String, cwd: String, sessionID: String?, model: String? = nil)
    case permission(id: String, allow: Bool)
    case interrupt

    var line: String {
        var object: [String: Any]
        switch self {
        case .prompt(let text, let cwd, let sessionID, let model):
            object = ["type": "prompt", "text": text, "cwd": cwd]
            if let sessionID { object["sessionId"] = sessionID }
            if let model { object["model"] = model }
        case .permission(let id, let allow): object = ["type": "permission", "id": id, "allow": allow]
        case .interrupt: object = ["type": "interrupt"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

struct AgentItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case text(String)
        case tool(name: String, summary: String, detail: String, result: String?, isError: Bool, auto: Bool)
        case permission(tool: String, summary: String, detail: String, allowed: Bool?)
        case status(String)
        case error(String)
        case signIn
    }

    let id: String
    var kind: Kind
}

enum AgentLogic {
    static let folderKey = "agentFolder"
    static let summaryLimit = 100

    // MARK: Transcript

    /// Folds one event into the transcript. Returns the session to keep, if the event names one.
    /// `auto` says the model was picked by Auto, so the status line says so.
    @discardableResult
    static func apply(_ event: AgentEvent, to items: inout [AgentItem], auto: Bool = false) -> String? {
        switch event {
        case .ready, .idle: return nil
        case .session(let id): return id
        case .text(let text):
            items.append(AgentItem(id: "text-\(items.count)", kind: .text(text)))
        case .toolUse(let id, let tool, let summary, let detail):
            items.append(AgentItem(id: "tool-\(id)", kind: .tool(name: tool, summary: summary, detail: detail, result: nil, isError: false, auto: false)))
        case .toolResult(let id, let content, let isError, let auto):
            guard let index = items.firstIndex(where: { $0.id == "tool-\(id)" }),
                  case .tool(let name, let summary, let detail, _, _, _) = items[index].kind else { return nil }
            items[index].kind = .tool(name: name, summary: summary, detail: detail, result: content, isError: isError, auto: auto)
        case .permissionRequest(let id, let tool, let summary, let detail):
            items.append(AgentItem(id: "permission-\(id)-\(items.count)", kind: .permission(tool: tool, summary: summary, detail: detail, allowed: nil)))
        case .result(let sessionID, let isError, let text, let turns, let model):
            if isError, needsSignIn(text) {
                appendSignIn(to: &items)
            } else if isError {
                items.append(AgentItem(id: "error-\(items.count)", kind: .error(text.isEmpty ? "The agent stopped with an error." : text)))
            } else {
                items.append(AgentItem(id: "status-\(items.count)", kind: .status(resultLine(turns: turns, model: model, auto: auto))))
            }
            return sessionID
        case .error(let message):
            items.append(AgentItem(id: "error-\(items.count)", kind: .error(message)))
        case .signIn:
            appendSignIn(to: &items)
        }
        return nil
    }

    static func appendSignIn(to items: inout [AgentItem]) {
        guard items.last?.kind != .signIn else { return }
        items.append(AgentItem(id: "signin-\(items.count)", kind: .signIn))
    }

    /// Marks a permission prompt answered so its buttons go away.
    static func answer(_ itemID: String, allow: Bool, in items: inout [AgentItem]) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              case .permission(let tool, let summary, let detail, nil) = items[index].kind else { return }
        items[index].kind = .permission(tool: tool, summary: summary, detail: detail, allowed: allow)
    }

    /// The sidecar's id for a permission prompt item (`permission-<id>-<n>`).
    static func permissionID(of itemID: String) -> String? {
        let parts = itemID.split(separator: "-")
        return parts.count == 3 && parts[0] == "permission" ? String(parts[1]) : nil
    }

    static func resultLine(turns: Int?, model: String? = nil, auto: Bool = false) -> String {
        let model = model.map { (auto ? "Auto \u{2192} " : "") + modelName($0) }
        return (["Done", turns.map { "\($0) turn\($0 == 1 ? "" : "s")" }, model] as [String?]).compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    // MARK: Sign-in

    static let signInMessage = "Sign in to Claude: run `claude setup-token` and paste the token in Settings \u{2192} Models, "
        + "or run `claude` and /login once."

    private static let signInPatterns = ["not logged in", "/login", "invalid api key", "authentication_failed", "authentication_error",
                                         "oauth token", "oauth_org_not_allowed", "invalid bearer token"]

    /// What `claude setup-token` prints: a long-lived OAuth token for the Pro or Max plan.
    static func isSetupToken(_ token: String) -> Bool {
        token.hasPrefix("sk-ant-oat") && !token.contains(where: \.isWhitespace)
    }

    /// Whether a sidecar error or failed result means Claude Code has no usable subscription sign-in.
    static func needsSignIn(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return signInPatterns.contains { lowered.contains($0) }
    }

    /// The sidecar's environment: the app's, with `node` first on the PATH, never an API key, and the setup token when one is saved.
    static func childEnvironment(_ base: [String: String], nodeFolder: String, token: String?, mcpCommand: String?) -> [String: String] {
        var environment = base
        environment["ANTHROPIC_API_KEY"] = nil
        environment["ANTHROPIC_AUTH_TOKEN"] = nil
        environment["PATH"] = [nodeFolder, base["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"].compactMap { $0 }.joined(separator: ":")
        if let token { environment["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        environment["WORKTIME_MCP_COMMAND"] = mcpCommand
        return environment
    }

    // MARK: Tool inputs

    /// One line for a tool call: the command, the file relative to the folder, or the pattern.
    static func summary(tool: String, input: [String: Any], cwd: String) -> String {
        let value = { (key: String) in input[key] as? String }
        let text: String
        switch tool {
        case "Bash": text = value("command").map(firstLine) ?? ""
        case "Read", "Edit", "Write", "NotebookEdit": text = value("file_path").map { relative($0, to: cwd) } ?? ""
        case "Grep": text = [value("pattern"), value("path").map { "in " + relative($0, to: cwd) }].compactMap { $0 }.joined(separator: " ")
        case "Glob": text = value("pattern") ?? ""
        default:
            if tool.hasPrefix("mcp__") {
                text = mcpSummary(input)
            } else {
                text = input.keys.sorted().compactMap { input[$0] as? String }.first.map(firstLine) ?? ""
            }
        }
        return text.count > summaryLimit ? String(text.prefix(summaryLimit - 1)) + "\u{2026}" : text
    }

    /// MCP inputs in one line: strings bare (a pull request URL as `owner/repo#12`), other values as `key: value`.
    private static func mcpSummary(_ input: [String: Any]) -> String {
        input.keys.sorted().compactMap { key -> String? in
            switch input[key] {
            case let text as String:
                guard !text.isEmpty else { return nil }
                return GitHubLink.pullRequest(at: text).map { "\($0.repo)#\($0.number)" } ?? firstLine(text)
            case let number as NSNumber: return "\(key): \(number)"
            default: return nil
            }
        }.joined(separator: ", ")
    }

    /// What a tool row shows: `WorkTime · GitHub needs attention` for `mcp__worktime__github_needs_attention`, else the tool name.
    static func displayName(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return tool }
        var server = parts[1]
        if server.hasPrefix("plugin_"), let last = server.split(separator: "_").last { server = String(last) }
        let name = humanised(parts.dropFirst(2).joined(separator: "_"))
        return humanised(server, capitaliseAll: true) + " \u{00B7} " + name
    }

    private static let knownWords = ["worktime": "WorkTime", "github": "GitHub", "gitlab": "GitLab", "pr": "PR", "prs": "PRs", "mcp": "MCP",
                                     "api": "API", "url": "URL", "id": "ID", "ids": "IDs", "jira": "Jira", "slack": "Slack", "ci": "CI"]

    private static func humanised(_ name: String, capitaliseAll: Bool = false) -> String {
        name.split(whereSeparator: { $0 == "_" || $0 == "-" }).enumerated().map { index, word in
            let lowered = word.lowercased()
            if let known = knownWords[lowered] { return known }
            return index == 0 || capitaliseAll ? lowered.prefix(1).uppercased() + lowered.dropFirst() : lowered
        }.joined(separator: " ")
    }

    /// The expanded text of a call: a Bash command as it is, anything else as JSON.
    static func detail(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let command = input["command"] as? String { return command }
        return pretty(input)
    }

    static func pretty(_ input: [String: Any]) -> String {
        guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func relative(_ path: String, to cwd: String) -> String {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    private static func firstLine(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let first = lines.first else { return "" }
        return lines.count > 1 ? first + " \u{2026}" : String(first)
    }

    // MARK: Finding node and the sidecar

    /// Where `node` may be: the PATH, Homebrew, then the newest nvm version.
    static func nodeCandidates(path: String?, home: URL, nvmVersions: [String]) -> [URL] {
        let fromPath = (path ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        let known = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].map { URL(fileURLWithPath: $0) }
        let nvm = nvmVersions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { home.appendingPathComponent(".nvm/versions/node/\($0)/bin/node") }
        var seen = Set<String>()
        return (fromPath + known + nvm).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The built sidecar: `WORKTIME_AGENT_DIR`, then the app's Resources, then the `agent/` folder of the checkout it was built from.
    static func sidecarCandidates(environment: [String: String], resources: URL?, sourceFile: String) -> [URL] {
        let repo = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return ([environment["WORKTIME_AGENT_DIR"].map { URL(fileURLWithPath: $0) }, resources?.appendingPathComponent("agent"),
                 repo.appendingPathComponent("agent")] as [URL?])
            .compactMap { $0?.appendingPathComponent("dist/main.js") }
    }

    // MARK: @-mentions

    struct Mention: Equatable {
        let path: String
        let lines: ClosedRange<Int>?
    }

    private static let mentionPattern = #"(?<![\w@])@([A-Za-z0-9_./~\-]*[A-Za-z0-9_/\-])(?::(\d+)(?:-(\d+))?)?"#

    /// The partial `@path` being typed at the end of the prompt, without the `@`; nil when the prompt does not end in one.
    static func mentionQuery(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let token = text[text.index(after: at)...]
        guard !token.contains(where: \.isWhitespace) else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        return String(token)
    }

    static func insertMention(_ path: String, into text: String) -> String {
        guard mentionQuery(text) != nil, let at = text.lastIndex(of: "@") else { return text + "@" + path + " " }
        return String(text[..<at]) + "@" + path + " "
    }

    /// Paths whose letters contain the query in order, best first: a match in the file name, then a contiguous one, then shorter paths.
    static func fuzzyMatches(_ query: String, in paths: [String], limit: Int = 12) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return Array(paths.sorted { $0.count < $1.count }.prefix(limit)) }
        let scored: [(path: String, score: Int)] = paths.compactMap { path in
            let haystack = path.lowercased()
            guard isSubsequence(needle, of: haystack) else { return nil }
            let name = (haystack as NSString).lastPathComponent
            var score = path.count
            if name.contains(needle) { score -= 1000 }
            if name.hasPrefix(needle) { score -= 500 }
            if haystack.contains(needle) { score -= 300 }
            return (path, score)
        }
        return scored.sorted { $0.score == $1.score ? $0.path < $1.path : $0.score < $1.score }.prefix(limit).map(\.path)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = needle[...]
        for character in haystack where character == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }

    static func mentions(in text: String) -> [Mention] {
        guard let regex = try? NSRegularExpression(pattern: mentionPattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let path = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else { return nil }
            let start = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
            let end = Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) } ?? start
            let lines = start.flatMap { start in end.map { min(start, $0)...max(start, $0) } }
            return Mention(path: path, lines: lines)
        }
    }

    /// The prompt with the files it mentions listed by absolute path, so the agent reads them rather than guessing.
    static func expandMentions(_ text: String, cwd: String, exists: (String) -> Bool) -> String {
        var seen = Set<String>()
        let lines = mentions(in: text).compactMap { mention -> String? in
            let path = absolute(mention.path, cwd: cwd)
            guard exists(path), seen.insert(path + "\(String(describing: mention.lines))").inserted else { return nil }
            return "- " + path + (mention.lines.map { $0.count == 1 ? " (line \($0.lowerBound))" : " (lines \($0.lowerBound)-\($0.upperBound))" } ?? "")
        }
        guard !lines.isEmpty else { return text }
        return text + "\n\nReferenced files (read them as needed):\n" + lines.joined(separator: "\n")
    }

    static func absolute(_ path: String, cwd: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst(1) }
        return URL(fileURLWithPath: cwd).appendingPathComponent(path).standardizedFileURL.path
    }

    static let skippedFolders: Set<String> = [".git", ".build", "node_modules", "DerivedData", ".swiftpm", "dist", "Pods"]

    // MARK: Code references in replies

    static let codeScheme = "worktime-code"

    private static let referencePattern = #"(?<![\w./])(`?)((?:/|~/)?(?:[A-Za-z0-9_.\-]+/)*[A-Za-z0-9_\-][A-Za-z0-9_.\-]*\.[A-Za-z][A-Za-z0-9]{0,9}):(\d+)(?:[:-]\d+)?\1"#
    private static let linkPattern = #"\]\(([^)\s]+)\)"#

    /// The reply with `path/file.swift:123` references and Markdown links to files in the folder turned into links that
    /// open the file at that line. Fenced code blocks are left alone.
    static func linkifiedCodeReferences(_ text: String, cwd: String, exists: (String) -> Bool) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                return line
            }
            return inFence ? line : linkifyLine(line, cwd: cwd, exists: exists)
        }.joined(separator: "\n")
    }

    private static func linkifyLine(_ line: String, cwd: String, exists: (String) -> Bool) -> String {
        var result = line
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range(at: 1), in: result) else { continue }
                let target = String(result[range])
                guard !target.contains("://"), !target.hasPrefix("mailto:"), let link = fileLink(target, cwd: cwd, exists: exists) else { continue }
                result.replaceSubrange(range, with: link)
            }
        }
        guard let regex = try? NSRegularExpression(pattern: referencePattern) else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let pathRange = Range(match.range(at: 2), in: result),
                  let lineRange = Range(match.range(at: 3), in: result), let number = Int(result[lineRange]) else { continue }
            if result[whole.upperBound...].hasPrefix("](") { continue }
            let path = absolute(String(result[pathRange]), cwd: cwd)
            guard exists(path) else { continue }
            let label = String(result[whole])
            result.replaceSubrange(whole, with: "[\(label)](\(codeURL(path: path, line: number)))")
        }
        return result
    }

    /// A Markdown link target to a file (`Sources/A.swift`, `A.swift:12`, `A.swift#L12`) as a `worktime-code` link.
    private static func fileLink(_ target: String, cwd: String, exists: (String) -> Bool) -> String? {
        var path = target, line: Int?
        if let hash = path.range(of: "#L") {
            line = Int(path[hash.upperBound...].prefix { $0.isNumber })
            path = String(path[..<hash.lowerBound])
        } else if let colon = path.lastIndex(of: ":"), let number = Int(path[path.index(after: colon)...]) {
            line = number
            path = String(path[..<colon])
        }
        let absolutePath = absolute(path.removingPercentEncoding ?? path, cwd: cwd)
        return exists(absolutePath) ? codeURL(path: absolutePath, line: line) : nil
    }

    static func codeURL(path: String, line: Int?) -> String {
        var components = URLComponents()
        components.scheme = codeScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)] + (line.map { [URLQueryItem(name: "line", value: String($0))] } ?? [])
        return components.string ?? ""
    }

    static func codeTarget(_ url: URL) -> (path: String, line: Int?)? {
        guard url.scheme == codeScheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value else { return nil }
        return (path, items.first { $0.name == "line" }?.value.flatMap(Int.init))
    }

    /// How to open a file at a line: Xcode for Swift and Objective-C when it is installed, else a VS Code style
    /// `--goto` CLI when one is on the PATH, else the default app.
    static func openCommand(path: String, line: Int?, hasXcode: Bool, gotoCLI: URL?) -> (executable: URL, arguments: [String]) {
        let xcodeFiles: Set<String> = ["swift", "m", "mm", "h", "metal", "xib", "storyboard"]
        if hasXcode, xcodeFiles.contains((path as NSString).pathExtension.lowercased()) {
            return (URL(fileURLWithPath: "/usr/bin/xed"), (line.map { ["--line", String($0)] } ?? []) + [path])
        }
        if let gotoCLI {
            return (gotoCLI, ["--goto", path + (line.map { ":\($0)" } ?? "")])
        }
        return (URL(fileURLWithPath: "/usr/bin/open"), [path])
    }

    // MARK: Pull requests

    static let prSessionsKey = "agentPRSessions"

    static func reviewPrompt(url: String, repo: String, hasCheckout: Bool) -> String {
        "Review \(url). Use the worktime github_pr tool and `gh pr diff`; don't check out the branch."
            + (hasCheckout ? "" : " There is no local checkout of \(repo), so read the code with gh.")
    }

    // MARK: Models

    struct ModelChoice: Equatable {
        let id: String
        let name: String
        let tier: String?
    }

    static let modelKey = "agentModel"
    static let auto = "auto"
    static let models = [ModelChoice(id: auto, name: "Auto", tier: nil),
                         ModelChoice(id: "claude-opus-5-5", name: "Opus 5.5", tier: "opus"),
                         ModelChoice(id: "claude-sonnet-5-5", name: "Sonnet 5.5", tier: "sonnet"),
                         ModelChoice(id: "claude-haiku-5-5", name: "Haiku 5.5", tier: "haiku")]
    static let tiers = ["haiku", "sonnet", "opus"]
    static let fallbackTier = "sonnet"

    static func modelName(_ id: String) -> String { models.first { $0.id == id }?.name ?? id }

    static func modelID(tier: String) -> String? { models.first { $0.tier == tier }?.id }

    /// The saved choice, or Auto when there is none or it is no longer offered.
    static func storedModel(_ raw: String?) -> String {
        raw.flatMap { raw in models.first { $0.id == raw }?.id } ?? auto
    }

    // MARK: Auto

    struct RouteSignals: Equatable {
        var mentions = 0
        var isReview = false
        var turns = 0
    }

    static let routeSystem = """
        Pick the Claude model for a coding agent's next prompt. Answer with JSON {"model": "haiku" | "sonnet" | "opus"}.
        haiku: quick lookups, status checks, single-fact questions.
        sonnet: everyday coding, reviews of small diffs, explanations.
        opus: multi-file changes, debugging, architecture, large reviews.
        """

    static let routeTimeout: TimeInterval = 3

    static func routeRequestBody(prompt: String, signals: RouteSignals) -> [String: Any] {
        let user = "Referenced files: \(signals.mentions)\nPull request review: \(signals.isReview ? "yes" : "no")\n"
            + "Earlier turns in this session: \(signals.turns)\n\nPrompt:\n\(prompt.prefix(4000))"
        let schema: [String: Any] = ["type": "object", "properties": ["model": ["type": "string", "enum": tiers]], "required": ["model"]]
        return ["model": OllamaSummarizer.model, "stream": false, "keep_alive": "10m", "format": schema, "options": ["temperature": 0],
                "messages": [["role": "system", "content": routeSystem], ["role": "user", "content": user]]]
    }

    /// The tier in an Ollama `/api/chat` reply, or nil when it holds none.
    static func routeTier(fromReply data: Data) -> String? {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (reply["message"] as? [String: Any])?["content"] as? String,
              let answer = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let tier = answer["model"] as? String, tiers.contains(tier) else { return nil }
        return tier
    }

    private static let followUps = ["continue", "go on", "keep going", "fix it", "fix that", "fix this", "fix them", "do it", "try again",
                                    "again", "yes", "ok", "okay", "go ahead", "proceed", "and the rest", "next"]

    /// A short prompt that carries on the previous turn rather than asking something new.
    static func isFollowUp(_ prompt: String) -> Bool {
        let text = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard text.split(separator: " ").count <= 6 else { return false }
        return followUps.contains { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + ",") }
    }

    /// The model Auto runs a prompt on: the classified tier, Sonnet when there is none, and never below the previous
    /// turn's model for a follow-up.
    static func routedModel(tier: String?, previous: String?, prompt: String) -> String {
        let picked = tier.flatMap(modelID) ?? modelID(tier: fallbackTier) ?? auto
        guard let previous, isFollowUp(prompt), rank(previous) > rank(picked) else { return picked }
        return previous
    }

    private static func rank(_ id: String) -> Int {
        models.first { $0.id == id }?.tier.flatMap { tiers.firstIndex(of: $0) } ?? -1
    }

    /// Asks the local model through `ask` (the request body in, the reply out) and gives up after `timeout` seconds.
    static func route(prompt: String, signals: RouteSignals, previous: String?, timeout: TimeInterval = routeTimeout,
                      ask: @escaping @Sendable (Data) async throws -> Data) async -> String {
        let body = (try? JSONSerialization.data(withJSONObject: routeRequestBody(prompt: prompt, signals: signals))) ?? Data()
        let tier = await withTaskGroup(of: String?.self) { group in
            group.addTask { (try? await ask(body)).flatMap(routeTier) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return routedModel(tier: tier, previous: previous, prompt: prompt)
    }

    static let quickActions: [(title: String, prompt: String)] = [
        ("Find in code", "Find where this is implemented in the code and point me to the files and lines: "),
        ("Explain this repo", "Give me a short tour of this repository: what it does, how it is laid out and where to start reading."),
    ]
}
