import Foundation

/// Read-only Jira and Slack lookups for the agents, with the site and tokens WorkTime saved. Nothing here posts or changes anything.
extension MCPServer {
    struct JiraAccess: Sendable {
        let client: JiraClient
        let site: String
    }

    struct SlackAccess: Sendable {
        let secrets: FileSecretStore
        let clientID: String
        var transport: SlackTransport = SlackClient.urlSession

        /// Runs `work` with the saved sign-in, renewed and saved back the same way the app does it.
        func run<T>(_ work: (SlackClient) async throws -> T) async throws -> T {
            let account = TokenStore.slack.account, transport = transport, clientID = clientID
            return try await SlackClient.authorized(
                stored: { secrets.key(for: account).flatMap { String(data: $0, encoding: .utf8) }.flatMap(SlackAuth.init(stored:)) },
                renew: { try await SlackClient.renew($0, clientID: clientID, transport: transport) },
                save: { try secrets.save(Data($0.stored.utf8), for: account) },
                client: { SlackClient(token: $0, transport: transport) }, work)
        }
    }

    struct TopicSources {
        var jira: () -> JiraAccess? = { MCPServer.storedJira() }
        var slack: () -> SlackAccess? = { MCPServer.storedSlack() }
        var timeout: TimeInterval = 30
    }

    static let jiraNotSetUp = "Jira is not set up in WorkTime: add the site, email and API token in Settings \u{203A} Jira."
    static let slackNotSetUp = "Slack is not set up in WorkTime: sign in with Slack in Settings \u{203A} Slack."

    static func storedJira(secrets: URL = AppPaths.secrets) -> JiraAccess? {
        func preference(_ key: String) -> String? { CFPreferencesCopyAppValue(key as CFString, appDomain as CFString) as? String }
        let token = FileSecretStore(folder: secrets, name: TokenStore.jiraService).key(for: TokenStore.jira.account).flatMap { String(data: $0, encoding: .utf8) }
        guard let token, !token.isEmpty, let site = preference(JiraLogic.siteKey), let email = preference(JiraLogic.emailKey) else { return nil }
        return JiraAccess(client: JiraClient(site: site, email: email, token: token), site: site)
    }

    static func storedSlack(secrets: URL = AppPaths.secrets) -> SlackAccess? {
        let store = FileSecretStore(folder: secrets, name: TokenStore.slackService)
        guard store.key(for: TokenStore.slack.account) != nil else { return nil }
        let clientID = CFPreferencesCopyAppValue(SlackLogic.clientIDKey as CFString, appDomain as CFString) as? String ?? ""
        return SlackAccess(secrets: store, clientID: clientID)
    }

    static func topicTools(sources: TopicSources = TopicSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func wait(_ what: String, _ work: @escaping @Sendable () async throws -> String) throws -> String {
            switch blocking(timeout: sources.timeout, work) {
            case .success(let text): return cut(text, at: outputLimit)
            case .failure(let error): throw error
            case nil: throw MCPToolError("\(what) did not answer within \(Int(sources.timeout)) seconds.")
            }
        }
        func jira(_ work: @escaping @Sendable (JiraAccess) async throws -> String) throws -> String {
            guard let access = sources.jira() else { throw MCPToolError(jiraNotSetUp) }
            do { return try wait("Jira") { try await work(access) } } catch let error as JiraError { throw MCPToolError(error.message) }
        }
        func slack(_ work: @escaping @Sendable (SlackAccess) async throws -> String) throws -> String {
            guard let access = sources.slack() else { throw MCPToolError(slackNotSetUp) }
            do { return try wait("Slack") { try await work(access) } } catch let error as SlackError { throw MCPToolError(error.message) }
        }
        return [
            MCPTool(name: "jira_issue",
                    description: "One Jira issue, read-only: summary, status, type, priority, assignee, reporter, description, linked issues "
                        + "and the last \(JiraLogic.commentLimit) comments.",
                    properties: ["key": ["type": "string", "description": "The issue key, like ISD-123, or its browse link."]],
                    required: ["key"]) { args in
                let text = args["key"] as? String ?? ""
                guard let key = JiraLogic.issueKey(text) else { throw MCPToolError("key must be a Jira key like ISD-123, not \u{201C}\(text)\u{201D}.") }
                let date = now()
                return try jira { access in
                    do {
                        return JiraLogic.issueMarkdown(try await access.client.issue(key), site: access.site, now: date)
                    } catch JiraError.notFound {
                        throw MCPToolError("No issue \(key), or the Jira account cannot see it.")
                    }
                }
            },
            MCPTool(name: "jira_search",
                    description: "Jira issues matching a JQL query, read-only: key, summary, status, priority, last update and link.",
                    properties: ["jql": ["type": "string", "description": "A JQL query, e.g. project = ISD AND text ~ \"Intrum\" ORDER BY updated DESC."],
                                 "max": ["type": "integer", "minimum": 1, "maximum": JiraLogic.searchLimit, "description": "How many issues, 20 when left out."]],
                    required: ["jql"]) { args in
                let jql = (args["jql"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !jql.isEmpty else { throw MCPToolError("jql is required.") }
                let max = min(count(args["max"], fallback: 20), JiraLogic.searchLimit), date = now()
                return try jira { access in
                    JiraLogic.searchMarkdown(try await access.client.search(jql: jql, max: max), jql: jql, site: access.site, now: date)
                }
            },
            MCPTool(name: "slack_thread",
                    description: "The messages of a Slack thread, oldest first, with who wrote them, read-only. Takes a message link "
                        + "copied from Slack; a reply's link reads its whole thread.",
                    properties: ["url": ["type": "string", "description": "https://<workspace>.slack.com/archives/<channel>/p<ts>, optionally with ?thread_ts=."]],
                    required: ["url"]) { args in
                let text = args["url"] as? String ?? ""
                guard let link = SlackLogic.threadLink(text) else { throw MCPToolError("url must be a Slack message link, not \u{201C}\(text)\u{201D}.") }
                return try slack { access in
                    try await access.run { client in
                        let thread = try await client.thread(link)
                        let ids = thread.messages.flatMap { [$0.user].compactMap { $0 } + SlackLogic.mentionedUsers(in: $0.text) }
                        return SlackLogic.threadMarkdown(thread.messages, more: thread.more, link: link, names: await client.names(ids))
                    }
                }
            },
            MCPTool(name: "slack_search",
                    description: "Slack messages matching a search, newest first, read-only, with channel, author and link. Takes Slack's "
                        + "search syntax (in:#channel, from:@name, after:2026-01-31).",
                    properties: ["query": ["type": "string", "description": "What to search for."],
                                 "max": ["type": "integer", "minimum": 1, "maximum": SlackLogic.searchCountLimit,
                                         "description": "How many messages, 20 when left out."]],
                    required: ["query"]) { args in
                let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { throw MCPToolError("query is required.") }
                let max = min(count(args["max"], fallback: 20), SlackLogic.searchCountLimit)
                return try slack { access in
                    try await access.run { client in
                        let messages = try await client.search(query, count: max, teamID: "")
                        let names = await client.names(messages.flatMap { SlackLogic.mentionedUsers(in: $0.text) + [$0.author].compactMap { $0 } })
                        return SlackLogic.searchMarkdown(messages, query: query, names: names)
                    }
                }
            },
        ]
    }
}
