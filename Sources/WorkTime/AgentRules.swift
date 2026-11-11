import Foundation

/// A call the user chose to always allow, for every agent: a Bash command prefix, edits in a folder, or one tool.
struct AgentRule: Codable, Hashable {
    enum Kind: String, Codable {
        case bash, edits, tool
    }

    let kind: Kind
    let value: String

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    init?(_ object: Any) {
        guard let object = object as? [String: Any], let kind = (object["kind"] as? String).flatMap(Kind.init),
              let value = object["value"] as? String, !value.isEmpty else { return nil }
        self.init(kind: kind, value: value)
    }

    var json: [String: String] { ["kind": kind.rawValue, "value": value] }
}

enum AgentRules {
    static let key = "agentAllowRules"

    static func decode(_ data: Data?) -> [AgentRule] {
        data.flatMap { try? JSONDecoder().decode([AgentRule].self, from: $0) } ?? []
    }

    static func encode(_ rules: [AgentRule]) -> Data? { try? JSONEncoder().encode(rules) }

    static func adding(_ new: [AgentRule], to rules: [AgentRule]) -> [AgentRule] {
        rules + new.reduce(into: [AgentRule]()) { added, rule in
            if !rules.contains(rule), !added.contains(rule) { added.append(rule) }
        }
    }

    /// One rule as Settings lists it.
    static func label(_ rule: AgentRule) -> String {
        switch rule.kind {
        case .bash: return rule.value
        case .edits: return "Edits in " + abbreviated(rule.value)
        case .tool: return AgentLogic.displayName(rule.value)
        }
    }

    /// The Always allow line of a permission card, naming exactly what will be saved.
    static func offer(_ rules: [AgentRule]) -> String? {
        guard let first = rules.first else { return nil }
        switch first.kind {
        case .bash: return "Always allow: " + rules.map(\.value).joined(separator: ", ")
        case .edits: return "Always allow edits in " + abbreviated(first.value)
        case .tool: return "Always allow " + AgentLogic.displayName(first.value)
        }
    }

    private static let dangerousCommands: Set<String> = ["rm", "sudo", "sh", "bash", "zsh", "eval", "xargs", "curl", "wget"]
    private static let dangerousPrefixes: Set<String> = ["git", "git push", "git reset", "git clean", "git checkout"]

    /// A warning for rules that would let a command delete work or run anything, with any arguments.
    static func warning(_ rules: [AgentRule]) -> String? {
        let risky = rules.filter { rule in
            rule.kind == .bash && (dangerousPrefixes.contains(rule.value)
                                   || rule.value.split(separator: " ").first.map { dangerousCommands.contains(String($0)) } == true)
        }
        guard !risky.isEmpty else { return nil }
        return risky.map(\.value).joined(separator: ", ") + " will then run with any arguments without asking, "
            + "including ones that delete work or run anything (rm -rf, push --force, reset --hard, piping into a shell)."
    }

    /// A command prefix typed in Settings, like `gh pr view` or `gh pr view *`: words a prefix rule can hold, nothing a shell
    /// would read as an operator, quote or expansion.
    static func bashRule(_ text: String) -> Result<AgentRule, AgentInboxError> {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.last == "*" { words.removeLast() }
        guard let name = words.first else { return .failure(AgentInboxError("Type a command, like gh pr view.")) }
        guard name.wholeMatch(of: #/[\w.\/~+-]+/#) != nil, name != "for",
              words.dropFirst().allSatisfy({ $0.wholeMatch(of: #/[\w.\/:=@,+-]+/#) != nil }) else {
            return .failure(AgentInboxError("A rule is a command and its first words, without quotes, pipes, ; or $."))
        }
        return .success(AgentRule(kind: .bash, value: words.joined(separator: " ")))
    }

    /// The WorkTime MCP tools a rule can name: all but those that always ask.
    static func toolChoices(_ names: [String], builtIn: AgentBuiltIn) -> [String] {
        names.map { builtIn.mcpPrefix + $0 }.filter { !builtIn.alwaysAsk.contains($0) }
    }

    private static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// What the sidecar runs without asking, read from `builtin-allowed.json` beside it: the one list its checks use too.
struct AgentBuiltIn: Decodable, Equatable {
    struct Command: Decodable, Equatable {
        let name: String
        var anyArgs: Bool?
        var note: String?
    }

    let tools: [String]
    let mcpPrefix: String
    let alwaysAsk: [String]
    let commands: [Command]

    static let fileName = "builtin-allowed.json"

    static func decode(_ data: Data?) -> AgentBuiltIn? { data.flatMap { try? JSONDecoder().decode(AgentBuiltIn.self, from: $0) } }

    /// The list beside the first built sidecar, from the same places the agent is started from.
    static func load(sidecars: [URL], fileManager: FileManager = .default) -> AgentBuiltIn? {
        sidecars.lazy.map { $0.deletingLastPathComponent().appendingPathComponent(fileName) }
            .compactMap { fileManager.contents(atPath: $0.path) }.compactMap(decode).first
    }

    /// The commands in one line each: `ls`, or `git — status, log, …`.
    var lines: [String] {
        commands.map { command in command.note.map { "\(command.name) \u{2014} \($0)" } ?? command.name }
    }
}
