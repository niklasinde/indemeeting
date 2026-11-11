import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let cwd = "/repo"
private let existing: Set<String> = ["/repo/Sources/App.swift", "/repo/README.md", "/repo/agent/src/main.ts", "/abs/Tool.swift"]
private let exists = { (path: String) in existing.contains(path) }

let agentTests: [(name: String, run: () throws -> Void)] = [
    ("agent: sidecar lines decode into events with short tool summaries", {
        check(AgentEvent.decode(#"{"type":"session","sessionId":"s1"}"#, cwd: cwd) == .session("s1"), "session")
        check(AgentEvent.decode(#"{"type":"text","text":"Hi"}"#, cwd: cwd) == .text("Hi"), "text")
        if case .toolUse(let id, let tool, let summary, let detail)? = AgentEvent.decode(
            #"{"type":"tool_use","id":"t1","tool":"Read","input":{"file_path":"/repo/Sources/App.swift"}}"#, cwd: cwd) {
            check(id == "t1" && tool == "Read" && summary == "Sources/App.swift", "read summary \(summary)")
            check(detail.contains("\"file_path\""), "detail is the input")
        } else {
            check(false, "tool_use decodes")
        }
        check(AgentEvent.decode(#"{"type":"permission_request","id":"3","tool":"Bash","input":{"command":"ls -la\nrm x"}}"#, cwd: cwd)
              == .permissionRequest(id: "3", tool: "Bash", summary: "ls -la \u{2026}", detail: "ls -la\nrm x"),
              "bash summarises its first line and keeps the whole command as the detail")
        check(AgentEvent.decode(#"{"type":"result","sessionId":"s1","isError":false,"text":"ok","costUSD":0.5,"turns":2,"model":"m"}"#, cwd: cwd)
              == .result(sessionID: "s1", isError: false, text: "ok", turns: 2, model: "m"), "result")
        check(AgentEvent.decode(#"{"type":"tool_result","id":"t","content":"x","auto":true}"#, cwd: cwd)
              == .toolResult(id: "t", content: "x", isError: false, auto: true), "auto-allowed result")
        check(AgentEvent.decode("not json", cwd: cwd) == nil, "garbage is ignored")
        check(AgentEvent.decode(#"{"type":"mystery"}"#, cwd: cwd) == nil, "unknown types are ignored")
    }),

    ("agent: tool summaries per tool, truncated", {
        check(AgentLogic.summary(tool: "Grep", input: ["pattern": "foo", "path": "/repo/Sources"], cwd: cwd) == "foo in Sources", "grep")
        check(AgentLogic.summary(tool: "Glob", input: ["pattern": "**/*.swift"], cwd: cwd) == "**/*.swift", "glob")
        check(AgentLogic.summary(tool: "mcp__worktime__recent_meetings", input: [:], cwd: cwd) == "", "mcp without inputs has no summary")
        let long = AgentLogic.summary(tool: "Bash", input: ["command": String(repeating: "a", count: 300)], cwd: cwd)
        check(long.count == AgentLogic.summaryLimit && long.hasSuffix("\u{2026}"), "truncated to the limit")
    }),

    ("agent: MCP tools read as server and humanised tool, with their inputs summarised", {
        check(AgentLogic.displayName("mcp__worktime__github_needs_attention") == "WorkTime \u{00B7} GitHub needs attention", "worktime")
        check(AgentLogic.displayName("mcp__plugin_worktime_worktime__github_pr") == "WorkTime \u{00B7} GitHub PR", "plugin server")
        check(AgentLogic.displayName("mcp__claude-in-chrome__read_page") == "Claude In Chrome \u{00B7} Read page", "dashed server")
        check(AgentLogic.displayName("Bash") == "Bash" && AgentLogic.displayName("mcp__x") == "mcp__x", "others unchanged")
        let pr = AgentLogic.summary(tool: "mcp__worktime__github_pr", input: ["pr": "https://github.com/o/r/pull/12"], cwd: cwd)
        check(pr == "o/r#12", "pr url shortened: \(pr)")
        let search = AgentLogic.summary(tool: "mcp__worktime__search_meetings", input: ["query": "budget", "limit": 5], cwd: cwd)
        check(search == "limit: 5, budget", "mixed inputs: \(search)")
    }),

    ("agent: Bash details are the command itself, other tools JSON", {
        let command = "python3 - <<'EOF'\nprint({1: 2})\nEOF"
        check(AgentLogic.detail(tool: "Bash", input: ["command": command, "description": "x"]) == command, "whole command")
        check(AgentLogic.detail(tool: "Read", input: ["file_path": "/a"]) == AgentLogic.pretty(["file_path": "/a"]), "json")
    }),

    ("agent: pull requests open from an agent link with a review prompt", {
        let url = "https://github.com/o/r/pull/12"
        let link = GitHubLink.agentLink(for: url)
        check(link == "worktime://agent?pr=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F12", link)
        check(GitHubLink.parseAgent(link) == GitHubLink.Target(repo: "o/r", number: 12), "round trip")
        check(GitHubLink.parseAgent("worktime://agent?pr=\(url)") == GitHubLink.Target(repo: "o/r", number: 12), "unencoded")
        check(GitHubLink.parseAgent("worktime://pr?url=\(url)") == nil && GitHubLink.parse(link) == nil, "the two links stay apart")
        check(GitHubLink.parseAgent("worktime://agent?pr=https://evil.com/o/r/pull/1") == nil, "only GitHub")
        check(GitHubLink.parseAgent("worktime://agent?pr=\(url)&x=1") == nil, "no extra parameters")
        let prompt = AgentLogic.reviewPrompt(url: url, repo: "o/r", hasCheckout: true)
        check(prompt == "Review \(url). Use the worktime github_pr tool and `gh pr diff`; don't check out the branch.", prompt)
        check(AgentLogic.reviewPrompt(url: url, repo: "o/r", hasCheckout: false).contains("no local checkout of o/r"), "no checkout")
    }),

    ("agent: models are a fixed list with Auto first and the default", {
        check(AgentLogic.models.map(\.id) == ["auto", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"], "ids")
        check(AgentLogic.storedModel(nil) == "auto" && AgentLogic.storedModel("gpt") == "auto", "Auto by default")
        check(AgentLogic.storedModel("claude-haiku-5-5") == "claude-haiku-5-5", "a saved choice")
        check(AgentLogic.modelName("claude-sonnet-5-5") == "Sonnet 5.5" && AgentLogic.modelName("other") == "other", "names")
        check(AgentRequest.prompt(text: "x", cwd: "/", sessionID: nil, model: "claude-haiku-5-5").line.contains(#""model":"claude-haiku-5-5""#), "sent")
    }),

    ("agent: Auto asks the local model for a tier with a schema and parses its answer", {
        let model = (AgentLogic.routeSchema["properties"] as? [String: Any])?["model"] as? [String: Any]
        check(model?["enum"] as? [String] == ["haiku", "sonnet", "opus"], "schema")
        let user = AgentLogic.routeUser(prompt: "Refactor @a.swift", signals: .init(mentions: 1, isReview: true, turns: 2))
        check(user.contains("Referenced files: 1") && user.contains("review: yes") && user.contains("turns in this session: 2"), user)
        check(AgentLogic.routeTier(fromAnswer: #"{"model": "opus"}"#) == "opus", "opus")
        check(AgentLogic.routeTier(fromAnswer: #"{"model":"gpt"}"#) == nil, "unknown tier")
        check(AgentLogic.routeTier(fromAnswer: "nope") == nil, "garbage")
    }),

    ("agent: Auto falls back to Sonnet and does not downgrade a follow-up", {
        let opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
        check(AgentLogic.routedModel(tier: "haiku", previous: nil, prompt: "what branch") == haiku, "classified")
        check(AgentLogic.routedModel(tier: nil, previous: nil, prompt: "x") == sonnet, "no answer means Sonnet")
        check(AgentLogic.routedModel(tier: "haiku", previous: opus, prompt: "continue") == opus, "a follow-up keeps Opus")
        check(AgentLogic.routedModel(tier: "haiku", previous: opus, prompt: "Fix it.") == opus, "fix it")
        check(AgentLogic.routedModel(tier: "haiku", previous: opus, prompt: "what is the time zone of the server config") == haiku, "a new question")
        check(AgentLogic.routedModel(tier: "opus", previous: haiku, prompt: "continue") == opus, "a follow-up may go up")
        check(AgentLogic.isFollowUp("ok, go ahead") && !AgentLogic.isFollowUp("continue the refactor of the whole store layer across all files"), "heuristic")
        try blocking {
            let picked = await AgentLogic.route(prompt: "rename across files", signals: .init(), previous: nil) { system, user in
                check(system == AgentLogic.routeSystem && user.contains("rename across files"), "the prompt is sent")
                return #"{"model":"opus"}"#
            }
            check(picked == opus, "a mocked model picks Opus: \(picked)")
            let down = await AgentLogic.route(prompt: "x", signals: .init(), previous: nil) { _, _ in throw LocalLLMError.notInstalled }
            check(down == sonnet, "no local model means Sonnet")
            let start = Date()
            let slow = await AgentLogic.route(prompt: "x", signals: .init(), previous: nil, timeout: 0.2) { _, _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ""
            }
            check(slow == sonnet && Date().timeIntervalSince(start) < 2, "a slow model times out to Sonnet")
        }
    }),

    ("agent: requests encode as single JSON lines", {
        let prompt = AgentRequest.prompt(text: "hi\nthere", cwd: "/repo", sessionID: "s1").line
        check(prompt.hasSuffix("\n") && prompt.dropLast().contains("\n") == false, "one line")
        check(prompt == #"{"cwd":"/repo","permissionMode":"default","sessionId":"s1","text":"hi\nthere","type":"prompt"}"# + "\n", "prompt \(prompt)")
        check(!AgentRequest.prompt(text: "x", cwd: "/", sessionID: nil).line.contains("sessionId"), "no session on a new one")
        check(AgentRequest.permission(id: "4", allow: false).line == #"{"allow":false,"id":"4","type":"permission"}"# + "\n", "permission")
        check(AgentRequest.interrupt.line == #"{"type":"interrupt"}"# + "\n", "interrupt")
    }),

    ("agent: Claude in Chrome is off unless saved for the agent, sent with the prompt, and its connection decoded", {
        check(!AgentLogic.chromeEnabled(nil, key: "a") && !AgentLogic.chromeEnabled(["b": true], key: "a"), "off by default")
        check(AgentLogic.chromeEnabled(["a": true], key: "a"), "saved per agent")
        check(AgentRequest.prompt(text: "x", cwd: "/", sessionID: nil, chrome: true).line.contains(#""chrome":true"#), "sent when on")
        check(!AgentRequest.prompt(text: "x", cwd: "/", sessionID: nil).line.contains("chrome"), "left out when off")
        check(AgentEvent.decode(#"{"type":"chrome","connected":true}"#, cwd: "/") == .chrome(problem: nil), "connected")
        check(AgentEvent.decode(#"{"type":"chrome","connected":false,"message":"Browser extension is not connected."}"#, cwd: "/")
              == .chrome(problem: "Browser extension is not connected."), "not connected")
        var items: [AgentItem] = []
        check(AgentLogic.apply(.chrome(problem: "x"), to: &items) == nil && items.isEmpty, "not a transcript item")
    }),

    ("agent: always-allow rules decode from the sidecar, are stored and shown with warnings", {
        let fetch = AgentRule(kind: .bash, value: "git fetch"), test = AgentRule(kind: .bash, value: "npm test")
        let line = #"{"type":"permission_request","id":"5","tool":"Bash","input":{"command":"git fetch && npm test"},"#
            + #""offer":[{"kind":"bash","value":"git fetch"},{"kind":"bash","value":"npm test"},{"kind":"nope","value":"x"}]}"#
        guard case .permissionRequest(_, _, _, _, let offer)? = AgentEvent.decode(line, cwd: cwd) else { return check(false, "decodes") }
        check(offer == [fetch, test], "offer \(offer)")
        check(AgentEvent.decode(#"{"type":"tool_result","id":"t","content":"x","auto":true,"rule":"git fetch"}"#, cwd: cwd)
              == .toolResult(id: "t", content: "x", isError: false, auto: true, rule: "git fetch"), "allowed by a rule")
        check(AgentRequest.rules([fetch]).line == #"{"rules":[{"kind":"bash","value":"git fetch"}],"type":"rules"}"# + "\n", "rules line")

        let stored = AgentRules.adding([test, fetch, test], to: [fetch])
        check(stored == [fetch, test], "no duplicates, order kept \(stored)")
        check(AgentRules.decode(AgentRules.encode(stored)) == stored, "round trip")
        check(AgentRules.decode(Data("junk".utf8)).isEmpty && AgentRules.decode(nil).isEmpty, "bad data is empty")

        check(AgentRules.offer([fetch, test]) == "Always allow: git fetch, npm test", "bash offer")
        check(AgentRules.offer([AgentRule(kind: .edits, value: NSHomeDirectory() + "/git/x")]) == "Always allow edits in ~/git/x", "edits offer")
        check(AgentRules.offer([AgentRule(kind: .tool, value: "mcp__worktime__github_pr")]) == "Always allow WorkTime \u{00B7} GitHub PR", "tool offer")
        check(AgentRules.offer([]) == nil, "nothing offered")
        check(AgentRules.label(AgentRule(kind: .edits, value: "/tmp/x")) == "Edits in /tmp/x", "edits label")

        check(AgentRules.warning([fetch, test]) == nil, "safe rules")
        for value in ["rm", "sudo", "git push", "git reset", "git", "sh", "rm -rf"] {
            check(AgentRules.warning([fetch, AgentRule(kind: .bash, value: value)])?.hasPrefix(value + " will") == true, "warns for \(value)")
        }
        check(AgentRules.warning([AgentRule(kind: .edits, value: "/")]) == nil && AgentRules.warning([AgentRule(kind: .bash, value: "rmdir")]) == nil,
              "only dangerous bash commands")
    }),

    ("agent: the transcript fills in tool results, answers permissions and keeps the session", {
        var items: [AgentItem] = []
        check(AgentLogic.apply(.session("s1"), to: &items) == "s1" && items.isEmpty, "session is returned, not shown")
        AgentLogic.apply(.toolUse(id: "t", tool: "Bash", summary: "ls", detail: ""), to: &items)
        AgentLogic.apply(.toolResult(id: "t", content: "a\nb", isError: true, auto: true), to: &items)
        check(items.first?.kind == .tool(name: "Bash", summary: "ls", detail: "", result: "a\nb", isError: true, auto: true), "result filled in")
        AgentLogic.apply(.permissionRequest(id: "9", tool: "Edit", summary: "x", detail: ""), to: &items)
        let permission = items[1]
        check(AgentLogic.permissionID(of: permission.id) == "9", "permission id \(permission.id)")
        AgentLogic.answer(permission.id, allow: false, in: &items)
        check(items[1].kind == .permission(tool: "Edit", summary: "x", detail: "", allowed: false), "answered")
        AgentLogic.answer(permission.id, allow: true, in: &items)
        check(items[1].kind == .permission(tool: "Edit", summary: "x", detail: "", allowed: false), "answered only once")
        let edits = [AgentRule(kind: .edits, value: "/repo")]
        AgentLogic.apply(.permissionRequest(id: "10", tool: "Edit", summary: "y", detail: "", offer: edits), to: &items)
        AgentLogic.answer(items[2].id, allow: true, in: &items)
        check(items[2].kind == .permission(tool: "Edit", summary: "y", detail: "", offer: edits, allowed: true), "the offer is kept when answered")
        items.remove(at: 2)
        check(AgentLogic.apply(.result(sessionID: "s2", isError: false, text: "", turns: 1, model: nil), to: &items) == "s2", "result session")
        check(items.last?.kind == .status("Done \u{00B7} 1 turn"), "status \(String(describing: items.last))")
        AgentLogic.apply(.result(sessionID: "s2", isError: false, text: "", turns: 4, model: "claude-sonnet-5-5"), to: &items, auto: true)
        check(items.last?.kind == .status("Done \u{00B7} 4 turns \u{00B7} Auto \u{2192} Sonnet 5.5"), "auto status \(String(describing: items.last))")
        AgentLogic.apply(.result(sessionID: "s2", isError: false, text: "", turns: 2, model: "claude-opus-5-5"), to: &items)
        check(items.last?.kind == .status("Done \u{00B7} 2 turns \u{00B7} Opus 5.5"), "fixed model status")
        AgentLogic.apply(.result(sessionID: nil, isError: true, text: "Context window exceeded", turns: 1, model: nil), to: &items)
        check(items.last?.kind == .error("Context window exceeded"), "error result")
        check(Set(items.map(\.id)).count == items.count, "ids are unique")
    }),

    ("agent: an auth failure from the sidecar asks for a sign-in once", {
        check(AgentEvent.decode(#"{"type":"error","message":"Not logged in · Please run /login","auth":true}"#, cwd: cwd) == .signIn, "auth flag")
        check(AgentEvent.decode(#"{"type":"error","message":"Invalid API key · Please run /login"}"#, cwd: cwd) == .signIn, "auth text")
        check(AgentEvent.decode(#"{"type":"error","message":"The agent is still working."}"#, cwd: cwd) == .error("The agent is still working."), "other")
        check(AgentLogic.needsSignIn("OAuth token has expired. Please obtain a new token"), "expired sign-in")
        check(!AgentLogic.needsSignIn("Rate limit reached"), "rate limit is not a sign-in")
        var items: [AgentItem] = []
        AgentLogic.apply(.signIn, to: &items)
        AgentLogic.apply(.result(sessionID: "s", isError: true, text: "Not logged in · Please run /login", turns: 1, model: nil), to: &items)
        check(items.map(\.kind) == [.signIn], "one sign-in item \(items)")
        check(AgentLogic.signInMessage == "Sign in to Claude: run `claude` in Terminal and use /login once.", "message")
    }),

    ("agent: the sidecar never gets an API key and uses the Claude Code sign-in on this Mac", {
        let base = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-ant-api03-x", "ANTHROPIC_AUTH_TOKEN": "y", "HOME": "/Users/me"]
        let plain = AgentLogic.childEnvironment(base, nodeFolder: "/opt/node/bin", mcpCommand: "/App/WorkTime")
        check(plain["ANTHROPIC_API_KEY"] == nil && plain["ANTHROPIC_AUTH_TOKEN"] == nil, "keys removed")
        check(plain["CLAUDE_CODE_OAUTH_TOKEN"] == nil && plain["HOME"] == "/Users/me", "the Claude Code sign-in")
        check(plain["PATH"]?.hasPrefix("/opt/node/bin:/usr/bin:") == true && plain["WORKTIME_MCP_COMMAND"] == "/App/WorkTime", "path and mcp")
        let redacted = SecretRedaction.redact("401 for sk-ant-oat01-SECRET-part", key: nil)
        check(!redacted.contains("SECRET"), "OAuth tokens are redacted: \(redacted)")
    }),

    ("agent: node is looked for on the PATH, Homebrew, then the newest nvm", {
        let home = URL(fileURLWithPath: "/Users/me")
        let candidates = AgentLogic.nodeCandidates(path: "/usr/bin:/opt/homebrew/bin", home: home, nvmVersions: ["v9.0.0", "v24.1.0", "v18.2.0"]).map(\.path)
        check(candidates == ["/usr/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node", "/Users/me/.nvm/versions/node/v24.1.0/bin/node",
                             "/Users/me/.nvm/versions/node/v18.2.0/bin/node", "/Users/me/.nvm/versions/node/v9.0.0/bin/node"], "\(candidates)")
        let sidecar = AgentLogic.sidecarCandidates(environment: ["WORKTIME_AGENT_DIR": "/x"], resources: URL(fileURLWithPath: "/App/Resources"),
                                                   sourceFile: "/src/worktime/Sources/WorkTime/AgentClient.swift").map(\.path)
        check(sidecar == ["/x/dist/main.js", "/App/Resources/agent/dist/main.js", "/src/worktime/agent/dist/main.js"], "\(sidecar)")
    }),

    ("agent: @ mentions are picked while typing and listed by absolute path on send", {
        check(AgentLogic.mentionQuery("look at @Sou") == "Sou", "query")
        check(AgentLogic.mentionQuery("look at @") == "", "empty query right after @")
        check(AgentLogic.mentionQuery("mail me@x.com") == nil, "email is not a mention")
        check(AgentLogic.mentionQuery("@a.swift and more") == nil, "a finished mention")
        check(AgentLogic.insertMention("Sources/App.swift", into: "see @app") == "see @Sources/App.swift ", "insert")
        check(AgentLogic.fuzzyMatches("app", in: ["docs/apple.md", "Sources/App.swift", "lib/a/p/p.txt", "README.md"])
              == ["docs/apple.md", "Sources/App.swift", "lib/a/p/p.txt"], "fuzzy order")
        check(AgentLogic.mentions(in: "fix @Sources/App.swift:10-40 and @README.md, cc me@x.com")
              == [.init(path: "Sources/App.swift", lines: 10...40), .init(path: "README.md", lines: nil)], "mentions")
        let expanded = AgentLogic.expandMentions("fix @Sources/App.swift:12 and @missing.txt", cwd: cwd, exists: exists)
        check(expanded.hasSuffix("Referenced files (read them as needed):\n- /repo/Sources/App.swift (line 12)"), expanded)
        check(AgentLogic.expandMentions("no mentions", cwd: cwd, exists: exists) == "no mentions", "unchanged")
    }),

    ("agent: file:line references and Markdown file links in replies open the file", {
        let text = AgentLogic.linkifiedCodeReferences("See `Sources/App.swift:12` and /abs/Tool.swift:3, not v1.2:3 or nope.swift:4.", cwd: cwd, exists: exists)
        check(text.contains("[`Sources/App.swift:12`](worktime-code://open?path=/repo/Sources/App.swift&line=12)"), text)
        check(text.contains("[/abs/Tool.swift:3](worktime-code://open?path=/abs/Tool.swift&line=3)"), text)
        check(text.contains("nope.swift:4") && !text.contains("path=/repo/nope.swift"), "missing files stay text")
        let link = AgentLogic.linkifiedCodeReferences("[main](agent/src/main.ts#L93) [web](https://x.com/a.ts:1)", cwd: cwd, exists: exists)
        check(link == "[main](worktime-code://open?path=/repo/agent/src/main.ts&line=93) [web](https://x.com/a.ts:1)", link)
        let fenced = "```\nSources/App.swift:1\n```"
        check(AgentLogic.linkifiedCodeReferences(fenced, cwd: cwd, exists: exists) == fenced, "code blocks untouched")
        let labelled = AgentLogic.linkifiedCodeReferences("[Sources/App.swift:2](Sources/App.swift:2)", cwd: cwd, exists: exists)
        check(labelled == "[Sources/App.swift:2](worktime-code://open?path=/repo/Sources/App.swift&line=2)", labelled)
        let target = AgentLogic.codeTarget(URL(string: AgentLogic.codeURL(path: "/a b/c.swift", line: 7))!)
        check(target?.path == "/a b/c.swift" && target?.line == 7, "round trip \(String(describing: target))")
        check(AgentLogic.codeTarget(URL(string: "https://x.com")!) == nil, "other links pass through")
    }),

    ("agent: files open in Xcode, a --goto editor, or the default app", {
        let code = URL(fileURLWithPath: "/usr/local/bin/code")
        let swift = AgentLogic.openCommand(path: "/r/A.swift", line: 4, hasXcode: true, gotoCLI: code)
        check(swift.executable.path == "/usr/bin/xed" && swift.arguments == ["--line", "4", "/r/A.swift"], "xed")
        let ts = AgentLogic.openCommand(path: "/r/a.ts", line: 4, hasXcode: true, gotoCLI: code)
        check(ts.executable == code && ts.arguments == ["--goto", "/r/a.ts:4"], "goto")
        let plain = AgentLogic.openCommand(path: "/r/A.swift", line: nil, hasXcode: false, gotoCLI: nil)
        check(plain.executable.path == "/usr/bin/open" && plain.arguments == ["/r/A.swift"], "open")
    }),
]
