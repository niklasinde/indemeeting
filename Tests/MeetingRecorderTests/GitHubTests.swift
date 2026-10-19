import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private let now = Date(timeIntervalSince1970: 1_792_300_000)

private func node(number: Int = 1, title: String = "QDLY-1: Title", repo: String = "acme/api", state: String = "OPEN", merged: Bool = false,
                  draft: Bool = false, updated: String = "2026-10-19T12:58:21Z", review: String = "null", rollup: String = #"{"state":"SUCCESS"}"#,
                  author: String = #"{"login":"niklas"}"#, labels: String = #"[{"name":"bug"}]"#) -> String {
    """
    {"number":\(number),"title":"\(title)","url":"https://github.com/\(repo)/pull/\(number)","isDraft":\(draft),"state":"\(state)",
     "merged":\(merged),"updatedAt":"\(updated)","reviewDecision":\(review == "null" ? review : "\"\(review)\""),"additions":10,"deletions":2,
     "repository":{"nameWithOwner":"\(repo)"},"author":\(author),"comments":{"totalCount":3},"labels":{"nodes":\(labels)},
     "commits":{"nodes":[{"commit":{"statusCheckRollup":\(rollup)}}]}}
    """
}

private func response(_ nodes: [String]) -> Data {
    Data(#"{"data":{"search":{"nodes":[\#(nodes.joined(separator: ","))]}}}"#.utf8)
}

private func pr(_ number: Int, repo: String = "acme/api", state: GitHubPR.State = .open, checks: GitHubPR.Checks = .passed,
                title: String = "Title", updated: TimeInterval = 0, author: String? = "niklas") -> GitHubPR {
    GitHubPR(url: "https://github.com/\(repo)/pull/\(number)", number: number, title: title, repo: repo, state: state,
             updated: Date(timeIntervalSince1970: updated), checks: checks, author: author)
}

let githubTests: [(name: String, run: () throws -> Void)] = [
    ("a search response is parsed into pull requests with every field", {
        let rows = try GitHubLogic.parse(response([node(number: 7, review: "APPROVED", labels: #"[{"name":"bug"},{"name":"ui"}]"#)]))
        check(rows.count == 1, "one row")
        let row = rows[0]
        check(row.number == 7 && row.repo == "acme/api" && row.title == "QDLY-1: Title", "identity")
        check(row.url == "https://github.com/acme/api/pull/7", "url")
        check(row.state == .open && !row.isDraft, "state")
        check(row.review == .approved && row.checks == .passed, "review and checks")
        check(row.author == "niklas" && row.additions == 10 && row.deletions == 2 && row.comments == 3, "numbers")
        check(row.labels == ["bug", "ui"], "labels")
        check(row.updated == Date(timeIntervalSince1970: 1_792_414_701), "updated \(row.updated.timeIntervalSince1970)")
        check(row.ticket == "QDLY-1", "ticket")
    }),

    ("a pull request can be merged, closed or a draft, and have no rollup, review or author", {
        let rows = try GitHubLogic.parse(response([
            node(number: 1, state: "MERGED", merged: true),
            node(number: 2, state: "CLOSED"),
            node(number: 3, draft: true, rollup: "null", author: "null", labels: "[]"),
        ]))
        check(rows.map(\.state) == [.merged, .closed, .open], "states")
        check(rows[2].isDraft && rows[2].checks == .none && rows[2].author == nil && rows[2].review == nil, "bare draft")
        check(rows[2].labels.isEmpty, "no labels")
    }),

    ("check rollup states map to passed, failed, running and none", {
        check(GitHubLogic.checks("SUCCESS") == .passed, "success")
        check(GitHubLogic.checks("FAILURE") == .failed && GitHubLogic.checks("ERROR") == .failed, "failure")
        check(GitHubLogic.checks("PENDING") == .running && GitHubLogic.checks("EXPECTED") == .running, "pending")
        check(GitHubLogic.checks(nil) == .none && GitHubLogic.checks("OTHER") == .none, "none")
    }),

    ("review decisions map, and an unknown one is none", {
        let rows = try GitHubLogic.parse(response([
            node(number: 1, review: "CHANGES_REQUESTED"), node(number: 2, review: "REVIEW_REQUIRED"), node(number: 3, review: "SOMETHING"),
        ]))
        check(rows.map(\.review) == [.changesRequested, .required, nil], "decisions")
    }),

    ("nodes that are not pull requests, or null, are skipped", {
        let rows = try GitHubLogic.parse(Data(#"{"data":{"search":{"nodes":[null,{},\#(node(number: 4))]}}}"#.utf8))
        check(rows.map(\.number) == [4], "only the pull request")
    }),

    ("a response without data throws the classified error", {
        do {
            _ = try GitHubLogic.parse(Data(#"{"data":null,"errors":[{"message":"API rate limit exceeded for user"}]}"#.utf8))
            check(false, "should throw")
        } catch { check(error as? GitHubError == .rateLimited, "rate limited, got \(error)") }
        do {
            _ = try GitHubLogic.parse(Data("not json".utf8))
            check(false, "should throw")
        } catch { check(error as? GitHubError == .failed("unexpected response"), "unexpected response") }
    }),

    ("the searches name the kind, are limited to open, and created adds the closed ones", {
        let review = GitHubLogic.searches(for: .reviewRequested)
        check(review.count == 1 && review[0].terms == "review-requested:@me is:pr is:open archived:false sort:updated-desc", review[0].terms)
        check(GitHubLogic.searches(for: .assigned)[0].terms.hasPrefix("assignee:@me is:pr is:open"), "assigned")
        check(GitHubLogic.searches(for: .mentioned)[0].terms.hasPrefix("mentions:@me is:pr is:open"), "mentioned")
        let created = GitHubLogic.searches(for: .created)
        check(created.map(\.limit) == [50, 30], "limits")
        check(created[0].terms.hasPrefix("author:@me is:pr is:open") && created[1].terms.hasPrefix("author:@me is:pr is:closed"), "states")
    }),

    ("the gh arguments run a GraphQL search without any token", {
        let arguments = GitHubLogic.arguments(for: GitHubLogic.searches(for: .created)[0])
        check(Array(arguments.prefix(2)) == ["api", "graphql"], "graphql")
        check(arguments.contains("q=author:@me is:pr is:open archived:false sort:updated-desc"), "terms")
        check(arguments.contains("first=50"), "page size")
        check(!arguments.contains { $0.lowercased().contains("token") || $0.lowercased().contains("authorization") }, "no credentials")
        check(GitHubLogic.query.contains("statusCheckRollup") && GitHubLogic.query.contains("reviewDecision"), "fields")
        check(GitHubLogic.authArguments == ["auth", "status", "--hostname", "github.com"], "auth check")
    }),

    ("the gh CLI is looked for on the PATH first, then in the usual places, without duplicates", {
        let home = URL(fileURLWithPath: "/Users/me")
        let paths = GitHubLogic.cliCandidates(path: "/usr/bin:/opt/homebrew/bin", home: home).map(\.path)
        check(paths == ["/usr/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/Users/me/.local/bin/gh"], "\(paths)")
        check(GitHubLogic.cliCandidates(path: nil, home: home).map(\.path)
              == ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/Users/me/.local/bin/gh"], "no PATH")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("gh")
        try "#!/bin/sh\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        check(GitHubLogic.findCLI(environment: ["PATH": folder.path], home: folder)?.path == cli.path, "found on PATH")
    }),

    ("stderr text is classified: missing sign-in, rate limit, single sign-on, offline, anything else", {
        check(GitHubError.classify("You are not logged into any GitHub hosts. To log in, run: gh auth login") == .notLoggedIn, "not logged in")
        check(GitHubError.classify("gh: Bad credentials (HTTP 401)") == .notLoggedIn, "bad credentials")
        check(GitHubError.classify("gh: API rate limit exceeded for user ID 1. (HTTP 403)") == .rateLimited, "rate limit")
        check(GitHubError.classify("You have exceeded a secondary rate limit") == .rateLimited, "secondary")
        if case .sso(let detail) = GitHubError.classify("gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access") {
            check(detail.contains("SAML"), "detail")
        } else { check(false, "sso") }
        check(GitHubError.classify("error connecting to api.github.com") == .offline, "offline")
        check(GitHubError.classify("gh: Something odd\nsecond line") == .failed("gh: Something odd"), "first line only")
        check(GitHubError.cliMissing.command == "brew install gh" && GitHubError.notLoggedIn.command == "gh auth login", "commands")
        check(GitHubError.rateLimited.command == nil, "no command for a rate limit")
    }),

    ("filters keep the chosen state and repository, match the search words and sort by newest update", {
        let all = [pr(1, state: .open, title: "Fix invoice rounding", updated: 100), pr(2, state: .merged, title: "Release notes", updated: 300),
                   pr(3, repo: "acme/ui", state: .open, title: "Invoice grid", updated: 200), pr(4, state: .closed, updated: 50)]
        func numbers(_ filter: GitHubLogic.Filter) -> [Int] { GitHubLogic.filter(all, filter).map(\.number) }
        check(numbers(.init()) == [3, 1], "open by default, newest first")
        check(numbers(.init(state: .merged)) == [2], "merged")
        check(numbers(.init(state: .closed)) == [4], "closed")
        check(numbers(.init(state: .all)) == [2, 3, 1, 4], "all")
        check(numbers(.init(repo: "acme/ui")) == [3], "repository")
        check(numbers(.init(query: "invoice")) == [3, 1], "title word")
        check(numbers(.init(query: "INVOICE grid")) == [3], "every word, any case")
        check(numbers(.init(query: "#1")) == [1], "number")
        check(numbers(.init(query: "acme/ui")) == [3], "repository in query")
        check(numbers(.init(state: .all, query: "niklas")) == [2, 3, 1, 4], "author")
        check(GitHubLogic.repos(in: all) == ["acme/api", "acme/ui"], "repository list")
    }),

    ("the header counts and says where a page may be cut off", {
        check(GitHubLogic.header(count: 47, kind: .created, capped: false) == "47 created", "plain")
        check(GitHubLogic.header(count: 50, kind: .reviewRequested, capped: true) == "50+ review requested", "capped")
        let full = (0..<50).map { pr($0) }
        check(GitHubLogic.isCapped(full, state: .open) && !GitHubLogic.isCapped(full, state: .merged), "capped only for open")
        check(!GitHubLogic.isCapped(Array(full.prefix(49)), state: .open), "short page")
        check(GitHubLogic.repoName("acme/api") == ("acme", "api"), "repo name")
        check(GitHubLogic.changesText(additions: 12, deletions: 3) == "+12 \u{2212}3", "changes")
        check(GitHubLogic.updatedText(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago", "relative time")
    }),

    ("a ticket key only counts when the title starts with it", {
        check(pr(1, title: "QDLY-8315: Store the number").ticket == "QDLY-8315", "starts with key")
        check(pr(1, title: "FIX(QDLY-8691): Convert").ticket == nil, "key inside")
        check(pr(1, title: "[Snyk] Upgrade").ticket == nil, "no key")
    }),

    ("the menu line counts reviews asked of you and failing checks on your own open pull requests", {
        let prs: [GitHubKind: [GitHubPR]] = [
            .reviewRequested: [pr(1), pr(2), pr(3), pr(4, state: .merged)],
            .created: [pr(5, checks: .failed), pr(6, checks: .failed), pr(7), pr(8, state: .merged, checks: .failed)],
        ]
        check(GitHubLogic.menuSummary(prs) == "GitHub: 3 need your review \u{00B7} 2 failing checks", GitHubLogic.menuSummary(prs))
        check(GitHubLogic.menuSummary([.reviewRequested: [pr(1)]]) == "GitHub: 1 needs your review", "singular")
        check(GitHubLogic.menuSummary([.created: [pr(1, checks: .failed)]]) == "GitHub: 1 failing check", "one failing")
        check(GitHubLogic.menuSummary([:]) == "GitHub: nothing waiting for you", "nothing")
    }),

    ("the cache stores each kind in order, replaces only the kinds fetched, and clears", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("github-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        check(try store.githubPRs().isEmpty && (try store.githubFetched()) == nil, "starts empty")
        var full = pr(1, title: "QDLY-1: One", updated: 1_792_300_000, author: nil)
        full.isDraft = true
        full.review = .changesRequested
        full.additions = 5
        full.deletions = 6
        full.comments = 2
        full.labels = ["bug", "ui"]
        full.checks = .running
        try store.saveGitHubPRs([.created: [full, pr(2, state: .merged)], .assigned: [pr(1)]], fetched: now)
        let saved = try store.githubPRs()
        check(saved[.created]?.first == full, "round trip \(String(describing: saved[.created]?.first))")
        check(saved[.created]?.map(\.number) == [1, 2] && saved[.assigned]?.map(\.number) == [1], "kinds and order")
        check(saved[.created]?[1].state == .merged, "state")
        check(try store.githubFetched() == now, "fetched time")
        try store.saveGitHubPRs([.created: [pr(9)]], fetched: now)
        let replaced = try store.githubPRs()
        check(replaced[.created]?.map(\.number) == [9] && replaced[.assigned]?.count == 1, "only created replaced")
        try store.saveGitHubPRs([.created: []])
        check(try store.githubPRs()[.created] == nil, "an empty fetch empties the kind")
        check(try store.githubTitles()["github.com/acme/api/pull/1"] == "Title", "title by address")
        check(try store.clearGitHubCache() == 1, "cleared count")
        check(try store.githubPRs().isEmpty, "cleared")
    }),

    ("deleting all activity leaves the GitHub cache alone", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("github-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        try store.saveGitHubPRs([.created: [pr(1)]])
        try store.deleteAll()
        check(try store.githubPRs()[.created]?.count == 1, "kept")
    }),
]
