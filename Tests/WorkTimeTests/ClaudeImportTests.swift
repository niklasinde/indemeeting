import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let sessionID = "0b6f7c2e-1d4a-4c8e-9f3a-5e2d7b1c9a04"
private let otherID = "7a1e2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b"
private let prURL = "https://github.com/quiddly-com/finq.api/pull/57"

private let fixture = """
{"type":"summary","summary":"Old work","leafUuid":"x"}
{"type":"user","isMeta":true,"cwd":"/Users/me/git/finq.api","timestamp":"2026-11-10T08:00:00.000Z","message":{"role":"user","content":"Caveat: local commands"}}
{"type":"user","cwd":"/Users/me/git/finq.api","timestamp":"2026-11-10T08:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ignore</system-reminder>"}]}}
{"type":"user","isSidechain":true,"cwd":"/Users/me/git/finq.api","message":{"role":"user","content":"a subagent prompt"}}
{"type":"user","cwd":"/Users/me/git/finq.api","timestamp":"2026-11-10T08:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Fix the rounding in the invoice revaluation so that the totals match the ledger exactly every month"}]}}
{"type":"assistant","cwd":"/Users/me/git/finq.api","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}

"""

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
}

private func pr(_ url: String, title: String, repo: String = "quiddly-com/finq.api", state: GitHubPR.State = .open, updated: Double = 0) -> GitHubPR {
    var pr = GitHubPR(url: url, number: Int(url.split(separator: "/").last!)!, title: title, repo: repo, updated: Date(timeIntervalSince1970: updated))
    pr.state = state
    return pr
}

let claudeImportTests: [(name: String, run: () throws -> Void)] = [
    ("import link: a session id and an optional absolute folder", {
        check(ClaudeImport.parseLink("worktime://agent?session=\(sessionID)") == ClaudeImport.Link(session: sessionID, cwd: nil), "id only")
        check(ClaudeImport.parseLink("worktime://agent?session=\(sessionID.uppercased())&cwd=%2FUsers%2Fme%2Fgit%2Fapp")
              == ClaudeImport.Link(session: sessionID, cwd: "/Users/me/git/app"), "with the folder, the id lowercased")
        check(ClaudeImport.parseLink("worktime://agent?session=\(sessionID)&cwd=/Users/me/my%20app") == ClaudeImport.Link(session: sessionID, cwd: "/Users/me/my app"), "space")
        check(ClaudeImport.parseLink(ClaudeImport.link(session: sessionID, cwd: "/Users/me/my app")) == ClaudeImport.Link(session: sessionID, cwd: "/Users/me/my app"), "round trip")
        check(ClaudeImport.parseLink("worktime://agent?session=\(sessionID)&cwd=relative/path") == nil, "a relative folder")
        check(ClaudeImport.parseLink("worktime://agent?session=not-a-uuid") == nil, "not a session id")
        check(ClaudeImport.parseLink("worktime://agent?session=\(sessionID)&session=\(otherID)") == nil, "twice")
        check(ClaudeImport.parseLink("worktime://agent?session=\(sessionID)&extra=1") == nil, "unknown parameter")
        check(ClaudeImport.parseLink("worktime://agent?pr=\(prURL)") == nil, "a pull request link")
        check(ClaudeImport.parseLink("https://agent?session=\(sessionID)") == nil, "another scheme")
        check(GitHubLink.parseAgent("worktime://agent?session=\(sessionID)") == nil, "the pull request parser leaves it alone")
        check(GitHubLink.parseAgent("worktime://agent?pr=\(prURL)") != nil, "and still takes its own")
    }),

    ("import header: folder, first typed prompt and start, leaving out meta, reminders and sidechains", {
        let header = ClaudeImport.header(jsonl: fixture)
        check(header.cwd == "/Users/me/git/finq.api", "\(String(describing: header.cwd))")
        check(header.prompt == ActivityLogic.truncate("Fix the rounding in the invoice revaluation so that the totals match the ledger exactly every month", to: 60),
              "\(String(describing: header.prompt))")
        check(header.prompt?.count == 60, "cut to 60")
        check(header.started == (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-10T08:00:00.000Z")), "first timestamp")
        check(ClaudeImport.header(jsonl: "{\"type\":\"summary\"}\nnot json\n") == ClaudeSessionHeader(), "nothing")
        check(ClaudeImport.completeLines(Data("a\nb\npartial".utf8)) == "a\nb", "a cut line is dropped")
        check(ClaudeImport.completeLines(Data("partial".utf8)).isEmpty, "no complete line")
        check(ClaudeImport.agentName(prompt: nil) == "Imported session", "untitled")
        check(ClaudeImport.agentName(prompt: "  ") == "Imported session", "blank")
        check(ClaudeImport.agentName(prompt: String(repeating: "a", count: 80)).count == 60, "at most 60")
    }),

    ("import list: newest first, sessions an agent has and ones without a prompt left out, searchable", {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let third = "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f", empty = "2d3e4f5a-6b7c-4d8e-9f0a-1b2c3d4e5f6a"
        try write(fixture, to: root.appendingPathComponent("-Users-me-git-finq-api/\(sessionID).jsonl"), modified: Date(timeIntervalSince1970: 3000))
        try write(fixture.replacingOccurrences(of: "finq.api", with: "papercut"),
                  to: root.appendingPathComponent("-Users-me-git-papercut/\(otherID).jsonl"), modified: Date(timeIntervalSince1970: 5000))
        try write(fixture, to: root.appendingPathComponent("-Users-me-git-finq-api/\(third).jsonl"), modified: Date(timeIntervalSince1970: 4000))
        try write("{\"type\":\"summary\",\"cwd\":\"/x\"}\n", to: root.appendingPathComponent("-x/\(empty).jsonl"), modified: Date(timeIntervalSince1970: 6000))
        try write("{}\n", to: root.appendingPathComponent("-x/notes.jsonl"))
        let all = ClaudeSessionFiles.recent(root: root, excluding: [])
        check(all.map(\.id) == [otherID, third, sessionID], "\(all.map(\.id))")
        check(all.first?.cwd == "/Users/me/git/papercut" && all.first?.size ?? 0 > 0, "folder and size")
        check(ClaudeSessionFiles.recent(root: root, excluding: [third]).map(\.id) == [otherID, sessionID], "known left out")
        check(ClaudeSessionFiles.recent(root: root, excluding: [], limit: 1).map(\.id) == [otherID], "limit")
        check(ClaudeImport.filter(all, query: "PAPERCUT").map(\.id) == [otherID], "folder search")
        check(ClaudeImport.filter(all, query: "rounding finq").map(\.id) == [third, sessionID], "every word")
        check(ClaudeImport.filter(all, query: " ").count == 3, "empty search")
        check(ClaudeSessionFiles.locate(sessionID, cwd: nil, root: root)?.cwd == "/Users/me/git/finq.api", "found by id")
        check(ClaudeSessionFiles.locate(otherID, cwd: "/Users/me/git/papercut", root: root)?.id == otherID, "found by folder")
        check(ClaudeSessionFiles.locate("3e4f5a6b-7c8d-4e9f-8a1b-2c3d4e5f6a7b", cwd: nil, root: root) == nil, "missing")
    }),

    ("import target: the open pull request on the checkout's branch, else a topic named from the prompt", {
        let remotes = ["quiddly-com/finq.api"]
        let head = { (url: String) -> String? in url == prURL ? "NI/QDLY-1234-rounding" : nil }
        let prs = [pr(prURL, title: "Fix rounding"), pr("https://github.com/quiddly-com/finq.api/pull/58", title: "QDLY-9: Other")]
        check(ClaudeImport.target(branch: "NI/QDLY-1234-rounding", remotes: remotes, prs: prs, head: head, prompt: "x") == .pullRequest(prURL), "by head")
        let byTicket = [pr("https://github.com/quiddly-com/finq.api/pull/60", title: "QDLY-4321: Fix")]
        check(ClaudeImport.target(branch: "NI/QDLY-4321", remotes: remotes, prs: byTicket, head: { _ in nil }, prompt: "x")
              == .pullRequest("https://github.com/quiddly-com/finq.api/pull/60"), "by the branch's ticket when the head is not cached")
        check(ClaudeImport.target(branch: "NI/QDLY-4321", remotes: remotes, prs: byTicket, head: { _ in "other" }, prompt: "x") == .topic(name: "x"),
              "a known head that differs wins over the ticket")
        check(ClaudeImport.target(branch: "NI/QDLY-1234-rounding", remotes: remotes, prs: [pr(prURL, title: "Fix", state: .merged)], head: head, prompt: "Fix it")
              == .topic(name: "Fix it"), "a merged one is not used")
        check(ClaudeImport.target(branch: "NI/QDLY-1234-rounding", remotes: ["quiddly-com/finq.admin-ui"], prs: prs, head: head, prompt: nil)
              == .topic(name: "Imported session"), "another repository")
        check(ClaudeImport.target(branch: nil, remotes: [], prs: prs, head: head, prompt: "Hi") == .topic(name: "Hi"), "not a checkout")
    }),

    ("import repository: the branch and remotes of the checkout holding the folder, worktrees too", {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("finq.api"), git = repo.appendingPathComponent(".git")
        try write("ref: refs/heads/develop\n", to: git.appendingPathComponent("HEAD"))
        try write("[remote \"origin\"]\n\turl = git@github.com:quiddly-com/finq.api.git\n", to: git.appendingPathComponent("config"))
        let found = ClaudeImport.repository(at: repo.appendingPathComponent("src/app").path)
        check(found?.branch == "develop" && found?.remotes == ["quiddly-com/finq.api"], "\(String(describing: found))")
        let tree = root.appendingPathComponent("tree"), treeGit = git.appendingPathComponent("worktrees/tree")
        try write("gitdir: \(treeGit.path)\n", to: tree.appendingPathComponent(".git"))
        try write("ref: refs/heads/NI/QDLY-1\n", to: treeGit.appendingPathComponent("HEAD"))
        try write("../..\n", to: treeGit.appendingPathComponent("commondir"))
        let worktree = ClaudeImport.repository(at: tree.path)
        check(worktree?.branch == "NI/QDLY-1" && worktree?.remotes == ["quiddly-com/finq.api"], "\(String(describing: worktree))")
        check(ClaudeImport.repository(at: root.path) == nil || ClaudeImport.repository(at: root.path)?.remotes.contains("quiddly-com/finq.api") == false,
              "a plain folder has no checkout of its own")
    }),

    ("import fork: the original is always forked, the fork continues in place, both carry the note", {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        var records = ClaudeImport.adding(original: sessionID, date: date, to: [])
        check(ClaudeImport.adding(original: sessionID, date: date, to: records).count == 1, "once")
        check(ClaudeImport.shouldFork(sessionID, records: records), "the original forks")
        check(!ClaudeImport.shouldFork(nil, records: records) && !ClaudeImport.shouldFork(otherID, records: records), "others do not")
        records = ClaudeImport.forked(sessionID, into: otherID, in: records)
        check(records == [ClaudeImportRecord(original: sessionID, date: date, forked: otherID)], "\(records)")
        check(!ClaudeImport.shouldFork(otherID, records: records), "the fork is continued in place")
        check(ClaudeImport.shouldFork(sessionID, records: records), "picking the original forks again")
        check(ClaudeImport.record(for: otherID, in: records)?.original == sessionID, "the fork has the note too")
        check(ClaudeImport.note(records[0]).hasPrefix("Continued from a Claude Code session \u{00B7} "), ClaudeImport.note(records[0]))
        check(ClaudeImport.decode(ClaudeImport.encode(records)) == records, "round trip")
        check(ClaudeImport.decode(nil).isEmpty, "none saved")
        let request = AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: sessionID, fork: true).line
        check(request.contains(#""forkSession":true"#) && request.contains(#""sessionId":"\#(sessionID)""#), request)
        check(!AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: nil, fork: true).line.contains("forkSession"), "nothing to fork")
        check(!AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: sessionID).line.contains("forkSession"), "not by default")
    }),

    ("import: sessions agents have are known, and the agent that has one is found", {
        let entry = AgentSessionEntry(id: "h", folder: "/r", created: Date(), lastUsed: Date(), title: "t", model: nil)
        let records = [ClaudeImportRecord(original: sessionID, date: Date(), forked: otherID)]
        let history = [prURL: [entry]], saved = ["topic:abc": otherID]
        check(ClaudeImport.knownIDs(history: history, saved: saved, records: records) == ["h", otherID, sessionID], "all")
        check(ClaudeImport.owner(of: sessionID, history: history, saved: saved, records: records) == "topic:abc", "through its fork")
        check(ClaudeImport.owner(of: "h", history: history, saved: [:], records: []) == prURL, "in a history")
        check(ClaudeImport.owner(of: "nobody", history: history, saved: saved, records: records) == nil, "none")
        check(ClaudeImport.resumeFlags(session: sessionID) == ["--resume", sessionID], "resume flags")
    }),

    ("import topic: works in the session's own folder, which deleting the topic never removes", {
        let topic = TopicAgents.imported(name: String(repeating: "n", count: 100), folder: "/Users/me/git/finq.api", session: sessionID,
                                         now: Date(timeIntervalSince1970: 0))
        check(topic.folder == "/Users/me/git/finq.api" && topic.importedSession == sessionID && topic.kind == .topic, "\(topic)")
        check(topic.name.count == TopicAgents.nameLimit, "name cut")
        check(TopicAgents.ownedFolder(topic, root: URL(fileURLWithPath: "/data/Agents")) == nil, "not owned")
        check(TopicAgents.systemPrompt(topic).contains("/Users/me/git/finq.api") && !TopicAgents.systemPrompt(topic).contains("scratch folder"),
              TopicAgents.systemPrompt(topic))
        check(TopicAgents.decode(TopicAgents.encode([topic])) == [topic], "round trip")
    }),
]
