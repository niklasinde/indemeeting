import Foundation

struct AssistantProblem: Equatable, Sendable {
    var line: Int?
    var message: String

    var text: String { line.map { "Line \($0): \(message)" } ?? message }
}

/// A role agent under a workspace's Main, as its Markdown file with YAML front matter describes it.
struct AssistantRole: Equatable, Identifiable, Sendable {
    var slug: String
    var name: String
    var icon = Assistants.defaultIcon
    var summary = ""
    var model = "sonnet"
    var permissionMode = "ask"
    var tools: [String] = []
    var folder: String?
    var body = ""
    var problems: [AssistantProblem] = []

    var id: String { slug }
    var isUsable: Bool { problems.isEmpty }
}

/// A role in a workspace.
struct AssistantEntry: Equatable, Identifiable, Sendable {
    var workspace: String
    var role: AssistantRole

    var id: String { key }
    var key: String { Assistants.key(workspace: workspace, slug: role.slug) }
}

struct AssistantTemplate: Sendable {
    var role: AssistantRole

    var slug: String { role.slug }
    var text: String { Assistants.serialise(role) }
}

enum AssistantError: Error, Equatable {
    case broken(String, String)
    case ambiguous(String, [String])

    var message: String {
        switch self {
        case .broken(let name, let problem): return "The assistant \(name) cannot be used until its file is fixed: \(problem)"
        case .ambiguous(let text, let names): return "\u{201C}\(text)\u{201D} matches several assistants: \(names.joined(separator: ", ")). Use its key."
        }
    }
}

enum Assistants {
    static let prefix = "assistant:"
    static let defaultIcon = "sparkles"
    static let models = ["opus", "sonnet", "haiku"]
    static let modes = ["ask", "auto", "acceptEdits", "plan"]
    static let ownFolder = "own"
    static let nameLimit = 60
    static let summaryLimit = 300
    static let bodyLimit = 20_000
    static let folderName = "Assistants"
    static let mcpPrefix = "mcp__worktime__"
    static let storedModelsKey = "agentAssistantModels"
    static let collapsedKey = "agentAssistantsCollapsed"
    static let fields = ["name", "icon", "description", "model", "permissionMode", "tools", "folder"]
    /// The worktime tools an assistant may call whatever its `tools` say: reading what was tracked and said.
    static let defaultTools = ["activity_context", "recent_meetings", "search_meetings", "get_meeting", "resume_context"]

    // MARK: Keys

    static func key(workspace: String, slug: String) -> String { "\(prefix)\(workspace):\(slug)" }

    static func parse(key: String) -> (workspace: String, slug: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let workspace = String(rest[..<colon]), slug = String(rest[rest.index(after: colon)...])
        return workspace.isEmpty || slug.isEmpty ? nil : (workspace, slug)
    }

    static func isKey(_ key: String) -> Bool { parse(key: key) != nil }

    static func slug(_ name: String) -> String {
        name.contains { $0.isLetter || $0.isNumber } ? TopicAgents.slug(name) : "assistant"
    }

    static func uniqueName(_ name: String, taken: [String]) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(name.lowercased()) else { return name }
        return (2...).lazy.map { "\(name) \($0)" }.first { !lowered.contains($0.lowercased()) }!
    }

    // MARK: Parse

    /// The role in `text`. Never fails: whatever is wrong is listed in `problems` and the rest is filled in as far as it goes.
    static func parse(slug: String, text: String?) -> AssistantRole {
        var role = AssistantRole(slug: slug, name: slug)
        guard let text else {
            role.problems = [AssistantProblem(line: nil, message: "The file could not be read.")]
            return role
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            role.body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            role.problems = [AssistantProblem(line: 1, message: "The file must start with a front matter block between two --- lines.")]
            return role
        }
        guard let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else {
            role.problems = [AssistantProblem(line: nil, message: "The front matter is not closed with a --- line.")]
            return role
        }
        role.body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        var seen = Set<String>(), given: [String: Int] = [:]
        var index = 1
        func problem(_ line: Int?, _ message: String) { role.problems.append(AssistantProblem(line: line, message: message)) }
        while index < close {
            let line = lines[index], number = index + 1
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                problem(number, "Expected key: value, found \u{201C}\(trimmed)\u{201D}.")
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard fields.contains(key) else {
                problem(number, "Unknown key \u{201C}\(key)\u{201D}; use \(fields.joined(separator: ", ")).")
                continue
            }
            guard seen.insert(key).inserted else {
                problem(number, "\u{201C}\(key)\u{201D} is given twice.")
                continue
            }
            given[key] = number
            var items: [String]?
            if key == "tools" {
                if value.isEmpty {
                    var block: [String] = []
                    while index < close, let item = listItem(lines[index]) {
                        block.append(item)
                        index += 1
                    }
                    items = block
                } else {
                    items = list(value)
                }
            } else {
                value = unquote(value)
            }
            switch key {
            case "name": role.name = value
            case "icon": role.icon = value
            case "description": role.summary = value
            case "model": role.model = value == "auto" ? "sonnet" : value
            case "permissionMode": role.permissionMode = value
            case "folder": role.folder = value.isEmpty ? nil : value
            default: role.tools = items ?? []
            }
        }
        validate(&role, given: given)
        return role
    }

    private static func validate(_ role: inout AssistantRole, given: [String: Int]) {
        func problem(_ key: String?, _ message: String) { role.problems.append(AssistantProblem(line: key.flatMap { given[$0] }, message: message)) }
        if given["name"] == nil { problem(nil, "name is required.") } else if role.name.isEmpty || role.name.count > nameLimit {
            problem("name", "name must be 1 to \(nameLimit) characters.")
        }
        if given["name"] == nil || role.name.isEmpty { role.name = role.slug }
        if given["description"] == nil { problem(nil, "description is required: one line telling Main when to delegate to this assistant.") }
        else if role.summary.isEmpty || role.summary.count > summaryLimit { problem("description", "description must be 1 to \(summaryLimit) characters.") }
        if given["icon"] != nil, role.icon.range(of: "^[a-z0-9][a-z0-9.]*$", options: .regularExpression) == nil {
            problem("icon", "icon must be an SF Symbol name such as hammer or person.2.fill.")
        }
        if !models.contains(role.model) { problem("model", "model must be one of \(models.joined(separator: ", ")).") }
        if !modes.contains(role.permissionMode) { problem("permissionMode", "permissionMode must be one of \(modes.joined(separator: ", ")).") }
        if role.tools.contains(where: { $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil }) {
            problem("tools", "tools lists tool names such as jira_issue, separated by commas.")
        }
        var unique: [String] = []
        for tool in role.tools where !unique.contains(tool) { unique.append(tool) }
        role.tools = unique
        if given["folder"] != nil, role.folder == nil { problem("folder", "folder is empty; leave the key out for the workspace folder, or use \(ownFolder).") }
    }

    private static func listItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("-") else { return nil }
        return unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func list(_ value: String) -> [String] {
        let inner = value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
        return inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var out = "", escaped = false
            for character in value.dropFirst().dropLast() {
                if escaped {
                    out.append(character == "n" ? "\n" : character)
                    escaped = false
                } else if character == "\\" { escaped = true } else { out.append(character) }
            }
            return out
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return value.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        if let comment = value.range(of: " #") { return String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return value
    }

    // MARK: Serialise

    private static func quoted(_ value: String) -> String {
        let special = value.isEmpty || value.contains(": ") || value.contains(" #") || value.contains("\n") || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.hasSuffix(":") || value.first.map { "-?:,[]{}#&*!|>'\"%@`".contains($0) } == true
        guard special else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func serialise(_ role: AssistantRole) -> String {
        var lines = ["---", "name: " + quoted(role.name), "icon: " + quoted(role.icon), "description: " + quoted(role.summary),
                     "model: " + role.model, "permissionMode: " + role.permissionMode,
                     "tools: [" + role.tools.map(quoted).joined(separator: ", ") + "]"]
        if let folder = role.folder { lines.append("folder: " + quoted(folder)) }
        return (lines + ["---", "", role.body]).joined(separator: "\n") + "\n"
    }

    /// `text` with its `name:` line replaced, or added to the front matter; other lines are left as they are.
    static func renamed(_ text: String, to name: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        let close = lines.indices.dropFirst().first { lines[$0].trimmingCharacters(in: .whitespaces) == "---" } ?? lines.count
        let line = "name: " + quoted(name)
        if let at = lines[1..<close].firstIndex(where: { $0.hasPrefix("name:") }) { lines[at] = line } else { lines.insert(line, at: 1) }
        return lines.joined(separator: "\n")
    }

    static func wordCount(_ text: String) -> Int {
        parse(slug: "", text: text).body.split { $0.isWhitespace }.count
    }

    // MARK: Listing

    /// The roles of the files, by name; a file that cannot be read or understood is in the list with its problems.
    static func list(_ files: [(slug: String, text: String?)]) -> [AssistantRole] {
        files.map { parse(slug: $0.slug, text: $0.text) }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.slug < $1.slug : order == .orderedAscending
        }
    }

    // MARK: Delegation

    /// The assistant `input` names, by key, name or file name, ignoring case and a trailing "assistant"; nil when none matches, so
    /// the caller can try the other kinds of agent.
    static func resolve(_ input: String, in entries: [AssistantEntry]) -> Result<AgentTarget, AssistantError>? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var found = entries.filter { $0.key.caseInsensitiveCompare(text) == .orderedSame }
        if found.isEmpty {
            var name = text.lowercased()
            for suffix in [" assistant", " agent"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
            let wanted = slug(name)
            found = entries.filter { $0.role.name.lowercased() == name || $0.role.slug == wanted }
        }
        guard let entry = found.first else { return nil }
        guard found.count == 1 else { return .failure(.ambiguous(text, found.map { "\($0.role.name) (\($0.workspace))" })) }
        guard entry.role.isUsable else { return .failure(.broken(entry.role.name, entry.role.problems.first?.text ?? "")) }
        return .success(AgentTarget(key: entry.key, title: entry.role.name))
    }

    // MARK: Prompts

    /// What Main is told about its assistants, rebuilt at every prompt.
    static func roster(_ roles: [AssistantRole]) -> String? {
        let usable = roles.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }
        return "Your assistants are role agents under you, each with its own conversation:\n"
            + usable.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
            + "\nWhen the user asks for one, or the task clearly matches one, hand it over with send_to_agent, giving the role name as agent "
            + "(the user approves each message), and say that you did. Check back with agent_session. Do the rest yourself."
    }

    /// The assistant's prompt: what it is, then its own instructions; the workspace's MAIN.md follows through `WorkspaceInstructions`.
    static func scope(_ role: AssistantRole, workspace: Workspace, folder: String) -> String {
        var text = """
            You are the \(role.name) assistant of the \(workspace.name) workspace in WorkTime, working under Main. Messages that \
            start with "From Main:" are handed over by Main on the user's behalf; answer them as you would the user.
            Your working folder is \(folder). Nothing you do can post to Jira, Slack or GitHub, and you must never claim it did: draft \
            any message as text in a fenced block for the user to copy, and say where it goes.
            """
        let body = String(role.body.prefix(bodyLimit))
        if !body.isEmpty { text += "\n\nYour role instructions:\n" + body }
        return text
    }

    // MARK: Tools

    /// The MCP tools the assistant may call: the default set and its own list, as the sidecar names them.
    static func allowedTools(_ role: AssistantRole) -> [String] {
        var allowed: [String] = []
        for tool in defaultTools + role.tools {
            let name = tool.hasPrefix("mcp__") ? tool : mcpPrefix + tool
            if !allowed.contains(name) { allowed.append(name) }
        }
        return allowed
    }

    // MARK: Defaults

    /// The Claude model id a front matter `model` stands for.
    static func modelID(_ model: String) -> String {
        AgentLogic.modelID(tier: model) ?? AgentLogic.defaultModel
    }

    static func permissionMode(_ mode: String) -> AgentPermissionMode {
        mode == "ask" ? .ask : AgentPermissionMode(rawValue: mode) ?? .ask
    }
}

// MARK: Built-in templates

extension Assistants {
    static let templates: [AssistantTemplate] = [
        AssistantTemplate(role: AssistantRole(
            slug: "developer", name: "Developer", icon: "hammer",
            summary: "Implements a ticket or fixes a pull request in its repository, runs the tests and reports what changed.",
            model: "sonnet", permissionMode: "ask", tools: ["github_pr", "jira_issue", "jira_search"], folder: nil,
            body: """
                # Developer

                You work in the repository the task is about: the one of the pull request or ticket Main names. Open its checkout \
                under the workspace folders, or ask the user where it is when you cannot find it.

                - Read the repository's CLAUDE.md or AGENTS.md first and follow it.
                - Read the ticket (jira_issue) or pull request (github_pr, gh pr diff) before changing anything.
                - Make the smallest change that does the job; reuse code that is already there.
                - Run the repository's tests and linter before you say it is done, and report what you ran and the result. If you \
                could not run them, say so.
                - Edit and Bash calls ask the user as usual. Ask before you commit or push, and never push to main.
                - Finish with what changed, what you checked, and what is left.
                """)),
        AssistantTemplate(role: AssistantRole(
            slug: "time-reporter", name: "Time reporter", icon: "clock",
            summary: "Drafts the week's time per ticket and the Jira worklog texts from tracked activity; never posts.",
            model: "sonnet", permissionMode: "ask", tools: ["time_report", "jira_issue", "jira_search"], folder: ownFolder,
            body: """
                # Time reporter

                You turn tracked time into a report the user can paste into Jira.

                1. Call time_report for the week asked for (the current week when none is named), and activity_context for the \
                days that look thin or unclear.
                2. Look up the tickets with jira_issue or jira_search so each line has its summary.
                3. Output a table: day, ticket, hours, what was done. Then one worklog text per ticket and day, in the user's \
                usual voice: short, past tense, no filler.
                4. Round hours to quarters, make each day add up, and list anything you could not place under "Unassigned" with \
                your best guess.

                You never post or change anything in Jira. Output copy-ready text and say what looks off or missing.
                """)),
        AssistantTemplate(role: AssistantRole(
            slug: "reviewer", name: "Reviewer", icon: "eye",
            summary: "Reviews a pull request and drafts the review comments; never posts them.",
            model: "opus", permissionMode: "ask", tools: ["github_pr", "github_prs", "jira_issue"], folder: nil,
            body: """
                # Reviewer

                You review the pull request Main or the user names.

                - Read it with github_pr and `gh pr diff`; open the changed files in the checkout when the diff is not enough.
                - Read the linked ticket with jira_issue when there is one, and check the change does what it asks.
                - Look for bugs, missing tests, risky migrations, security problems and anything that breaks the repository's \
                conventions (its CLAUDE.md). Skip style nits a linter would catch.
                - Draft the review in one fenced block: a verdict (approve, request changes or comment) and the comments, each \
                with file and line and a sentence on why.

                You never post, approve or comment on GitHub. The user posts the review themselves.
                """)),
        AssistantTemplate(role: AssistantRole(
            slug: "support", name: "Support", icon: "lifepreserver",
            summary: "Works a support case from its Jira ticket and Slack threads and drafts the replies.",
            model: "sonnet", permissionMode: "ask", tools: ["jira_issue", "jira_search", "slack_thread", "slack_search"], folder: ownFolder,
            body: """
                # Support

                You help with a support case.

                - Read the ticket (jira_issue) and any Slack thread (slack_thread) first; search for earlier cases with jira_search \
                and slack_search when it looks familiar.
                - Say in two or three lines what the customer needs, what is known and what is missing.
                - Draft the reply for Jira or Slack in a fenced block, in the customer's language, polite and short. Say where it \
                should be posted.
                - Look at the repositories only when the question is about code.

                You cannot post anything and must never claim you did.
                """)),
        AssistantTemplate(role: AssistantRole(
            slug: "meeting-follow-up", name: "Meeting follow-up", icon: "calendar.badge.checkmark",
            summary: "Reads a meeting and drafts the tickets and messages its action items call for.",
            model: "sonnet", permissionMode: "ask", tools: ["jira_issue", "jira_search", "slack_search"], folder: ownFolder,
            body: """
                # Meeting follow-up

                You turn a meeting into follow-up work.

                - Find the meeting with search_meetings or recent_meetings and read it with get_meeting: summary, action items and, \
                when needed, the transcript.
                - List the action items with owner and due date, and what is unclear.
                - Check jira_search for tickets that already cover an item before proposing a new one.
                - Draft each ticket (summary, description, acceptance criteria) and each message (who, where, text) in fenced blocks \
                for the user to post.

                You cannot create or send anything; never claim you did.
                """)),
    ]

    static func template(_ slug: String) -> AssistantTemplate? { templates.first { $0.slug == slug } }
}

// MARK: Files

/// Each workspace's assistants as `<folder>/<workspace id>/Assistants/<slug>.md`, read whenever they are needed so edits apply at once.
struct AssistantFiles: Sendable {
    var folder: URL = AppPaths.workspaceFolders
    var home = NSHomeDirectory()

    func folder(_ workspace: String) -> URL {
        folder.appendingPathComponent(workspace, isDirectory: true).appendingPathComponent(Assistants.folderName, isDirectory: true)
    }

    func url(_ workspace: String, slug: String) -> URL { folder(workspace).appendingPathComponent(slug + ".md") }

    func ownFolder(_ workspace: String, slug: String) -> URL { folder(workspace).appendingPathComponent(slug, isDirectory: true) }

    /// The templates, written the first time a workspace is used; a folder that exists is left as the user has it.
    func ensureDefaults(_ workspace: String) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder(workspace).path) else { return }
        try? manager.createDirectory(at: folder(workspace), withIntermediateDirectories: true)
        for template in Assistants.templates { write(template.text, workspace: workspace, slug: template.slug) }
    }

    func slugs(_ workspace: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder(workspace).path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.map { String($0.dropLast(3)) }
    }

    func list(_ workspace: String) -> [AssistantRole] {
        Assistants.list(slugs(workspace).map { ($0, text(workspace, slug: $0)) })
    }

    func text(_ workspace: String, slug: String) -> String? { try? String(contentsOf: url(workspace, slug: slug), encoding: .utf8) }

    func role(_ workspace: String, slug: String) -> AssistantRole? {
        FileManager.default.fileExists(atPath: url(workspace, slug: slug).path)
            ? Assistants.parse(slug: slug, text: text(workspace, slug: slug)) : nil
    }

    func write(_ text: String, workspace: String, slug: String) {
        try? FileManager.default.createDirectory(at: folder(workspace), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url(workspace, slug: slug), options: .atomic)
    }

    /// Removes the file only: the assistant's own folder and its sessions stay.
    func remove(_ workspace: String, slug: String) { try? FileManager.default.removeItem(at: url(workspace, slug: slug)) }

    /// A new assistant from `text`, renamed to a name not yet used; returns its slug.
    @discardableResult
    func create(_ workspace: String, name: String, text: String) -> String {
        let roles = list(workspace)
        let name = Assistants.uniqueName(String(name.trimmingCharacters(in: .whitespaces).prefix(Assistants.nameLimit)), taken: roles.map(\.name))
        let slug = TopicAgents.uniqueSlug(Assistants.slug(name), taken: Set(slugs(workspace)))
        write(Assistants.renamed(text, to: name), workspace: workspace, slug: slug)
        return slug
    }

    func blank(_ workspace: String, name: String) -> String {
        let role = AssistantRole(slug: "", name: name, summary: "Describe when Main should hand work to this assistant.",
                                 body: "# \(name)\n\nDescribe how this assistant works.")
        return create(workspace, name: name, text: Assistants.serialise(role))
    }

    func duplicate(_ workspace: String, slug: String) -> String? {
        guard let text = text(workspace, slug: slug) else { return nil }
        let name = Assistants.parse(slug: slug, text: text).name
        return create(workspace, name: name + " copy", text: text)
    }

    func rename(_ workspace: String, slug: String, to name: String) {
        guard let text = text(workspace, slug: slug) else { return }
        let name = Assistants.uniqueName(name.trimmingCharacters(in: .whitespaces),
                                         taken: list(workspace).filter { $0.slug != slug }.map(\.name))
        write(Assistants.renamed(text, to: name), workspace: workspace, slug: slug)
    }

    func reset(_ workspace: String, slug: String) {
        if let template = Assistants.template(slug) { write(template.text, workspace: workspace, slug: slug) }
    }

    /// The folder the assistant works in: the workspace's, its own, or the one it names.
    func workFolder(_ role: AssistantRole, workspace: Workspace) -> String {
        guard let folder = role.folder else { return workspace.defaultFolder(home: home) }
        return folder == Assistants.ownFolder ? ownFolder(workspace.id, slug: role.slug).path : Workspaces.expand(folder, home: home)
    }

    /// Changes whenever a file is added, removed or edited, for noticing edits made outside the app.
    func signature(_ workspace: String) -> String {
        slugs(workspace).sorted().map { slug in
            let date = (try? url(workspace, slug: slug).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(slug)@\(date?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }
}
