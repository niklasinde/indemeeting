import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_792_300_000)
private let pull = "https://github.com/acme/api/pull/7"
private let session = "0b6f7c2e-1d2a-4c3b-9e8f-112233445566"

private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func item(_ id: String, _ kind: AgentItem.Kind) -> AgentItem { AgentItem(id: id, kind: kind) }

/// A Claude Code transcript: a prompt, a skipped meta line and command wrapper, thinking, a tool call and its output, the answer.
let transcriptFixture = [
    #"{"type":"queue-operation","operation":"enqueue"}"#,
    #"{"type":"user","cwd":"/repo","message":{"role":"user","content":"Review https://github.com/acme/api/pull/7"}}"#,
    #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: meta"}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-name>/clear</command-name>"}]}}"#,
    #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret plan"}]}}"#,
    #"{"type":"assistant","cwd":"/repo","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/repo/Sources/App.swift"}}]}}"#,
    #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"let body = 1"}]}}"#,
    #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent chatter"}]}}"#,
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looks good, one nit in App.swift:3."}]}}"#,
    "not json",
].joined(separator: "\n")

let agentOverviewTests: [(name: String, run: () throws -> Void)] = [
    ("agents: Main sends its system prompt, and agent links in its replies stay links", {
        let line = AgentRequest.prompt(text: "hi", cwd: "/repos", sessionID: nil, appendSystemPrompt: "Be Main").line
        check(line.contains(#""appendSystemPrompt":"Be Main""#), line)
        check(!AgentRequest.prompt(text: "hi", cwd: "/repos", sessionID: nil).line.contains("appendSystemPrompt"), "others send none")
        check(AgentLogic.mainSystemPrompt.contains("attention") && AgentLogic.mainSystemPrompt.contains("send_to_agent"), "tools named")
        let reply = "- [acme/api#7](\(pull)) \u{00B7} [agent](\(GitHubLink.agentLink(for: pull)))"
        check(AgentLogic.linkifiedCodeReferences(reply, cwd: "/repos") { _ in true } == reply, "untouched")
        check(GitHubLink.parseAgent(GitHubLink.agentLink(for: pull))?.url == pull, "the link opens that pull request's agent")
    }),

    ("agents: the snapshot reads status, pending tool, last prompt and reply from the transcript", {
        let items = [item("user-0", .user("First")), item("text-1", .text("Old reply")), item("user-2", .user("Fix the tests")),
                     item("text-3", .text("Running them")), item("permission-1-4", .permission(tool: "Bash", summary: "swift test", detail: "", allowed: nil))]
        let waiting = AgentOverview.snapshot(key: pull, title: "t", prURL: pull, folder: "/repo", sessionID: session, items: items,
                                             busy: true, seen: true, updatedAt: now)
        check(waiting.status == .waiting && waiting.pendingTool == "Bash" && waiting.pendingInput == "swift test", "\(waiting)")
        check(waiting.lastPrompt == "Fix the tests" && waiting.lastResult == "Running them", "last prompt and reply")
        let working = AgentOverview.snapshot(key: "k", title: "t", prURL: nil, folder: "/", sessionID: nil, items: Array(items.prefix(3)),
                                             busy: true, seen: true, updatedAt: nil)
        check(working.status == .working && working.lastResult == nil, "no reply since the last prompt: \(working)")
        let failed = AgentOverview.snapshot(key: "k", title: "t", prURL: nil, folder: "/", sessionID: nil,
                                            items: items.prefix(2) + [item("error-2", .error("boom"))], busy: false, seen: true, updatedAt: nil)
        check(failed.status == .error && failed.error == "boom", "error")
        let signedOut = AgentOverview.snapshot(key: "k", title: "t", prURL: nil, folder: "/", sessionID: nil, items: [item("signin-0", .signIn)],
                                               busy: false, seen: true, updatedAt: nil)
        check(signedOut.status == .signedOut, "signed out")
        let long = AgentOverview.snapshot(key: "k", title: "t", prURL: nil, folder: "/", sessionID: nil,
                                          items: [item("user-0", .user("q")), item("text-1", .text(String(repeating: "a", count: 5000)))],
                                          busy: false, seen: false, updatedAt: nil)
        check(long.status == .idle && long.lastResult?.count == AgentOverview.resultLimit, "reply truncated")
    }),

    ("agents: saved sessions that are not loaded join as idle, and the most urgent sort first", {
        let loaded = [AgentState(key: "main", title: "Main", status: .idle, lastResult: "done", updatedAt: now, seen: true),
                      AgentState(key: pull, title: "a", prURL: pull, status: .working, updatedAt: now),
                      AgentState(key: "b", title: "b", prURL: "https://github.com/acme/web/pull/3", status: .idle, lastResult: "fixed",
                                 updatedAt: now.addingTimeInterval(-60), seen: false),
                      AgentState(key: "c", title: "c", prURL: "https://github.com/acme/web/pull/4", status: .waiting, pendingTool: "Edit",
                                 updatedAt: now.addingTimeInterval(-3600))]
        let all = AgentOverview.withPersisted(loaded, sessions: [pull: "x", "https://github.com/acme/ops/pull/9": session])
        check(all.count == 5, "one persisted added, the loaded one not repeated: \(all.map(\.key))")
        let saved = all.last!
        check(saved.title == "acme/ops#9" && saved.sessionID == session && !saved.loaded && saved.status == .idle, "\(saved)")
        check(AgentOverview.sorted(all).map(\.title) == ["c", "b", "a", "Main", "acme/ops#9"], "\(AgentOverview.sorted(all).map(\.title))")
        check(AgentOverview.need(all[2]) == .unseen && AgentOverview.need(all[0]) == .idle, "unseen needs a reply that was not seen")
    }),

    ("agents: the state file round-trips and reads as Markdown with links", {
        let agents = [AgentState(key: pull, title: "acme/api#7 Fix", prURL: pull, folder: "/repo", sessionID: session, status: .waiting,
                                 pendingTool: "Bash", pendingInput: "rm -rf build", lastPrompt: "clean\nup", updatedAt: now.addingTimeInterval(-120))]
        let data = AgentOverview.encode(agents, now: now)
        let file = AgentOverview.decode(data)
        check(file?.agents == agents && file?.written == now, "round trip")
        check(String(decoding: data, as: UTF8.self).contains("\"prURL\" : \"https://github.com/acme/api/pull/7\""), "slashes kept readable")
        let text = AgentOverview.markdown(file!, now: now)
        check(text.contains("- **acme/api#7 Fix** \u{00B7} Waiting for your permission \u{00B7} asks to run Bash: rm -rf build"), text)
        check(text.contains(GitHubLink.agentLink(for: pull)) && text.contains("session: \(session)") && text.contains("last prompt: clean / up"), text)
        check(AgentOverview.markdown(.init(written: now, agents: []), now: now, active: true) == "No agent needs you.\n", "empty")
        check(AgentOverview.decode(Data("{}".utf8)) == nil, "garbage")
    }),

    ("agents: a transcript keeps prompts, replies and one-line tool calls, and is cut from the start", {
        let entries = AgentTranscript.entries(jsonl: transcriptFixture)
        check(entries == ["User: Review https://github.com/acme/api/pull/7", "Tool: Read \u{2014} Sources/App.swift",
                          "Result: Looks good, one nit in App.swift:3."], "\(entries)")
        let full = AgentTranscript.compact(jsonl: transcriptFixture)
        check(!full.contains("secret plan") && !full.contains("let body") && !full.contains("subagent"), full)
        let cut = AgentTranscript.compact(jsonl: transcriptFixture, maxChars: 60)
        check(cut.hasPrefix("[2 earlier entries cut]") && cut.contains("Result: Looks good"), cut)
        check(AgentTranscript.compact(jsonl: "").hasPrefix("The session has no prompts"), "empty")
    }),

    ("agents: a session's transcript is found by its folder, or in any project folder", {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("-Users-me-git-app--claude-x", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent(session + ".jsonl"))
        check(ClaudeTranscripts.folderName(cwd: "/Users/me/git/app/.claude/x") == folder.lastPathComponent, "path scheme")
        check(AgentTranscript.url(sessionID: session, cwd: "/Users/me/git/app/.claude/x", root: root)?.lastPathComponent == session + ".jsonl", "by cwd")
        check(AgentTranscript.url(sessionID: session, cwd: "/elsewhere", root: root) != nil, "by scanning")
        check(AgentTranscript.url(sessionID: session, cwd: nil, root: root) != nil, "without a folder")
        check(AgentTranscript.url(sessionID: "../etc", cwd: nil, root: root) == nil, "only session ids")
    }),

    ("agents: inbox requests are checked for url, length and age, and queue behind a busy agent", {
        let id = UUID().uuidString
        guard case .success(let request) = AgentInbox.request(prURL: " \(pull) ", text: " Rebase it \n", now: now, id: id) else {
            return check(false, "valid request")
        }
        check(request.prURL == pull && request.text == "Rebase it", "trimmed")
        check(AgentInbox.request(prURL: "https://example.com", text: "x", now: now) == .failure(AgentInboxError(
            "pr_url must be a GitHub pull request url, not https://example.com.")), "url")
        check(AgentInbox.request(prURL: pull, text: "  ", now: now) == .failure(AgentInboxError("text is empty.")), "empty")
        if case .success = AgentInbox.request(prURL: pull, text: String(repeating: "a", count: AgentInbox.textLimit + 1), now: now) {
            check(false, "too long is refused")
        }
        check(AgentInbox.problem(request, now: now.addingTimeInterval(AgentInbox.staleAfter + 1)) != nil, "stale")
        check(AgentInbox.problem(AgentInbox.Request(id: "../x", prURL: pull, text: "a", created: now), now: now) != nil, "id must be a UUID")
        check(AgentInbox.decide(busy: false, waitingForPermission: false, queued: 0) == .start, "idle starts")
        check(AgentInbox.decide(busy: true, waitingForPermission: false, queued: 0) == .queue, "busy queues")
        check(AgentInbox.decide(busy: false, waitingForPermission: false, queued: 1) == .queue, "keeps the order behind queued ones")
        if case .reject = AgentInbox.decide(busy: true, waitingForPermission: true, queued: 0) {} else { check(false, "waiting refuses") }
        if case .reject = AgentInbox.decide(busy: true, waitingForPermission: false, queued: AgentInbox.queueLimit) {} else {
            check(false, "a full queue refuses")
        }
        check(AgentInbox.fromMain(AgentInbox.prompt("Hi")) == "Hi" && AgentInbox.fromMain("Hi") == nil, "from Main")
        let decoded = AgentInbox.decode(AgentInbox.Request.self, from: AgentInbox.encode(request))
        check(decoded == request, "request round trip")
    }),

    ("agents: the MCP tools read the state file and transcripts, and send_to_agent waits for the app's reply", {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("agents.json"), inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let folder = ClaudeTranscripts.folder(cwd: "/repo", root: projects)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(transcriptFixture.utf8).write(to: folder.appendingPathComponent(session + ".jsonl"))
        try AgentOverview.encode([AgentState(key: pull, title: "acme/api#7", prURL: pull, folder: "/repo", sessionID: session, status: .idle,
                                             lastResult: "Looks good", updatedAt: now, seen: false)], now: now).write(to: state)
        var sources = MCPServer.AgentSources(stateFile: state, inbox: inbox, projects: projects, replyTimeout: 3)
        sources.slack = { "- DM from Anna: hi\n" }
        let tools = MCPServer.agentTools(.failure(MCPToolError("no db")), sources: sources, now: { now })
        func run(_ name: String, _ args: [String: Any] = [:]) -> Result<String, Error> {
            Result { try tools.first { $0.name == name }!.run(args) }
        }
        check(tools.map(\.name) == ["agents_overview", "agent_session", "attention", "send_to_agent"], "\(tools.map(\.name))")
        let readOnly = tools.map { ($0.listing["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool }
        check(readOnly == [true, true, true, false], "only send_to_agent acts: \(readOnly)")
        let overview = (try? run("agents_overview").get()) ?? ""
        check(overview.contains("Finished, not seen yet") && overview.contains("last result: Looks good"), overview)
        let byPR = (try? run("agent_session", ["pr_url": pull]).get()) ?? ""
        check(byPR.hasPrefix("Session \(session)") && byPR.contains("Tool: Read \u{2014} Sources/App.swift"), byPR)
        check((try? run("agent_session", ["session_id": session]).get()) == byPR, "by session id")
        check((try? run("agent_session", ["pr_url": "https://github.com/acme/api/pull/8"]).get()) == nil, "unknown agent")
        let attention = (try? run("attention").get()) ?? ""
        check(attention.contains("## Agents") && attention.contains("acme/api#7") && attention.contains("## Slack\n- DM from Anna"), attention)
        check(!attention.contains("## Meeting action items"), "skipped without a database")

        let app = Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
                if let name = names.first(where: AgentInbox.isRequest),
                   let data = try? Data(contentsOf: inbox.appendingPathComponent(name)),
                   let request = AgentInbox.decode(AgentInbox.Request.self, from: data) {
                    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
                    let reply = AgentInbox.Reply(id: request.id, status: request.text == "busy" ? .queued : .started, sessionID: session, message: "")
                    try? AgentInbox.encode(reply).write(to: inbox.appendingPathComponent(AgentInbox.replyName(request.id)))
                    if request.text == "busy" { return }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        app.start()
        let sent = (try? run("send_to_agent", ["pr_url": pull, "text": "Rebase it"]).get()) ?? ""
        check(sent.hasPrefix("Sent to the agent on acme/api#7") && sent.contains("Session: \(session)"), sent)
        let queued = (try? run("send_to_agent", ["pr_url": pull, "text": "busy"]).get()) ?? ""
        check(queued.hasPrefix("Queued for the agent on acme/api#7"), queued)
        check((try? run("send_to_agent", ["pr_url": "nope", "text": "x"]).get()) == nil, "bad url refused before the app is asked")
        let quiet = MCPServer.agentTools(.failure(MCPToolError("no db")),
                                         sources: MCPServer.AgentSources(stateFile: state, inbox: inbox, projects: projects, replyTimeout: 0.3,
                                                                         slack: { nil }), now: { now })
        let timedOut = Result { try quiet.first { $0.name == "send_to_agent" }!.run(["pr_url": pull, "text": "anyone?"]) }
        if case .failure(let error) = timedOut {
            check(error.localizedDescription.contains("Is the app running?"), error.localizedDescription)
        } else {
            check(false, "no reply times out")
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        check(left.isEmpty, "requests and replies are cleaned up: \(left)")
    }),
]
