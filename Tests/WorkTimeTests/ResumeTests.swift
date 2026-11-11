import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
private let hour: TimeInterval = 3600
private let api = ResumeContextKey(repo: "finq.api", branch: "NI/QDLY-1234", ticket: "QDLY-1234")
private let prURL = "https://github.com/quiddly-com/finq.api/pull/57"

private func block(_ start: TimeInterval, _ end: TimeInterval, repo: String? = "finq.api", branch: String? = "NI/QDLY-1234",
                   ticket: String? = nil, url: String? = nil, focus: ClaudeSession? = nil, prompt: String? = nil, idle: Bool = false) -> ActivityBlock {
    var block = ActivityBlock(id: Int64(start), start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
                              key: ActivityKey(appBundle: "com.app", appName: "App", windowTitle: nil, url: url, repo: repo, branch: branch,
                                               ticket: ticket, claude: focus.map { [$0] } ?? [], idle: idle, claudeFocus: focus?.id))
    block.claudePrompt = prompt
    return block
}

private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

private func userLine(_ text: String, _ offset: TimeInterval, meta: Bool = false) -> String {
    let stamp = at(offset).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    let object: [String: Any] = ["type": "user", "timestamp": stamp, "isMeta": meta, "cwd": "/Users/me/git/finq.api",
                                 "message": ["role": "user", "content": text]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func comment(_ id: String, _ author: String, _ body: String, _ offset: TimeInterval, bot: Bool = false) -> GitHubComment {
    GitHubComment(id: id, author: GitHubActivity.Actor(login: author, isBot: bot), body: body, parts: [], created: at(offset))
}

let resumeTests: [(name: String, run: () throws -> Void)] = [
    ("resume: a block's context is its branch, else its ticket, and matches the branch or anything on the ticket", {
        let branch = block(0, 60).key
        check(ResumeContextKey.of(branch) == api && ResumeContextKey.of(branch)?.ticket == "QDLY-1234", "branch with ticket from its name")
        let jira = block(0, 60, repo: nil, branch: nil, ticket: "QDLY-1234").key
        check(ResumeContextKey.of(jira)?.id == "QDLY-1234", "ticket alone")
        check(ResumeContextKey.of(block(0, 60, idle: true).key) == nil, "idle has none")
        check(ResumeContextKey.of(block(0, 60, repo: "x", branch: nil).key) == nil, "a repository without branch or ticket has none")
        check(api.matches(jira), "the Jira page counts for the branch")
        check(!api.matches(block(0, 60, branch: "main").key), "another branch does not")
        check(ResumeContextKey(repo: "finq.api", branch: "NI/QDLY-1234", ticket: nil) == api, "same id with or without ticket")
    }),

    ("resume: the trigger fires once after 30 s in a new context, ignores short flicks and context-less samples", {
        var trigger = ResumeTrigger()
        let other = ResumeContextKey(repo: "finq.admin-ui", branch: "develop")
        check(trigger.observe(api, at: at(0), gap: 2 * hour) == nil, "not yet")
        check(trigger.observe(api, at: at(25), gap: 2 * hour) == nil, "25 s is not steady")
        check(trigger.observe(nil, at: at(28), gap: 2 * hour) == nil, "another app")
        let fired = trigger.observe(api, at: at(30), gap: 2 * hour)
        check(fired?.key == api && fired?.entered == at(0), "fires with the time it was entered")
        check(trigger.observe(api, at: at(60), gap: 2 * hour) == nil, "only once")
        _ = trigger.observe(other, at: at(70), gap: 2 * hour)
        check(trigger.observe(api, at: at(80), gap: 2 * hour) == nil, "a 10 s detour")
        check(trigger.observe(api, at: at(200), gap: 2 * hour) == nil, "coming back from a flick is not a switch")
        check(trigger.observe(other, at: at(300), gap: 2 * hour) == nil, "")
        check(trigger.observe(other, at: at(330), gap: 2 * hour)?.key == other, "a settled switch fires")
        check(trigger.observe(nil, at: at(400), gap: 2 * hour) == nil, "away")
        check(trigger.observe(other, at: at(400 + 3 * hour), gap: 2 * hour) == nil, "back after the gap")
        check(trigger.observe(other, at: at(430 + 3 * hour), gap: 2 * hour)?.entered == at(400 + 3 * hour), "fires again after the gap with nothing between")
    }),

    ("resume: the last visit merges nearby blocks, stops at the current visit and keeps sessions and prompts", {
        let session = ClaudeSession(id: "s1", folder: "/Users/me/git/finq.api", title: "Fix the voucher")
        let blocks = [
            block(-30 * hour, -29 * hour),
            block(-5 * hour, -4.5 * hour, focus: session, prompt: "add a test for the rounding"),
            block(-4.4 * hour, -4 * hour, repo: nil, branch: nil, ticket: "QDLY-1234", url: "acme.atlassian.net/browse/QDLY-1234"),
            block(-3 * hour, -2 * hour, branch: "main"),
            block(0, 60, prompt: "now"),
        ]
        let visit = ResumeLogic.lastVisit(blocks, key: api, before: t0)
        check(visit?.start == at(-5 * hour) && visit?.end == at(-4 * hour), "two blocks 6 minutes apart are one visit")
        check(abs((visit?.active ?? 0) - 0.9 * hour) < 1, "active time sums the blocks")
        check(visit?.sessions == [session] && visit?.prompts == ["add a test for the rounding"], "session and prompt")
        check(ResumeLogic.shouldShow(visit, entered: t0, gap: 2 * hour), "4 h away shows")
        check(!ResumeLogic.shouldShow(visit, entered: t0, gap: 8 * hour), "8 h threshold does not")
        check(!ResumeLogic.shouldShow(nil, entered: t0, gap: hour), "never here does not")
        let straddling = ResumeLogic.lastVisit([block(-hour, 600)], key: api, before: t0)
        check(straddling?.end == t0, "a block running past the arrival is cut at it")
    }),

    ("resume: contexts from tool arguments", {
        let blocks = [block(-hour, -0.5 * hour), block(-0.4 * hour, -0.2 * hour, repo: "finq.admin-ui", branch: "NI/QDLY-77")]
        check(ResumeLogic.latestContext(blocks)?.id == "finq.admin-ui@NI/QDLY-77", "latest")
        check(ResumeLogic.context(repo: "quiddly-com/finq.api", branch: nil, ticket: nil, blocks: blocks) == api, "repository's latest branch")
        check(ResumeLogic.context(repo: nil, branch: "NI/QDLY-1234", ticket: nil, blocks: blocks)?.repo == "finq.api", "branch finds its repository")
        check(ResumeLogic.context(repo: nil, branch: nil, ticket: "QDLY-5", blocks: blocks)?.id == "QDLY-5", "ticket")
        check(ResumeLogic.context(repo: "nowhere", branch: nil, ticket: nil, blocks: blocks) == nil, "unknown repository")
    }),

    ("resume: prompts are read from a transcript up to the end of the visit, newest first, without meta entries", {
        let jsonl = [userLine("first question", -5 * hour), userLine("<system-reminder>x</system-reminder>caveat", -4.8 * hour, meta: true),
                     userLine("second question\nwith a line", -4.5 * hour), userLine("after I left", -hour)].joined(separator: "\n")
        let prompts = ResumeLogic.prompts(inJSONL: jsonl, until: at(-4 * hour))
        check(prompts.map(\.text) == ["second question with a line", "first question"], "\(prompts.map(\.text))")
    }),

    ("resume: the pull request is found by head branch, else by ticket, and only in the context's repository", {
        let byHead = GitHubPR(url: prURL, number: 57, title: "Fix rounding", repo: "quiddly-com/finq.api", updated: at(-hour))
        let byTitle = GitHubPR(url: prURL + "0", number: 570, title: "QDLY-1234: Fix rounding", repo: "quiddly-com/finq.api", updated: at(0))
        let elsewhere = GitHubPR(url: "https://github.com/quiddly-com/finq.admin-ui/pull/1", number: 1, title: "QDLY-1234: UI",
                                 repo: "quiddly-com/finq.admin-ui", updated: at(10))
        let heads = [prURL: "NI/QDLY-1234"]
        check(ResumeLogic.pullRequest(for: api, in: [elsewhere, byTitle, byHead], head: { heads[$0] })?.number == 57, "head branch first")
        check(ResumeLogic.pullRequest(for: api, in: [elsewhere, byTitle], head: { _ in nil })?.number == 570, "then the ticket in the title")
        check(ResumeLogic.pullRequest(for: ResumeContextKey(ticket: "QDLY-1234"), in: [elsewhere, byTitle], head: { _ in nil })?.number == 1,
              "a ticket alone takes the latest anywhere")
        check(ResumeLogic.pullRequest(for: ResumeContextKey(repo: "finq.api", branch: "main"), in: [byTitle], head: { _ in nil }) == nil, "none")
    }),

    ("resume: pull request changes since the visit: commits, others' comments and finished checks", {
        var activity = GitHubActivity()
        activity.me = "niklas"
        let pr = GitHubPR(url: prURL, number: 57, title: "Fix", repo: "quiddly-com/finq.api", updated: t0, checks: .running, activity: activity)
        var detail = GitHubPRDetail(url: prURL, repo: "quiddly-com/finq.api", number: 57, title: "Fix")
        detail.rollup = .failed
        detail.commits = [GitHubPRDetail.Commit(oid: "a", headline: "Old", author: nil, date: at(-5 * hour), url: nil),
                          GitHubPRDetail.Commit(oid: "b", headline: "Address review", author: nil, date: at(-hour), url: nil)]
        detail.checks = [GitHubPRDetail.Check(name: "build", status: .passed, completed: at(-hour)),
                         GitHubPRDetail.Check(name: "tests", status: .failed, completed: at(-0.5 * hour)),
                         GitHubPRDetail.Check(name: "lint", status: .passed, completed: at(-5 * hour))]
        var comments = GitHubComments()
        comments.me = "niklas"
        comments.threads = [GitHubThread(id: "t", path: "a.py", comments: [comment("1", "anna", "Why  not\nround half up?", -hour),
                                                                         comment("2", "niklas", "mine", -0.9 * hour)])]
        comments.conversation = [comment("3", "copilot", "bot", -hour, bot: true), comment("4", "bo", "old", -6 * hour)]
        let changes = ResumeLogic.changes(pr, detail: detail, comments: comments, since: at(-4 * hour))
        check(changes.newCommits == ["Address review"], "\(changes.newCommits)")
        check(changes.finishedChecks == ["tests failed", "build passed"], "\(changes.finishedChecks)")
        check(changes.newComments.map(\.author) == ["anna"] && changes.newComments[0].text == "Why not round half up?", "others only")
        check(changes.checks == .failed && changes.unresolved == 1 && changes.hasChanges && !changes.listOnly, "current state")
        let quiet = ResumeLogic.changes(pr, detail: nil, comments: nil, since: at(-4 * hour))
        check(!quiet.hasChanges && quiet.listOnly && quiet.checks == .running, "list row only")
    }),

    ("resume: Jira status and assignee changes and comments since the visit", {
        let data = Data("""
            {"key":"QDLY-1234","fields":{"summary":"Rounding","status":{"name":"Review"},"assignee":{"displayName":"Anna Berg"},
             "comment":{"total":2,"comments":[{"author":{"displayName":"Bo"},"created":"2026-10-27T10:00:00.000+0000","body":"Old"},
                                              {"author":{"displayName":"Anna Berg"},"created":"2026-10-27T12:30:00.000+0000","body":"Looks good"}]}},
             "changelog":{"histories":[
               {"author":{"displayName":"Bo"},"created":"2026-10-27T09:00:00.000+0000","items":[{"field":"status","fromString":"To Do","toString":"In Progress"}]},
               {"author":{"displayName":"Anna Berg"},"created":"2026-10-27T12:00:00.000+0000","items":[
                 {"field":"status","fromString":"In Progress","toString":"Review"},{"field":"labels","fromString":"","toString":"x"},
                 {"field":"assignee","fromString":"Niklas Inde","toString":"Anna Berg"}]}]}}
            """.utf8)
        let changes = ResumeLogic.parseChangelog(data)
        check(changes.count == 3, "labels left out")
        let since = JiraLogic.date("2026-10-27T11:00:00.000+0000")!
        let ticket = ResumeLogic.ticket(try JiraLogic.parseIssue(data), changes: changes, since: since, url: "https://x/browse/QDLY-1234")
        check(ticket.changes == ["Status: In Progress \u{2192} Review (Anna Berg)", "Assignee: Niklas Inde \u{2192} Anna Berg (Anna Berg)"], "\(ticket.changes)")
        check(ticket.newComments.map(\.text) == ["Looks good"] && ticket.status == "Review" && ticket.assignee == "Anna Berg", "comments since")
        check(ResumeLogic.issuePath("QDLY-1").hasSuffix("&expand=changelog"), "asks for the changelog")
    }),

    ("resume: meeting lines naming the ticket (also spoken), the pull request or the repository", {
        let text = """
            # Weekly sync
            We talked about finq.api2 and the release.
            Bo: the PR 57 still fails on tests
            Anna: QDLY 1234 should go out this week
            """
        check(ResumeLogic.mentionLine(in: text, ticket: "QDLY-1234", prNumber: 57, repo: "finq.api") == "Anna: QDLY 1234 should go out this week", "ticket first")
        check(ResumeLogic.mentionLine(in: text, ticket: "QDLY-9", prNumber: 57, repo: "finq.api") == "Bo: the PR 57 still fails on tests", "then the PR")
        check(ResumeLogic.mentionLine(in: text, ticket: nil, prNumber: nil, repo: "finq.api") == nil, "finq.api2 is not finq.api")
        check(ResumeLogic.mentionLine(in: "Deploy finq.api today", ticket: nil, prNumber: nil, repo: "finq.api") == "Deploy finq.api today", "repository")
        check(ResumeLogic.mentionLine(in: "see QDLY-12345 and #570", ticket: "QDLY-1234", prNumber: 57, repo: nil) == nil, "longer numbers do not match")
        check(ResumeLogic.mentionLine(in: "merged #57.", ticket: nil, prNumber: 57, repo: nil) == "merged #57.", "hash number")
    }),

    ("resume: the agent of the pull request, else of the ticket", {
        let agents = [AgentState(key: "topic:1", title: "Rounding support", status: .idle, jiraKey: "QDLY-1234"),
                      AgentState(key: prURL, title: "finq.api #57", prURL: prURL, status: .waiting, lastResult: "Fixed the\ntest")]
        check(ResumeLogic.agent(in: agents, prURL: prURL, ticket: "QDLY-1234")?.lastResult == "Fixed the test", "pull request first")
        check(ResumeLogic.agent(in: agents, prURL: nil, ticket: "QDLY-1234")?.key == "topic:1", "ticket")
        check(ResumeLogic.agent(in: agents, prURL: nil, ticket: nil) == nil, "none")
    }),

    ("resume: resume_context answers from the database, cache and transcripts, and refuses bad tickets", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore(path: folder.appendingPathComponent("store.sqlite").path)
        let sessionID = "11111111-2222-3333-4444-555555555555"
        let session = ClaudeSession(id: sessionID, folder: "/Users/me/git/finq.api", title: "Fix the voucher")
        let projects = folder.appendingPathComponent("projects")
        let transcript = ClaudeTranscripts.transcript(id: sessionID, cwd: session.folder, root: projects)!
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try userLine("make the rounding test pass", -4.5 * hour).write(to: transcript, atomically: true, encoding: .utf8)
        for var item in [block(-5 * hour, -4 * hour, focus: session), block(-hour, -0.5 * hour, repo: "finq.admin-ui", branch: "develop")] {
            item.id = 0
            try store.saveBlock(item)
        }
        try store.saveGitHubPRs([.created: [GitHubPR(url: prURL, number: 57, title: "QDLY-1234: Fix rounding", repo: "quiddly-com/finq.api", updated: t0)]])
        let sources = ResumeSources(store: { store }, jira: { nil }, githubEnabled: { true },
                                    agentState: folder.appendingPathComponent("agents.json"), projects: projects)
        let tool = MCPServer.resumeTools(.success(store), sources: sources, now: { t0 })[0]
        let text = try tool.run(["branch": "NI/QDLY-1234"])
        check(text.hasPrefix("# finq.api \u{00B7} NI/QDLY-1234"), text)
        check(text.contains("Fix the voucher: make the rounding test pass"), "prompt from the transcript")
        check(text.contains("quiddly-com/finq.api#57") && text.contains("detail not fetched"), "pull request")
        check(try tool.run([:]).hasPrefix("# finq.admin-ui \u{00B7} develop"), "latest context without arguments")
        check(try tool.run(["ticket": "QDLY-77"]).contains("No tracked time here"), "a ticket never worked on")
        check((try? tool.run(["ticket": "nonsense"])) == nil, "bad ticket")
        check(MCPServer.toolNames.contains("resume_context"), "listed")
    }),
]
