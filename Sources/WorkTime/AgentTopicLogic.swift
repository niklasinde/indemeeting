import Foundation

/// An agent for a topic rather than a pull request, such as a support case: its own folder, optionally linked to a Jira
/// ticket and a Slack thread.
struct TopicAgent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case ticket, slack, topic }

    var id: String
    var name: String
    var jiraKey: String?
    var slackURL: String?
    var folder: String
    var created: Date
    var archived = false

    var key: String { TopicAgents.prefix + id }

    var kind: Kind { jiraKey != nil ? .ticket : slackURL != nil ? .slack : .topic }

    var slackLink: SlackThreadLink? { slackURL.flatMap(SlackLogic.threadLink) }
}

enum TopicAgentError: Error, Equatable {
    case noName
    case badJiraKey(String)
    case badSlackLink(String)
    case unknown(String)
    case ambiguous(String, [String])
    case archived(String)

    var message: String {
        switch self {
        case .noName: return "Give the agent a name."
        case .badJiraKey(let text): return "\u{201C}\(text)\u{201D} is not a Jira key like ISD-123."
        case .badSlackLink(let text): return "\u{201C}\(text)\u{201D} is not a Slack message link (https://<workspace>.slack.com/archives/\u{2026})."
        case .unknown(let text): return "No agent matches \u{201C}\(text)\u{201D}: give a pull request url, a topic agent's key (topic:<id>) or its name."
        case .ambiguous(let text, let names): return "\u{201C}\(text)\u{201D} matches several topic agents: \(names.joined(separator: ", ")). Use its key."
        case .archived(let name): return "The topic agent \(name) is archived; unarchive it in WorkTime first."
        }
    }
}

/// Where a prompt for an agent goes: its key (a pull request url or `topic:<id>`) and what to call it.
struct AgentTarget: Equatable {
    let key: String
    let title: String
}

enum TopicAgents {
    static let prefix = "topic:"
    static let nameLimit = 80
    static let slugLimit = 40

    static func isKey(_ key: String) -> Bool {
        key.hasPrefix(prefix) && UUID(uuidString: String(key.dropFirst(prefix.count))) != nil
    }

    /// The folder name for a topic: lowercase words joined by dashes, `topic` when nothing is left.
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let slug = String(words.joined(separator: "-").prefix(slugLimit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "topic" : slug
    }

    /// The slug, with `-2`, `-3`… when a folder of that name is taken.
    static func uniqueSlug(_ name: String, taken: Set<String>) -> String {
        let base = slug(name)
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base)-\($0)" }.first { !taken.contains($0) }!
    }

    /// A new topic from what the New agent sheet was given, its folder under `root`, or why it cannot be made.
    static func make(name: String, jira: String, slack: String, root: URL, taken: Set<String>, id: String = UUID().uuidString,
                     now: Date) -> Result<TopicAgent, TopicAgentError> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let jira = jira.trimmingCharacters(in: .whitespacesAndNewlines), slack = slack.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.noName) }
        let key = jira.isEmpty ? nil : JiraLogic.issueKey(jira)
        if !jira.isEmpty, key == nil { return .failure(.badJiraKey(jira)) }
        let link = slack.isEmpty ? nil : SlackLogic.threadLink(slack)
        if !slack.isEmpty, link == nil { return .failure(.badSlackLink(slack)) }
        let folder = root.appendingPathComponent(uniqueSlug(name, taken: taken), isDirectory: true).path
        return .success(TopicAgent(id: id, name: String(name.prefix(nameLimit)), jiraKey: key, slackURL: link?.url, folder: folder, created: now))
    }

    static func encode(_ topics: [TopicAgent]) -> Data { AgentInbox.encode(topics) }

    static func decode(_ data: Data?) -> [TopicAgent] {
        data.flatMap { AgentInbox.decode([TopicAgent].self, from: $0) } ?? []
    }

    /// The topic's folder, only when it is inside `root`: deleting a topic never removes anything else.
    static func ownedFolder(_ topic: TopicAgent, root: URL) -> URL? {
        let folder = URL(fileURLWithPath: topic.folder).standardizedFileURL.path, base = root.standardizedFileURL.path
        return folder.hasPrefix(base + "/") && !folder.dropFirst(base.count + 1).contains("/") ? URL(fileURLWithPath: folder) : nil
    }

    /// What `send_to_agent` was given: a pull request url, a topic key or id, or a topic's name (exactly, or the one that
    /// contains it), ignoring case.
    static func resolve(_ input: String, topics: [TopicAgent]) -> Result<AgentTarget, TopicAgentError> {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if GitHubLink.pullRequest(at: text) != nil { return .success(AgentTarget(key: text, title: AgentOverview.prTitle(text))) }
        let id = text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
        let lowered = text.lowercased()
        var found = topics.filter { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        if found.isEmpty { found = topics.filter { $0.name.lowercased() == lowered } }
        if found.isEmpty, !lowered.isEmpty { found = topics.filter { !$0.archived && $0.name.lowercased().contains(lowered) } }
        guard let topic = found.first else { return .failure(.unknown(text)) }
        guard found.count == 1 else { return .failure(.ambiguous(text, found.map(\.name))) }
        guard !topic.archived else { return .failure(.archived(topic.name)) }
        return .success(AgentTarget(key: topic.key, title: topic.name))
    }

    /// The topic already made for this ticket or this Slack thread, archived ones too.
    static func existing(jiraKey: String? = nil, slack: SlackThreadLink? = nil, in topics: [TopicAgent]) -> TopicAgent? {
        topics.first { topic in
            if let jiraKey, topic.jiraKey == jiraKey { return true }
            guard let slack, let link = topic.slackLink else { return false }
            return link.host == slack.host && link.channel == slack.channel && link.root == slack.root
        }
    }

    /// The prompt waiting in a new topic agent's composer.
    static func prompt(_ topic: TopicAgent) -> String {
        let sources = [topic.jiraKey, topic.slackURL.map { "the Slack thread \($0)" }].compactMap { $0 }
        guard !sources.isEmpty else { return "" }
        return "Look at \(sources.joined(separator: " and ")) and summarise what\u{2019}s needed from me."
    }

    /// The name of a topic opened from a Jira ticket.
    static func name(ticket key: String, summary: String) -> String {
        ActivityLogic.truncate(summary.isEmpty ? key : "\(key) \(summary)", to: 60)
    }

    /// The name of a topic opened from a Slack message.
    static func name(slackPlace place: String, author: String?) -> String {
        ActivityLogic.truncate("Slack: " + ([place] + [author].compactMap { $0 }.filter { $0 != place }).joined(separator: " \u{00B7} "), to: 60)
    }

    static func systemPrompt(_ topic: TopicAgent) -> String {
        var links: [String] = []
        if let key = topic.jiraKey { links.append("Linked Jira ticket: \(key). Read it first with the worktime jira_issue tool.") }
        if let url = topic.slackURL { links.append("Linked Slack thread: \(url). Read it first with the worktime slack_thread tool.") }
        return """
            You are a support and topic assistant in WorkTime for \u{201C}\(topic.name)\u{201D}. This is not a code review: the \
            working folder is a scratch folder for this topic, not a git repository; keep notes and drafts there if useful.
            \(links.isEmpty ? "No ticket or thread is linked; ask the user what the topic is about when it is unclear." : links.joined(separator: "\n"))
            Use jira_issue, jira_search, slack_thread and slack_search (all read-only) to gather context, and the user's \
            repositories only when the question is about code.
            You cannot post anything to Jira, Slack or anywhere else, and must never claim you did. When a reply or comment \
            is needed, draft it as text in a fenced block for the user to copy, and say where it should go.
            """
    }
}
