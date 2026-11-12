import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_793_000_000)
private let root = URL(fileURLWithPath: "/data/Agents", isDirectory: true)
private let threadURL = "https://acme.slack.com/archives/C0SUPPORT/p1792990000123456"

private func topic(_ name: String, id: String = UUID().uuidString, jira: String = "", slack: String = "", archived: Bool = false) -> TopicAgent {
    guard case .success(var made) = TopicAgents.make(name: name, jira: jira, slack: slack, root: root, taken: [], id: id, now: now) else {
        fatalError("fixture \(name)")
    }
    made.archived = archived
    return made
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("topic-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let issueFixture = Data("""
{"key":"ISD-123","fields":{"summary":"Intrum UAT login fails","status":{"name":"Waiting for support"},"issuetype":{"name":"Support"},
 "priority":{"name":"High"},"assignee":{"displayName":"Niklas Inde"},"reporter":{"displayName":"Anna Berg"},
 "created":"2026-11-01T09:00:00.000+0100","updated":"2026-11-10T14:03:00.000+0100",
 "description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Users get "},{"type":"mention","attrs":{"text":"@Bo"}},
   {"type":"text","text":" an error."}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Step one"}]}]}]}]},
 "issuelinks":[{"type":{"inward":"is blocked by","outward":"blocks"},"inwardIssue":{"key":"QDLY-9","fields":{"summary":"Fix SSO","status":{"name":"Review"}}}}],
 "comment":{"total":12,"comments":[\((1...12).map { #"{"author":{"displayName":"Person \#($0)"},"created":"2026-11-0\#($0 % 9 + 1)T10:00:00.000+0100","body":"Comment \#($0)"}"# }.joined(separator: ","))]}}}
""".utf8)

let agentTopicTests: [(name: String, run: () throws -> Void)] = [
    ("topics: Jira keys are typed in any case or pasted as links, and anything else is refused", {
        check(JiraLogic.issueKey(" isd-123 ") == "ISD-123", "lowercase")
        check(JiraLogic.issueKey("https://acme.atlassian.net/browse/QDLY-456") == "QDLY-456", "browse link")
        check(JiraLogic.issueKey("https://acme.atlassian.net/jira/software/c/projects/ISD/boards/1?selectedIssue=ISD-7") == "ISD-7", "board link")
        for bad in ["", "ISD", "ISD-", "ISD-0", "123-4", "ISD 123", "ISD-12a"] { check(JiraLogic.issueKey(bad) == nil, bad) }
    }),

    ("topics: Slack message links give the channel and the thread's first message", {
        let reply = SlackLogic.threadLink(threadURL + "?thread_ts=1792980000.000100&cid=C0SUPPORT")
        check(reply == SlackThreadLink(host: "acme.slack.com", channel: "C0SUPPORT", ts: "1792990000.123456", threadTS: "1792980000.000100"), "\(String(describing: reply))")
        check(reply?.root == "1792980000.000100", "a reply reads its whole thread")
        let top = SlackLogic.threadLink(threadURL)
        check(top?.root == "1792990000.123456" && top?.url == threadURL, "\(String(describing: top))")
        check(SlackLogic.threadLink(threadURL + "?thread_ts=1792990000.123456")?.threadTS == nil, "thread_ts of the message itself is dropped")
        for bad in ["https://evil.com/archives/C0SUPPORT/p1792990000123456", "http://acme.slack.com/archives/C0SUPPORT/p1792990000123456",
                    "https://acme.slack.com/archives/C0SUPPORT", "https://acme.slack.com/archives/c0support/p1792990000123456",
                    threadURL + "?thread_ts=abc", "ISD-1"] {
            check(SlackLogic.threadLink(bad) == nil, bad)
        }
        check(SlackLogic.repliesParameters(reply!) == ["channel": "C0SUPPORT", "ts": "1792980000.000100", "limit": "200"], "replies")
    }),

    ("topics: folder names are slugs, unique among the taken ones", {
        check(TopicAgents.slug("Support: Intrum UAT") == "support-intrum-uat", TopicAgents.slug("Support: Intrum UAT"))
        check(TopicAgents.slug("Åsa's räkning / ../etc") == "asa-s-rakning-etc", TopicAgents.slug("Åsa's räkning / ../etc"))
        check(TopicAgents.slug("!!!") == "topic", "nothing left")
        check(TopicAgents.slug(String(repeating: "word ", count: 30)).count <= TopicAgents.slugLimit, "short")
        check(TopicAgents.uniqueSlug("Intrum", taken: ["intrum", "intrum-2"]) == "intrum-3", "numbered")
    }),

    ("topics: the New agent sheet needs a name, and checks the key and link it is given", {
        check(TopicAgents.make(name: "  ", jira: "", slack: "", root: root, taken: [], now: now) == .failure(.noName), "name")
        check(TopicAgents.make(name: "A", jira: "nope", slack: "", root: root, taken: [], now: now) == .failure(.badJiraKey("nope")), "key")
        check(TopicAgents.make(name: "A", jira: "", slack: "https://x.com", root: root, taken: [], now: now) == .failure(.badSlackLink("https://x.com")), "link")
        let made = topic("Support: Intrum UAT", jira: "isd-123", slack: threadURL)
        check(made.jiraKey == "ISD-123" && made.slackURL == threadURL && made.folder == "/data/Agents/support-intrum-uat", "\(made)")
        check(made.kind == .ticket && topic("x", slack: threadURL).kind == .slack && topic("x").kind == .topic, "kinds")
        check(TopicAgents.isKey(made.key) && !TopicAgents.isKey("topic:nope") && !TopicAgents.isKey(made.id), "keys")
        check(TopicAgents.decode(TopicAgents.encode([made])) == [made] && TopicAgents.decode(Data("x".utf8)).isEmpty, "round trip")
        check(TopicAgents.ownedFolder(made, root: root)?.path == made.folder, "its own folder")
        var escaped = made
        escaped.folder = "/data/Agents/../Secrets"
        check(TopicAgents.ownedFolder(escaped, root: root) == nil, "never outside the root")
        escaped.folder = "/data/Agents"
        check(TopicAgents.ownedFolder(escaped, root: root) == nil, "never the root itself")
    }),

    ("topics: prompts and the system prompt name the ticket and thread and never promise to post", {
        let both = topic("Support", jira: "ISD-1", slack: threadURL)
        check(TopicAgents.prompt(both) == "Look at ISD-1 and the Slack thread \(threadURL) and summarise what\u{2019}s needed from me.", TopicAgents.prompt(both))
        check(TopicAgents.prompt(topic("Free")).isEmpty, "nothing to look at")
        let system = TopicAgents.systemPrompt(both)
        check(system.contains("ISD-1") && system.contains("jira_issue") && system.contains("slack_thread") && system.contains("never claim"), system)
        check(TopicAgents.name(ticket: "ISD-1", summary: "Login fails") == "ISD-1 Login fails", "ticket name")
        check(TopicAgents.name(slackPlace: "#support", author: "Anna") == "Slack: #support \u{00B7} Anna", "slack name")
        check(AgentLogic.mainBasePrompt.contains("topic agents"), "Main knows it can delegate to them")
    }),

    ("topics: Open in Agent finds the topic already made for a ticket or thread", {
        let ticket = topic("Ticket", jira: "ISD-5"), thread = topic("Thread", slack: threadURL + "?thread_ts=1792980000.000100", archived: true)
        check(TopicAgents.existing(jiraKey: "ISD-5", in: [thread, ticket]) == ticket, "by key")
        let sibling = SlackLogic.threadLink("https://acme.slack.com/archives/C0SUPPORT/p1792999999000000?thread_ts=1792980000.000100")
        check(TopicAgents.existing(slack: sibling, in: [ticket, thread]) == thread, "another reply in the same thread, archived too")
        check(TopicAgents.existing(slack: SlackLogic.threadLink(threadURL), in: [ticket, thread]) == nil, "a different thread")
    }),

    ("topics: send_to_agent takes a pull request url, a topic key or id, or a unique name", {
        let id = UUID().uuidString
        let intrum = topic("Support: Intrum UAT", id: id), gaia = topic("Support: Gaia"), old = topic("Old case", archived: true)
        let topics = [intrum, gaia, old]
        let pull = "https://github.com/acme/api/pull/7"
        check(TopicAgents.resolve(pull, topics: topics) == .success(AgentTarget(key: pull, title: "acme/api#7")), "pull request")
        check(TopicAgents.resolve(intrum.key, topics: topics) == .success(AgentTarget(key: intrum.key, title: intrum.name)), "key")
        check(TopicAgents.resolve(id.lowercased(), topics: topics) == .success(AgentTarget(key: intrum.key, title: intrum.name)), "id")
        check(TopicAgents.resolve("support: intrum uat", topics: topics) == .success(AgentTarget(key: intrum.key, title: intrum.name)), "name")
        check(TopicAgents.resolve("gaia", topics: topics) == .success(AgentTarget(key: gaia.key, title: gaia.name)), "part of a name")
        check(TopicAgents.resolve("support", topics: topics) == .failure(.ambiguous("support", [intrum.name, gaia.name])), "ambiguous")
        check(TopicAgents.resolve("old case", topics: topics) == .failure(.archived("Old case")), "archived")
        check(TopicAgents.resolve("nothing", topics: topics) == .failure(.unknown("nothing")), "unknown")
        check(AgentInbox.request(agent: intrum.key, text: "Hi", now: now).map(\.agent) == .success(intrum.key), "a topic key is a valid inbox target")
        check(AgentInbox.request(agent: "topic:nope", text: "Hi", now: now).map(\.agent) != .success("topic:nope"), "only real topic keys")
    }),

    ("topics: the overview lists topic agents with their links, and saved topic sessions are not taken for pull requests", {
        let made = topic("Support: Intrum UAT", jira: "ISD-1", slack: threadURL)
        let state = AgentState.topic(made, loaded: nil, sessionID: "s1")
        check(state.key == made.key && !state.loaded && state.jiraKey == "ISD-1" && state.slackURL == threadURL && state.isTopic, "\(state)")
        let line = AgentOverview.line(state, now: now)
        check(line.contains("topic agent \(made.key)") && line.contains("Jira ISD-1") && line.contains("Slack \(threadURL)"), line)
        let listed = AgentOverview.withPersisted([state], sessions: [made.key: "s1", "https://github.com/acme/api/pull/7": "s2"], known: [made.key])
        check(listed.map(\.key) == [made.key, "https://github.com/acme/api/pull/7"], "\(listed.map(\.key))")
    }),

    ("topics: a Jira issue reads as Markdown with its description, links and last ten comments", {
        let issue = try JiraLogic.parseIssue(issueFixture)
        check(issue.description == "Users get @Bo an error.\n- Step one", issue.description)
        check(issue.links == [JiraIssue.Link(relation: "is blocked by", key: "QDLY-9", summary: "Fix SSO", status: "Review")], "\(issue.links)")
        let text = JiraLogic.issueMarkdown(issue, site: "acme.atlassian.net", now: now)
        check(text.hasPrefix("# ISD-123 Intrum UAT login fails\nSupport \u{00B7} Waiting for support \u{00B7} priority High\nhttps://acme.atlassian.net/browse/ISD-123"), text)
        check(text.contains("Assignee: Niklas Inde \u{00B7} Reporter: Anna Berg") && text.contains("## Comments (last 10 of 12)"), text)
        check(text.contains("### Person 12") && !text.contains("### Person 2\n"), "the last ten")
        check(JiraLogic.issuePath("ISD-1").hasPrefix("/rest/api/3/issue/ISD-1?fields=summary,"), "path")
        check(JiraLogic.text("plain") == "plain" && JiraLogic.text(nil) == "", "plain and missing")
        check((try? JiraLogic.parseIssue(Data("{}".utf8))) == nil, "garbage")
    }),

    ("topics: Slack threads and searches read as Markdown with names", {
        let data = Data(#"{"ok":true,"has_more":true,"messages":[{"ts":"1792990000.000100","user":"U0ANNA","text":"Can <@U0BO> look?"},{"ts":"1792990100.000200","username":"deploybot","bot_id":"B1","text":"Deployed"}]}"#.utf8)
        let thread = try SlackLogic.parseReplies(data)
        check(thread.more && thread.messages.map(\.user) == ["U0ANNA", "deploybot"], "\(thread)")
        let text = SlackLogic.threadMarkdown(thread.messages, more: thread.more, link: SlackLogic.threadLink(threadURL)!, names: ["U0ANNA": "Anna", "U0BO": "Bo"])
        check(text.contains("2 messages, more not shown") && text.contains(" Anna: Can @Bo look?") && text.contains(" deploybot: Deployed"), text)
        let search = Data(#"{"ok":true,"messages":{"matches":[{"ts":"1792990000.000100","text":"UAT is down","user":"U0ANNA","username":"anna","permalink":"https://acme.slack.com/archives/C1/p1","channel":{"id":"C1","name":"support"}}]}}"#.utf8)
        let found = try SlackLogic.parseSearch(search, teamID: "T1")
        check(SlackLogic.searchMarkdown(found, query: "UAT", names: [:]).contains("#support \u{00B7} anna: UAT is down\n  https://acme.slack.com/archives/C1/p1"), "\(found)")
        check(SlackLogic.searchMarkdown([], query: "x", names: [:]) == "No Slack messages match x.\n", "none")
        check(SlackLogic.searchParameters(query: "q", count: 500)["count"] == "\(SlackLogic.searchCountLimit)", "capped")
    }),

    ("topics: the Jira and Slack tools say how to set them up, and read through the clients when they are", {
        let empty = MCPServer.topicTools(sources: MCPServer.TopicSources(jira: { nil }, slack: { nil }), now: { now })
        check(empty.map(\.name) == ["jira_issue", "jira_search", "slack_thread", "slack_search"], "\(empty.map(\.name))")
        check(empty.allSatisfy { ($0.listing["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }, "all read-only")
        func run(_ tools: [MCPTool], _ name: String, _ args: [String: Any]) -> Result<String, Error> {
            Result { try tools.first { $0.name == name }!.run(args) }
        }
        func message(_ result: Result<String, Error>) -> String {
            switch result {
            case .success(let text): return "succeeded: " + text
            case .failure(let error): return error.localizedDescription
            }
        }
        check(message(run(empty, "jira_issue", ["key": "ISD-1"])) == MCPServer.jiraNotSetUp, "jira not set up")
        check(message(run(empty, "slack_search", ["query": "x"])) == MCPServer.slackNotSetUp, "slack not set up")
        check(message(run(empty, "jira_issue", ["key": "nope"])).hasPrefix("key must be a Jira key"), "key checked first")
        check(message(run(empty, "slack_thread", ["url": "nope"])).hasPrefix("url must be a Slack message link"), "link checked first")
        check(message(run(empty, "jira_search", ["jql": " "])) == "jql or a filter is required.", "jql")

        let paths = PathLog()
        let jira = MCPServer.JiraAccess(client: JiraClient(site: "acme.atlassian.net", email: "me@acme.com", token: "t", transport: { request in
            paths.append(request.url?.path ?? "")
            return request.url?.path.hasSuffix("ISD-404") == true ? (Data(), 404) : (issueFixture, 200)
        }), site: "acme.atlassian.net")
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = FileSecretStore(folder: folder, name: TokenStore.slackService)
        try secrets.save(Data("xoxp-test".utf8), for: TokenStore.slack.account)
        let replies = Data(#"{"ok":true,"messages":[{"ts":"1792990000.000100","user":"U0ANNA","text":"Hello"}]}"#.utf8)
        let user = Data(#"{"ok":true,"user":{"id":"U0ANNA","name":"anna","real_name":"Anna Berg"}}"#.utf8)
        let slack = MCPServer.SlackAccess(secrets: secrets, clientID: "", transport: { request in
            paths.append(request.url?.path ?? "")
            return (request.url?.path.hasSuffix("users.info") == true ? user : replies, 200, nil)
        })
        let tools = MCPServer.topicTools(sources: MCPServer.TopicSources(jira: { jira }, slack: { slack }, timeout: 5), now: { now })
        check(message(run(tools, "jira_issue", ["key": "isd-123"])).hasPrefix("succeeded: # ISD-123 Intrum UAT login fails"), "issue")
        check(message(run(tools, "jira_issue", ["key": "ISD-404"])) == "No issue ISD-404, or the Jira account cannot see it.", "missing issue")
        check(message(run(tools, "slack_thread", ["url": threadURL])).contains("Anna Berg: Hello"), message(run(tools, "slack_thread", ["url": threadURL])))
        check(paths.all.contains("/api/conversations.replies") && paths.all.contains("/rest/api/3/issue/ISD-123"), "\(paths.all)")
        check(!paths.all.contains { $0.contains("chat.") || $0.contains("comment") }, "nothing posts")
    }),

    ("topics: the shared Slack wrapper renews a token that runs out, and asks to sign in again when renewal fails", {
        let old = SlackAuth(accessToken: "old", refreshToken: "r", expires: now.addingTimeInterval(60))
        var saved: SlackAuth?
        let token = try blockingResult {
            try await SlackClient.authorized(stored: { old }, renew: { _ in SlackAuth(accessToken: "new", refreshToken: "r2", expires: now.addingTimeInterval(3600)) },
                                             save: { saved = $0 }, client: { $0 }, now: now) { $0 }
        }
        check(token == "new" && saved?.refreshToken == "r2", "renewed before running out")
        let failed = Result {
            try blockingResult {
                try await SlackClient.authorized(stored: { old }, renew: { _ in throw SlackError.failed("invalid_refresh_token") }, save: { _ in },
                                                 client: { $0 }, now: now) { $0 }
            }
        }
        if case .failure(let error) = failed { check(error as? SlackError == .signInAgain, "\(error)") } else { check(false, "should fail") }
        let pasted = try blockingResult {
            try await SlackClient.authorized(stored: { SlackAuth(accessToken: "xoxp") }, renew: { _ in throw SlackError.offline }, save: { _ in },
                                             client: { $0 }, now: now) { $0 }
        }
        check(pasted == "xoxp", "a pasted token is used as it is")
    }),

    ("rules: typed rules are command prefixes, a trailing * is dropped, and shell syntax is refused", {
        check(AgentRules.bashRule("gh pr view *") == .success(AgentRule(kind: .bash, value: "gh pr view")), "star")
        check(AgentRules.bashRule("  npm   test ") == .success(AgentRule(kind: .bash, value: "npm test")), "spaces")
        check(AgentRules.bashRule("./test.sh") == .success(AgentRule(kind: .bash, value: "./test.sh")), "path")
        for bad in ["", "*", "rm -rf; ls", "echo $HOME", "git log | sh", "for x", "\"quoted\"", "a && b"] {
            if case .success(let rule) = AgentRules.bashRule(bad) { check(false, "\(bad) became \(rule)") }
        }
        if case .success(let rule) = AgentRules.bashRule("git push *") { check(AgentRules.warning([rule]) != nil, "dangerous warns") }
        let builtIn = AgentBuiltIn(tools: [], mcpPrefix: "mcp__worktime__", alwaysAsk: ["mcp__worktime__send_to_agent"], commands: [])
        let choices = AgentRules.toolChoices(MCPServer.toolNames, builtIn: builtIn)
        check(choices.contains("mcp__worktime__jira_issue") && !choices.contains("mcp__worktime__send_to_agent"), "\(choices)")
    }),

    ("rules: the built-in list is the sidecar's own file, and agrees with the app's tool names", {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agent/src/\(AgentBuiltIn.fileName)")
        guard let builtIn = AgentBuiltIn.decode(try? Data(contentsOf: file)) else { return check(false, "\(file.path) decodes") }
        check(builtIn.alwaysAsk == ["send_to_agent", "complete_reminder"].map { builtIn.mcpPrefix + $0 }
              && ["send_to_agent", "complete_reminder"].allSatisfy(MCPServer.toolNames.contains), "send_to_agent and complete_reminder always ask")
        check(builtIn.tools == ["Read", "Grep", "Glob"], "\(builtIn.tools)")
        check(builtIn.lines.contains("ls") && builtIn.lines.contains { $0.hasPrefix("sed \u{2014} no -i") }, "\(builtIn.lines)")
        check(builtIn.commands.allSatisfy { $0.anyArgs == true || $0.note != nil }, "every limited command explains its limit")
    }),

    ("permission modes: per agent, Ask when unset, sent with each prompt and on a change mid-turn", {
        check(AgentPermissionMode.allCases.map(\.rawValue) == ["default", "auto", "acceptEdits", "plan"], "no bypass or dontAsk")
        check(AgentPermissionMode.stored(nil, key: "main") == .ask, "default")
        check(AgentPermissionMode.stored(["main": "auto", "x": "bypassPermissions"], key: "main") == .auto, "saved")
        check(AgentPermissionMode.stored(["x": "bypassPermissions"], key: "x") == .ask, "never bypass")
        check(AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: nil, mode: .auto).line.contains(#""permissionMode":"auto""#), "prompt")
        check(AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: nil).line.contains(#""permissionMode":"default""#), "ask by default")
        check(AgentRequest.mode(.plan).line == #"{"mode":"plan","type":"mode"}"# + "\n", AgentRequest.mode(.plan).line)
        check(AgentEvent.decode(#"{"type":"result","sessionId":"s","isError":false,"text":"","turns":2,"model":"claude-sonnet-5-5","permissionMode":"auto"}"#, cwd: "/")
              == .result(sessionID: "s", isError: false, text: "", turns: 2, model: "claude-sonnet-5-5", mode: .auto), "result carries the mode")
        check(AgentLogic.resultLine(turns: 2, model: "claude-sonnet-5-5", mode: .auto) == "Done \u{00B7} 2 turns \u{00B7} Auto mode \u{00B7} Sonnet 5.5",
              AgentLogic.resultLine(turns: 2, model: "claude-sonnet-5-5", mode: .auto))
        check(AgentLogic.resultLine(turns: 1, model: nil, mode: .ask) == "Done \u{00B7} 1 turn", "Ask is not named")
    }),
]

private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ path: String) { lock.withLock { paths.append(path) } }
    var all: [String] { lock.withLock { paths } }
}

/// Runs async work from a synchronous test.
private func blockingResult<T>(_ work: @escaping () async throws -> T) throws -> T {
    let box = BlockingBox<T>(), done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

private final class BlockingBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
