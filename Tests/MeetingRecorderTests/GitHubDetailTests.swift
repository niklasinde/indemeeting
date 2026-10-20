import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func detailJSON(pr extra: String = "", commits: String = "[]", commitCount: Int = 0, files: String = "[]", fileCount: Int = 0,
                        contexts: String = "[]", rollup: String = #"{"state":"SUCCESS","contexts":{"totalCount":0,"nodes":[]}}"#) -> Data {
    Data("""
    {"data":{"repository":{"pullRequest":{
      "number":7,"title":"QDLY-1: Title","body":"Body","url":"https://github.com/acme/api/pull/7","isDraft":false,"state":"OPEN","merged":false,
      "mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","baseRefName":"develop","headRefName":"NI/QDLY-1-title",
      "createdAt":"2026-10-19T10:00:00Z","updatedAt":"2026-10-19T12:00:00Z","additions":10,"deletions":2,"changedFiles":3,
      "author":{"login":"niklas"},"labels":{"nodes":[{"name":"bug"}]},"assignees":{"nodes":[{"login":"niklas"}]},
      "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"elin"}},{"requestedReviewer":{"name":"backend"}},{"requestedReviewer":{}}]},
      "latestReviews":{"nodes":[{"author":{"login":"johan"},"state":"APPROVED"},{"author":{"login":"elin"},"state":"COMMENTED"},
        {"author":{"login":"sara"},"state":"CHANGES_REQUESTED"},{"author":null,"state":"COMMENTED"}]},
      "commits":{"totalCount":\(commitCount),"nodes":\(commits)},
      "files":{"totalCount":\(fileCount),"nodes":\(files)},
      "lastCommit":{"nodes":[{"commit":{"statusCheckRollup":\(rollup == "null" ? rollup : rollup.replacingOccurrences(of: #""nodes":[]"#, with: #""nodes":\#(contexts)"#))}}]}
      \(extra)
    }}}}
    """.utf8)
}

private func run(_ name: String, _ status: String, _ conclusion: String = "null", started: String = "null", completed: String = "null") -> String {
    #"{"__typename":"CheckRun","name":"\#(name)","status":"\#(status)","conclusion":\#(conclusion == "null" ? conclusion : "\"\(conclusion)\""),"startedAt":\#(started),"completedAt":\#(completed),"detailsUrl":"https://github.com/x/\#(name)","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}"#
}

let githubDetailTests: [(name: String, run: () throws -> Void)] = [
    ("a pull request detail is parsed with branches, people, labels and numbers", {
        let detail = try GitHubLogic.parseDetail(detailJSON())
        check(detail.repo == "acme/api" && detail.number == 7 && detail.title == "QDLY-1: Title", "identity")
        check(detail.state == .open && !detail.isDraft && detail.mergeable == .mergeable && detail.review == .required, "state")
        check(detail.base == "develop" && detail.head == "NI/QDLY-1-title", "branches")
        check(detail.additions == 10 && detail.deletions == 2 && detail.changedFiles == 3, "numbers")
        check(detail.labels == ["bug"] && detail.assignees == ["niklas"] && detail.author == "niklas", "labels and people")
        check(detail.ticket == "QDLY-1", "ticket")
        check(detail.created == Date(timeIntervalSince1970: 1_792_404_000), "created")
    }),

    ("reviewers: requests are pending, a re-request beats the old review, teams are marked, the worst state comes first", {
        let reviewers = try GitHubLogic.parseDetail(detailJSON()).reviewers
        check(reviewers.map(\.name) == ["sara", "backend", "elin", "ghost", "johan"], "order \(reviewers.map(\.name))")
        check(reviewers.first { $0.name == "elin" }?.state == .pending, "re-requested elin is pending")
        check(reviewers.first { $0.name == "backend" }?.isTeam == true, "team")
        check(reviewers.first { $0.name == "johan" }?.state == .approved, "approved")
        check(reviewers.first { $0.name == "ghost" }?.state == .commented, "review by a deleted user")
    }),

    ("merged, closed and draft pull requests, a ghost author, an unknown mergeable and no review decision", {
        let json = String(decoding: detailJSON(), as: UTF8.self)
            .replacingOccurrences(of: #""state":"OPEN","merged":false"#, with: #""state":"MERGED","merged":true"#)
            .replacingOccurrences(of: #""author":{"login":"niklas"}"#, with: #""author":null"#)
            .replacingOccurrences(of: #""mergeable":"MERGEABLE""#, with: #""mergeable":"UNKNOWN""#)
            .replacingOccurrences(of: #""reviewDecision":"REVIEW_REQUIRED""#, with: #""reviewDecision":null"#)
        let detail = try GitHubLogic.parseDetail(Data(json.utf8))
        check(detail.state == .merged && detail.author == nil && detail.mergeable == .unknown && detail.review == nil, "merged ghost")
        check(GitHubLogic.stateText(detail) == "Merged", "state text")
        let closed = try GitHubLogic.parseDetail(Data(json.replacingOccurrences(of: #""state":"MERGED","merged":true"#, with: #""state":"CLOSED","merged":false"#).utf8))
        check(closed.state == .closed, "closed")
        let draft = try GitHubLogic.parseDetail(Data(json.replacingOccurrences(of: #""isDraft":false"#, with: #""isDraft":true"#)
            .replacingOccurrences(of: #""state":"MERGED","merged":true"#, with: #""state":"OPEN","merged":false"#).utf8))
        check(GitHubLogic.stateText(draft) == "Draft", "draft")
    }),

    ("check runs map their conclusions, status contexts map their states, and failed checks come first", {
        let contexts = "[" + [
            run("lint", "COMPLETED", "SUCCESS", started: #""2026-10-19T10:00:00Z""#, completed: #""2026-10-19T10:01:20Z""#),
            run("e2e", "COMPLETED", "FAILURE"), run("build", "IN_PROGRESS"), run("deploy", "QUEUED"), run("docs", "COMPLETED", "SKIPPED"),
            run("old", "COMPLETED", "CANCELLED"), run("neutral", "COMPLETED", "NEUTRAL"), run("slow", "COMPLETED", "TIMED_OUT"),
            run("manual", "COMPLETED", "ACTION_REQUIRED"), run("wait", "WAITING"),
            #"{"__typename":"StatusContext","context":"snyk","state":"ERROR","targetUrl":"https://snyk.io"}"#,
            #"{"__typename":"StatusContext","context":"ci/legacy","state":"PENDING","targetUrl":null}"#,
            #"{"__typename":"StatusContext","context":"cla","state":"SUCCESS","targetUrl":null}"#,
        ].joined(separator: ",") + "]"
        let detail = try GitHubLogic.parseDetail(detailJSON(contexts: contexts))
        let status = Dictionary(uniqueKeysWithValues: detail.checks.map { ($0.name, $0.status) })
        check(status["lint"] == .passed && status["neutral"] == .passed && status["cla"] == .passed, "passed")
        check(status["e2e"] == .failed && status["slow"] == .failed && status["manual"] == .failed && status["snyk"] == .failed, "failed")
        check(status["build"] == .running, "running")
        check(status["deploy"] == .pending && status["wait"] == .pending && status["ci/legacy"] == .pending, "pending")
        check(status["docs"] == .skipped && status["old"] == .cancelled, "skipped and cancelled")
        check(detail.checks.prefix(4).allSatisfy { $0.status == .failed }, "failed first")
        check(detail.checks.last?.status == .skipped, "skipped last")
        check(detail.checks.first { $0.name == "lint" }?.duration == 80 && detail.checks.first { $0.name == "lint" }?.workflow == "CI", "duration and workflow")
        check(detail.checks.first { $0.name == "e2e" }?.duration == nil, "no duration without times")
        check(detail.hasRunningChecks, "running checks keep the page refreshing")
        check(GitHubLogic.checkSummary(detail.checks) == "4 failed · 1 running · 3 pending · 1 cancelled · 3 passed · 1 skipped", GitHubLogic.checkSummary(detail.checks))
        check(detail.rollup == .passed, "rollup")
    }),

    ("a pull request without a rollup has no checks and does not refresh", {
        let detail = try GitHubLogic.parseDetail(detailJSON(rollup: "null"))
        check(detail.checks.isEmpty && detail.rollup == .none && !detail.hasRunningChecks, "none")
        check(GitHubLogic.checkSummary([]) == "No checks", "summary")
        let done = try GitHubLogic.parseDetail(detailJSON(contexts: "[\(run("a", "COMPLETED", "SUCCESS"))]"))
        check(!done.hasRunningChecks, "finished checks stop the refresh")
    }),

    ("commits and files are parsed, and more than a page is counted", {
        let commits = #"[{"commit":{"oid":"abcdef1234567","messageHeadline":"Fix it","committedDate":"2026-10-19T09:00:00Z","url":"https://github.com/acme/api/commit/abcdef1","authors":{"nodes":[{"user":{"login":"niklas"},"name":"Niklas"}]},"statusCheckRollup":{"state":"FAILURE"}}},"#
            + #"{"commit":{"oid":"1234567abcdef","messageHeadline":"Merge","committedDate":null,"url":null,"authors":{"nodes":[{"user":null,"name":"Bot Name"}]},"statusCheckRollup":null}},"#
            + #"{"commit":{"oid":"0000000aaaaaa","messageHeadline":"No author","committedDate":null,"url":null,"authors":{"nodes":[]},"statusCheckRollup":null}}]"#
        let files = #"[{"path":"src/app/main.py","additions":5,"deletions":1,"changeType":"MODIFIED"},{"path":"README.md","additions":1,"deletions":0,"changeType":"ADDED"},"#
            + #"{"path":"old.py","additions":0,"deletions":9,"changeType":"DELETED"},{"path":"b/new.py","additions":0,"deletions":0,"changeType":"RENAMED"},{"path":"x","additions":0,"deletions":0,"changeType":"WEIRD"}]"#
        let detail = try GitHubLogic.parseDetail(detailJSON(commits: commits, commitCount: 250, files: files, fileCount: 312))
        check(detail.commits.map(\.shortOid) == ["abcdef1", "1234567", "0000000"], "short ids")
        check(detail.commits.map(\.author) == ["niklas", "Bot Name", nil], "authors")
        check(detail.commits[0].checks == .failed && detail.commits[1].checks == .none && detail.commits[0].date != nil, "commit checks and date")
        check(detail.commitCount == 250 && detail.fileCount == 312, "totals")
        check(GitHubLogic.countNote(shown: detail.commits.count, total: detail.commitCount, noun: "commits") == "Showing the first 3 of 250 commits", "commit note")
        check(GitHubLogic.countNote(shown: 3, total: 3, noun: "commits") == nil, "no note when all are shown")
        check(detail.files.map(\.change) == [.modified, .added, .removed, .renamed, .changed], "change types")
        check(detail.files[0].directory == "src/app/" && detail.files[0].name == "main.py" && detail.files[1].directory.isEmpty, "directory split")
        check(GitHubLogic.files(detail.files, matching: "SRC main").map(\.path) == ["src/app/main.py"], "file filter")
        check(GitHubLogic.files(detail.files, matching: "").count == 5, "empty filter keeps all")
    }),

    ("errors and a missing pull request are classified", {
        do {
            _ = try GitHubLogic.parseDetail(Data(#"{"data":{"repository":{"pullRequest":null}},"errors":[{"message":"Could not resolve to a PullRequest"}]}"#.utf8))
            check(false, "should throw")
        } catch { check(error is GitHubError, "a GitHubError") }
        do {
            _ = try GitHubLogic.parseDetail(Data("not json".utf8))
            check(false, "should throw")
        } catch { check(error as? GitHubError == .failed("unexpected response"), "unexpected response") }
        do {
            _ = try GitHubLogic.parseDetail(Data(#"{"data":null,"errors":[{"message":"API rate limit exceeded"}]}"#.utf8))
            check(false, "should throw")
        } catch { check(error as? GitHubError == .rateLimited, "rate limit") }
    }),

    ("a pull request reference and the repository of an address are read", {
        check(GitHubLogic.reference("acme/api#12")?.repo == "acme/api" && GitHubLogic.reference("acme/api#12")?.number == 12, "reference")
        check(GitHubLogic.reference("acme#12") == nil && GitHubLogic.reference("acme/api") == nil && GitHubLogic.reference("a/b#x") == nil, "bad references")
        check(GitHubLogic.repository(of: "https://github.com/acme/api/pull/7") == "acme/api", "repository")
        check(GitHubLogic.detailArguments(repo: "acme/api", number: 7).contains("owner=acme"), "arguments")
    }),

    ("durations and initials read well", {
        check(GitHubLogic.durationText(7) == "7s" && GitHubLogic.durationText(80) == "1m 20s" && GitHubLogic.durationText(120) == "2m", "short")
        check(GitHubLogic.durationText(3700) == "1h 1m", "hour")
        check(GitHubLogic.initials("niklas") == "NI" && GitHubLogic.initials("Elin Berg") == "EB" && GitHubLogic.initials("back-end") == "BE", "initials")
    }),

    ("the description drops comments, turns img tags into images and strips layout tags", {
        let body = "<!-- template -->\n## Summary\n<img width=\"300\" alt=\"shot\" src=\"https://github.com/user-attachments/1\">\n<details>\n<summary>More</summary>\n\nhidden **text**\n</details>\n\n\n\nEnd"
        let cleaned = GitHubLogic.cleanBody(body)
        check(!cleaned.contains("template") && !cleaned.contains("<details>") && !cleaned.contains("<summary>"), "tags gone: \(cleaned)")
        check(cleaned.contains("![shot](https://github.com/user-attachments/1)"), "image")
        check(!cleaned.contains("\n\n\n"), "blank lines collapsed")
        check(!GitHubLogic.isLong("short") && GitHubLogic.isLong(String(repeating: "x\n", count: 30)) && GitHubLogic.isLong(String(repeating: "x", count: 1300)), "long")
        check(GitHubLogic.preview(String(repeating: "word ", count: 400)).count < 720, "preview is cut")
    }),

    ("markdown blocks: task lists, fenced code, tables, images and nested bullets", {
        let text = "## Plan\n- [x] done\n- [ ] todo\n  - nested\n\n```swift\nlet a = 1\n\n# not a heading\n```\n\n| A | B |\n|---|---|\n| 1 | two |\n\n![diagram](https://example.com/a.png)\n\n1. first\n\ntext with `code`"
        let blocks = ChatLogic.blocks(text)
        check(blocks == [
            .heading("Plan"), .task(level: 0, done: true, text: "done"), .task(level: 0, done: false, text: "todo"), .bullet(level: 1, text: "nested"),
            .code("let a = 1\n\n# not a heading"), .table([["A", "B"], ["1", "two"]]), .image(alt: "diagram", url: "https://example.com/a.png"),
            .numbered("1", text: "first"), .paragraph("text with `code`"),
        ], "\(blocks)")
        check(ChatLogic.blocks("```\nunclosed") == [.code("unclosed")], "an unclosed fence keeps its code")
        check(ChatLogic.blocks("see ![x](u) inline") == [.paragraph("see ![x](u) inline")], "an inline image stays in the paragraph")
        check(ChatLogic.blocks("- not a task [ ] here") == [.bullet(level: 0, text: "not a task [ ] here")], "bullet")
    }),

    ("a table is aligned as plain text under a rule", {
        check(GitHubLogic.alignedTable([["Name", "N"], ["a", "10"]]) == "Name  N \n\u{2500}\u{2500}\u{2500}\u{2500}  \u{2500}\u{2500}\na     10", GitHubLogic.alignedTable([["Name", "N"], ["a", "10"]]))
    }),

    ("the detail is cached per pull request and cleared with the cache", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("githubdetail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let url = "https://github.com/acme/api/pull/7"
        check(try store.githubDetail(url) == nil, "nothing cached")
        try store.saveGitHubDetail(url, json: detailJSON())
        check(try store.githubDetail(url)?.title == "QDLY-1: Title", "cached")
        try store.saveGitHubDetail(url, json: Data("garbage".utf8))
        check(try store.githubDetail(url) == nil, "an unreadable cache row is ignored")
        try store.saveGitHubDetail(url, json: detailJSON())
        try store.deleteAll()
        check(try store.githubDetail(url) != nil, "delete all activity leaves it")
        _ = try store.clearGitHubCache()
        check(try store.githubDetail(url) == nil, "cleared")
    }),
    ("the merge state and the methods the repository allows are read from the detail", {
        let bare = try GitHubLogic.parseDetail(detailJSON())
        check(bare.mergeState == .unknown && bare.mergeMethods.isEmpty, "not known without the settings")
        let json = String(decoding: detailJSON(), as: UTF8.self)
            .replacingOccurrences(of: #""repository":{"pullRequest":{"#, with: #""repository":{"squashMergeAllowed":false,"mergeCommitAllowed":true,"rebaseMergeAllowed":true,"pullRequest":{"#)
            .replacingOccurrences(of: #""mergeable":"MERGEABLE""#, with: #""mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED""#)
        let detail = try GitHubLogic.parseDetail(Data(json.utf8))
        check(detail.mergeState == .blocked, "blocked by protection")
        check(detail.mergeMethods == [.merge, .rebase], "squash is not offered: \(detail.mergeMethods)")
    }),
]
