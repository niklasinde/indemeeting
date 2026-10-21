import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private let now = Date(timeIntervalSince1970: 1_792_300_000)
private let me = "niklas"
private let apiPull = "https://github.com/acme/api/pull/7"

private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-github-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Your own pull request with an unresolved thread from elin since your last commit, and failing checks.
private let mine = GitHubPR(url: apiPull, number: 7, title: "QDLY-1: Title", repo: "acme/api", updated: now.addingTimeInterval(-600),
                            review: .required, checks: .failed, author: me,
                            activity: GitHubActivity(me: me, threads: 1,
                                                     open: [GitHubActivity.Event(actor: .init(login: "elin"), date: now.addingTimeInterval(-300))],
                                                     lastCommit: now.addingTimeInterval(-3600)))

private let merged = GitHubPR(url: "https://github.com/acme/api/pull/5", number: 5, title: "QDLY-2: Old", repo: "acme/api",
                              state: .merged, updated: now.addingTimeInterval(-86_400), checks: .passed, author: me)

/// Someone else's pull request that waits on you for a review.
private let asked = GitHubPR(url: "https://github.com/acme/web/pull/3", number: 3, title: "Web: Banner", repo: "acme/web",
                             updated: now.addingTimeInterval(-900), review: .required, checks: .passed, author: "elin",
                             activity: GitHubActivity(me: me, requested: [me]))

private func seeded(_ folder: URL, detail: Data? = detailJSON()) throws -> MeetingStore {
    let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
    try store.saveGitHubPRs([.created: [mine, merged], .reviewRequested: [asked]], fetched: now)
    if let detail { try store.saveGitHubDetail(apiPull, json: detail) }
    return store
}

private func server(_ opened: Result<MeetingStore, Error>, enabled: Bool = true) -> MCPServer {
    MCPServer(tools: MCPServer.githubTools(opened, enabled: { enabled }, now: { now }))
}

let mcpGitHubTests: [(name: String, run: () throws -> Void)] = [
    ("the GitHub tools are listed read-only with their schemas", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = MCPServer.githubTools(.success(try seeded(directory)), enabled: { true })
        check(tools.map(\.name) == ["github_prs", "github_pr", "github_needs_attention"], "names \(tools.map(\.name))")
        check(tools.allSatisfy { ($0.listing["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }, "read-only")
        let listing = json(server(.success(try seeded(directory))).handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let schemas = (listing["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let pr = schemas.first { $0["name"] as? String == "github_pr" }?["inputSchema"] as? [String: Any]
        check(pr?["required"] as? [String] == ["pr"], "github_pr needs pr")
        check(schemas.count == 3, "served \(schemas.count)")
    }),

    ("github_prs lists the created open pull requests with their flags, and filters by kind, state and limit", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mcp = server(.success(try seeded(directory)))
        let open = call(mcp, "github_prs")
        check(!open.isError && open.text.hasPrefix("Created, open: 1 of 1 pull requests, cached just now\n"), open.text)
        check(open.text.contains("- acme/api#7 QDLY-1: Title\n  \(apiPull)\n  by niklas \u{00B7} review required \u{00B7} checks failed"), open.text)
        check(open.text.contains("1 unresolved \u{00B7} 1 new comment \u{00B7} updated"), open.text)
        check(!open.text.contains("QDLY-2"), "merged is not open")
        let all = call(mcp, "github_prs", #"{"state":"all"}"#)
        check(all.text.contains("QDLY-2") && all.text.contains("merged \u{00B7} by niklas"), all.text)
        let waiting = call(mcp, "github_prs", #"{"kind":"review_requested"}"#)
        check(waiting.text.contains("- acme/web#3 Web: Banner") && waiting.text.contains("by elin \u{00B7} review required")
              && waiting.text.contains("waiting on you"), waiting.text)
        let limited = call(mcp, "github_prs", #"{"state":"all","limit":1}"#)
        check(limited.text.hasPrefix("Created, all: 1 of 2 pull requests"), limited.text)
        check(call(mcp, "github_prs", #"{"kind":"owned"}"#).isError, "unknown kind")
        check(call(mcp, "github_prs", #"{"state":"later"}"#).isError, "unknown state")
    }),

    ("github_pr shows the cached detail by url or by owner/repo#number", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mcp = server(.success(try seeded(directory)))
        let byURL = call(mcp, "github_pr", "{\"pr\":\"\(apiPull)\"}")
        check(!byURL.isError && byURL.text.hasPrefix("# acme/api#7 QDLY-1: Title\n\(apiPull)\n"), byURL.text)
        check(byURL.text.contains("- Branches: NI/QDLY-1-title into develop"), byURL.text)
        check(byURL.text.contains("- Review decision: review required"), byURL.text)
        check(byURL.text.contains("johan: approved") && byURL.text.contains("sara: changes requested")
              && byURL.text.contains("backend (team): review requested"), byURL.text)
        check(byURL.text.contains("- Ticket keys: QDLY-1") && byURL.text.hasSuffix("## Description\nBody\n"), byURL.text)
        check(call(mcp, "github_pr", #"{"pr":"acme/api#7"}"#).text == byURL.text, "owner/repo#n gives the same")
    }),

    ("github_pr without a cached detail gives the list fields and says so, and an unknown one is a tool error", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mcp = server(.success(try seeded(directory)))
        let listOnly = call(mcp, "github_pr", #"{"pr":"acme/web#3"}"#)
        check(!listOnly.isError && listOnly.text.contains("not cached") && listOnly.text.contains("acme/web#3 Web: Banner")
              && listOnly.text.contains("waiting on you"), listOnly.text)
        let unknown = call(mcp, "github_pr", #"{"pr":"acme/none#99"}"#)
        check(unknown.isError && unknown.text.contains("No cached pull request"), unknown.text)
        check(call(mcp, "github_pr", #"{"pr":"not a pull request"}"#).isError, "a bad reference is refused")
        check(call(mcp, "github_pr").isError, "pr is required")
    }),

    ("github_needs_attention lists what waits on you or has new comments, most urgent first, once per pull request", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mcp = server(.success(try seeded(directory)))
        let all = call(mcp, "github_needs_attention")
        check(all.text.hasPrefix("Needs attention: 2 of 2 pull requests, cached just now\n"), all.text)
        let mineAt = all.text.range(of: "acme/api#7")?.lowerBound, askedAt = all.text.range(of: "acme/web#3")?.lowerBound
        check(mineAt != nil && askedAt != nil && mineAt! < askedAt!, "the new comments outrank the review: \(all.text)")
        check(!all.text.contains("acme/api#5") && all.text.components(separatedBy: "acme/web#3").count == 2, all.text)
        check(call(mcp, "github_needs_attention", #"{"limit":1}"#).text.hasPrefix("Needs attention: 1 of 2"), "limit")
    }),

    ("an empty cache and GitHub turned off are answered with a message, not an error", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = try MeetingStore.open(at: directory.appendingPathComponent("empty.sqlite"))
        for tool in ["github_prs", "github_needs_attention"] {
            let answer = call(server(.success(empty)), tool)
            check(!answer.isError && answer.text == "No GitHub pull requests are cached yet. Open the GitHub view in Meeting Recorder to fetch them.\n",
                  "empty \(tool): \(answer.text)")
        }
        let off = server(.success(try seeded(directory)), enabled: false)
        for (tool, arguments) in [("github_prs", "{}"), ("github_pr", #"{"pr":"acme/api#7"}"#), ("github_needs_attention", "{}")] {
            let answer = call(off, tool, arguments)
            check(!answer.isError && answer.text == "GitHub is off in Meeting Recorder settings.\n", "off \(tool): \(answer.text)")
        }
        check(call(server(.failure(SQLiteError(message: "missing"))), "github_prs").isError, "a missing database is a tool error")
    }),

    ("the GitHub tools cap their limits, their descriptions and their output", {
        check(MCPServer.count(500, fallback: 20) == 50 && MCPServer.count(nil, fallback: 20) == 20, "limits")
        check(MCPServer.count(0) == 1, "at least one")
        check(MCPServer.cut("abcdef", at: 2) == "ab\n\n[Cut at 2 characters]\n" && MCPServer.cut("abc", at: 3) == "abc", "cut")
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let long = String(repeating: "x", count: 5000)
        let store = try seeded(directory, detail: Data(String(decoding: detailJSON(), as: UTF8.self)
            .replacingOccurrences(of: #""body":"Body""#, with: #""body":"\#(long)""#).utf8))
        let text = call(server(.success(store)), "github_pr", #"{"pr":"acme/api#7"}"#).text
        check(text.contains("\u{2026}") && !text.contains(long) && text.count < 2600, "description is capped at \(text.count)")
    }),
]
