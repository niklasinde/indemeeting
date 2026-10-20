import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func at(_ hours: Double) -> Date { Date(timeIntervalSince1970: 1_792_000_000 + hours * 3600) }

private func stamp(_ hours: Double) -> String { ISO8601DateFormatter().string(from: at(hours)) }

private func user(_ login: String?, bot: Bool = false) -> String {
    login.map { #"{"login":"\#($0)","__typename":"\#(bot ? "Bot" : "User")"}"# } ?? "null"
}

private func node(_ id: String, _ login: String?, _ body: String, hours: Double = 0, bot: Bool = false, review: String? = nil, url: Bool = true) -> String {
    let escaped = String(decoding: (try? JSONEncoder().encode(body)) ?? Data(), as: UTF8.self)
    return #"{"id":"\#(id)","author":\#(user(login, bot: bot)),"body":\#(escaped),"createdAt":"\#(stamp(hours))","url":"https://github.com/acme/api/pull/7#\#(id)","pullRequestReview":\#(review.map { #"{"state":"\#($0)"}"# } ?? "null")}"#
}

private func thread(_ id: String, path: String = "src/a.py", line: String = "10", resolved: Bool = false, outdated: Bool = false, resolvedBy: String? = nil,
                    subject: String = "LINE", hunk: String = "@@ -1,2 +1,3 @@\n a\n-b\n+c", comments: [String], total: Int? = nil) -> String {
    let escaped = String(decoding: (try? JSONEncoder().encode(hunk)) ?? Data(), as: UTF8.self)
    return #"{"id":"\#(id)","isResolved":\#(resolved),"isOutdated":\#(outdated),"path":"\#(path)","line":\#(line),"originalLine":8,"startLine":null,"subjectType":"\#(subject)","resolvedBy":\#(resolvedBy.map { #"{"login":"\#($0)"}"# } ?? "null"),"head":{"nodes":[{"diffHunk":\#(escaped)}]},"comments":{"totalCount":\#(total ?? comments.count),"nodes":[\#(comments.joined(separator: ","))]}}"#
}

private func commentsJSON(threads: [String] = [], threadMore: Bool = false, threadCursor: String = "T1", issue: [String] = [], reviews: [String] = [],
                          issueMore: Bool = false, total: Int? = nil, cost: Int = 3) -> Data {
    Data("""
    {"data":{"rateLimit":{"cost":\(cost),"remaining":4990},"viewer":{"login":"niklas"},"repository":{"pullRequest":{"headRefOid":"abc1234",
      "comments":{"totalCount":\(issue.count),"pageInfo":{"hasNextPage":\(issueMore),"endCursor":"C1"},"nodes":[\(issue.joined(separator: ","))]},
      "reviews":{"totalCount":\(reviews.count),"pageInfo":{"hasNextPage":false,"endCursor":"R1"},"nodes":[\(reviews.joined(separator: ","))]},
      "reviewThreads":{"totalCount":\(total ?? threads.count),"pageInfo":{"hasNextPage":\(threadMore),"endCursor":"\(threadCursor)"},"nodes":[\(threads.joined(separator: ","))]}}}}}
    """.utf8)
}

private func review(_ id: String, _ login: String?, _ state: String, _ body: String, hours: Double) -> String {
    let escaped = String(decoding: (try? JSONEncoder().encode(body)) ?? Data(), as: UTF8.self)
    return #"{"id":"\#(id)","author":\#(user(login)),"body":\#(escaped),"state":"\#(state)","submittedAt":"\#(stamp(hours))","url":"https://github.com/acme/api/pull/7#\#(id)"}"#
}

private func sample() throws -> GitHubComments {
    try GitHubLogic.parseComments(commentsJSON(
        threads: [
            thread("T1", resolved: false, comments: [node("a", "sara", "First", hours: 1, review: "CHANGES_REQUESTED"), node("b", "niklas", "Reply", hours: 2, review: "COMMENTED")]),
            thread("T2", path: "src/b.py", line: "3", resolved: true, resolvedBy: "sara", comments: [node("c", "elin", "Nit: rename", hours: 3)]),
            thread("T3", path: "src/a.py", line: "null", outdated: true, comments: [node("d", nil, "From a deleted user", hours: 4)]),
            thread("T4", path: "README.md", line: "null", subject: "FILE", comments: [node("e", "coderabbitai", "Bot says", hours: 5, bot: true)]),
            thread("T5", path: "src/a.py", line: "2", comments: [node("f", "copilot-pull-request-reviewer", "Copilot says", hours: 6)]),
            "null",
            #"{"id":"T7","path":"x.py","line":1,"comments":{"nodes":[]}}"#,
        ],
        issue: [node("i1", "johan", "Looks fine", hours: 9), node("i2", "github-actions", "Deployed", hours: 7)],
        reviews: [review("r1", "johan", "APPROVED", "Ship it", hours: 8), review("r2", "elin", "COMMENTED", "", hours: 10), review("r3", "niklas", "PENDING", "draft", hours: 11)]))
}

let githubCommentsTests: [(name: String, run: () throws -> Void)] = [
    ("threads are parsed with their location, state, resolver, authors and review states; broken nodes are skipped", {
        let comments = try sample()
        check(comments.me == "niklas" && comments.headOid == "abc1234" && comments.cost == 3 && comments.remaining == 4990, "header")
        check(comments.threads.map(\.id) == ["T1", "T2", "T3", "T4", "T5"], "ids \(comments.threads.map(\.id))")
        let first = comments.threads[0]
        check(first.comments.map(\.id) == ["a", "b"] && first.comments[0].author.login == "sara" && first.comments[0].created == at(1), "comments in order")
        check(first.comments[0].review == .changesRequested && first.comments[1].review == .commented, "review states")
        check(first.url == "https://github.com/acme/api/pull/7#a" && first.commentCount == 2, "url and count")
        check(comments.threads[1].isResolved && comments.threads[1].resolvedBy == "sara", "resolved by")
        check(comments.threads[2].isOutdated && comments.threads[2].line == nil && comments.threads[2].originalLine == 8, "outdated")
        check(comments.threads[2].comments[0].author.login == "ghost", "ghost author")
        check(comments.threads[3].isFile && GitHubLogic.badge(comments.threads[3]) == "file-level", "file level")
        check(GitHubLogic.badge(comments.threads[2]) == "outdated" && GitHubLogic.badge(first) == nil, "badges")
        check(GitHubLogic.location(first) == "src/a.py:10" && GitHubLogic.location(comments.threads[2]) == "src/a.py:8" && GitHubLogic.location(comments.threads[3]) == "README.md", "locations")
        check(comments.unresolved == 4 && comments.commentCount == 9, "counts \(comments.unresolved) \(comments.commentCount)")
        check(GitHubLogic.commentsSummary(comments) == "5 threads \u{00B7} 4 unresolved \u{00B7} 9 comments", "summary \(GitHubLogic.commentsSummary(comments))")
    }),

    ("bots are told by account type, the [bot] suffix and the usual names", {
        let comments = try sample()
        let bots = comments.threads.flatMap(\.comments).filter(\.author.isBot).map(\.id)
        check(bots == ["e", "f"], "bots \(bots)")
        check(GitHubLogic.isBot(login: "dependabot[bot]", typename: nil) && GitHubLogic.isBot(login: "snyk-bot", typename: nil), "names")
        check(GitHubLogic.isBot(login: "sonarcloud", typename: nil) && GitHubLogic.isBot(login: "x", typename: "Bot"), "more names and type")
        check(!GitHubLogic.isBot(login: "niklas", typename: "User") && !GitHubLogic.isBot(login: "ghost", typename: nil), "people")
    }),

    ("the conversation holds comments and review summaries with a text, oldest first; empty and pending reviews are left out", {
        let conversation = try sample().conversation
        check(conversation.map(\.id) == ["i2", "r1", "i1"], "order \(conversation.map(\.id))")
        check(conversation[1].review == .approved && conversation[0].review == nil, "review state only on reviews")
        check(conversation[0].author.isBot, "github-actions is a bot")
    }),

    ("pagination: cursors and totals come with the page, a second page is appended without duplicates, and the cache holds both", {
        let one = commentsJSON(threads: [thread("T1", comments: [node("a", "sara", "x")]), thread("T2", comments: [node("b", "sara", "y")])], threadMore: true, threadCursor: "CUR1", issueMore: true, total: 5, cost: 2)
        let two = commentsJSON(threads: [thread("T2", comments: [node("b", "sara", "y")]), thread("T3", comments: [node("c", "sara", "z")])], threadMore: false, threadCursor: "CUR2", total: 5, cost: 4)
        let first = try GitHubLogic.parseComments(one)
        check(first.hasMore && first.cursors.threads == .init(after: "CUR1", more: true) && first.cursors.comments.more && first.threadTotal == 5, "first page \(first.cursors)")
        check(GitHubLogic.commentsProgress(first) == "2 of 5 threads", "progress")
        let merged = first.appending(try GitHubLogic.parseComments(two))
        check(merged.threads.map(\.id) == ["T1", "T2", "T3"] && merged.cost == 6, "merged \(merged.threads.map(\.id)) \(merged.cost)")
        check(merged.cursors.threads == .init(after: "CUR2", more: false) && merged.cursors.comments.more == false, "cursors advanced")
        check(!merged.hasMore && GitHubLogic.commentsProgress(merged) == nil, "done")
        let cache = GitHubLogic.commentsCache(GitHubLogic.commentsCache(nil, adding: one), adding: two)
        check(try GitHubLogic.parseComments(cache) == merged, "the cache reads back as the merged pages")
        check(try GitHubLogic.parseComments(GitHubLogic.commentsCache(nil, adding: one)) == first, "a one page cache")
        let arguments = GitHubLogic.commentsArguments(repo: "acme/api", number: 7, after: first.cursors)
        check(arguments.contains("threads=CUR1") && arguments.contains("comments=C1") && arguments.contains("owner=acme"), "arguments carry the cursors")
        check(!GitHubLogic.commentsArguments(repo: "acme/api", number: 7).contains { $0.hasPrefix("threads=") }, "no cursor on the first page")
        check(GitHubLogic.commentsQuery.contains("head: comments(first: 1)"), "the hunk is asked for on the first comment only")
    }),

    ("a response without the pull request or that cannot be read is an error", {
        do { _ = try GitHubLogic.parseComments(Data(#"{"data":{"repository":{"pullRequest":null}},"errors":[{"message":"API rate limit exceeded"}]}"#.utf8)); check(false, "parsed") } catch {
            check(error as? GitHubError == .rateLimited, "rate limited")
        }
        do { _ = try GitHubLogic.parseComments(Data("nope".utf8)); check(false, "parsed") } catch { check(error as? GitHubError == .failed("unexpected response"), "unreadable") }
    }),

    ("a diff hunk is cut to its last lines and each line classified", {
        let hunk = "@@ -1,9 +1,10 @@ def f():\n a\n b\n c\n d\n e\n-old\n+new\n+newer\n tail\n\\ No newline at end of file"
        let lines = GitHubLogic.diffLines(hunk, last: 6)
        check(lines.count == 6 && lines.last == GitHubDiffLine(kind: .context, text: "tail"), "last six without the marker line")
        check(lines.map(\.kind) == [.context, .context, .removed, .added, .added, .context], "kinds \(lines.map(\.kind))")
        check(lines[3].text == "new" && lines[2].text == "old", "text without the marker")
        check(GitHubLogic.diffLines("").count == 1 && GitHubLogic.diffLines("@@ -1 +1 @@").isEmpty, "empty hunks")
        var thread = GitHubThread(id: "t", path: "a", line: 5, diff: GitHubLogic.diffLines(hunk))
        check(GitHubLogic.suggestionBefore(thread).map(\.text) == ["tail"], "one line replaced")
        thread.startLine = 3
        check(GitHubLogic.suggestionBefore(thread).count == 3, "a range replaced")
        thread.isOutdated = true
        check(GitHubLogic.suggestionBefore(thread).isEmpty, "none when outdated")
    }),

    ("threads are filtered by unresolved, mine, new, bots and search, and grouped by file in line order", {
        let comments = try sample()
        func ids(_ filter: GitHubCommentsFilter, after: Date? = nil) -> [String] { GitHubLogic.visibleThreads(comments, filter, after: after).map(\.id) }
        check(ids(GitHubCommentsFilter()) == ["T1", "T2", "T3", "T4", "T5"], "all")
        check(ids(GitHubCommentsFilter(scope: .unresolved)) == ["T1", "T3", "T4", "T5"], "unresolved")
        check(ids(GitHubCommentsFilter(scope: .mine)) == ["T1"], "mine: started or replied in")
        check(ids(GitHubCommentsFilter(hideBots: true)) == ["T1", "T2", "T3"], "hide bots")
        check(ids(GitHubCommentsFilter(scope: .new), after: at(3.5)) == ["T3", "T4", "T5"], "new after the cutoff")
        check(ids(GitHubCommentsFilter(scope: .new)).isEmpty, "nothing is new without a cutoff")
        check(ids(GitHubCommentsFilter(query: "readme")) == ["T4"], "search the path")
        check(ids(GitHubCommentsFilter(query: "SARA rename")).isEmpty && ids(GitHubCommentsFilter(query: "elin RENAME")) == ["T2"], "all words, any case, author and text")
        check(ids(GitHubCommentsFilter(scope: .unresolved, hideBots: true, query: "deleted")) == ["T3"], "combined")
        let groups = GitHubLogic.groupedByFile(comments.threads)
        check(groups.map(\.path) == ["README.md", "src/a.py", "src/b.py"], "files in order \(groups.map(\.path))")
        check(groups[1].threads.map(\.id) == ["T5", "T3", "T1"] || groups[1].threads.map(\.id) == ["T5", "T1", "T3"], "by line")
        check(groups[1].directory == "src/" && groups[1].name == "a.py" && groups[0].directory == "", "path parts")
        check(GitHubLogic.defaultScope(comments) == .unresolved && GitHubLogic.defaultScope(GitHubComments()) == .all, "default scope")
    }),

    ("the conversation follows the filter, and is left out of the unresolved view", {
        let comments = try sample()
        func ids(_ filter: GitHubCommentsFilter, after: Date? = nil) -> [String] { GitHubLogic.visibleConversation(comments, filter, after: after).map(\.id) }
        check(ids(GitHubCommentsFilter()) == ["i2", "r1", "i1"], "all")
        check(ids(GitHubCommentsFilter(scope: .unresolved)).isEmpty, "unresolved")
        check(ids(GitHubCommentsFilter(hideBots: true)) == ["r1", "i1"], "hide bots")
        check(ids(GitHubCommentsFilter(query: "ship")) == ["r1"], "search")
        check(ids(GitHubCommentsFilter(scope: .new), after: at(8.5)) == ["i1"], "new")
        check(ids(GitHubCommentsFilter(scope: .mine)).isEmpty, "nothing of mine")
    }),

    ("a resolved thread is folded into one line", {
        let comments = try sample()
        check(GitHubLogic.resolvedLine(comments.threads[1]) == "Resolved by sara \u{00B7} src/b.py:3 \u{00B7} Nit: rename", GitHubLogic.resolvedLine(comments.threads[1]))
    }),

    ("a comment is new when someone else wrote it after your last activity; the cutoff is the list's", {
        let comment = GitHubComment(id: "x", author: .init(login: "elin"), body: "", parts: [], created: at(5))
        check(GitHubLogic.isNew(comment, me: "me", after: at(4)), "after")
        check(!GitHubLogic.isNew(comment, me: "me", after: at(6)) && !GitHubLogic.isNew(comment, me: "elin", after: at(4)), "before, or mine")
        check(!GitHubLogic.isNew(comment, me: "me", after: nil), "no cutoff")
        let activity = GitHubActivity(me: "me", open: [.init(actor: .init(login: "me"), date: at(2)), .init(actor: .init(login: "elin"), date: at(3))],
                                      lastComment: .init(actor: .init(login: "me"), date: at(1)), lastCommit: at(0))
        func pr(_ author: String, _ state: GitHubPR.State = .open) -> GitHubPR {
            GitHubPR(url: "u", number: 1, title: "t", repo: "a/b", state: state, updated: at(0), author: author, activity: activity)
        }
        check(GitHubLogic.feedbackCutoff(pr("me")) == at(2), "my pull request: my newest commit, comment or reply")
        check(GitHubLogic.feedbackCutoff(pr("elin")) == at(2), "someone else's: my replies")
        check(GitHubLogic.feedbackCutoff(pr("elin", .merged)) == nil, "closed")
        var quiet = pr("elin")
        quiet.activity = GitHubActivity(me: "me")
        check(GitHubLogic.feedbackCutoff(quiet) == nil, "I have not taken part")
    }),

    ("HTML in comments: details become sections, comments are dropped, tags become Markdown", {
        let body = """
            <!-- auto-generated -->
            _Potential issue_ | _Major_

            **Log before returning.** See <a href="https://example.com/x">the docs</a> and <code>log.info</code>.

            <details>
            <summary>\u{1F4DD} <b>Committable</b> suggestion</summary>

            Check it first.

            ```suggestion
            if x:

                return
            ```

            <details><summary>Inner</summary>deep text</details>
            </details>

            <h3>Notes</h3>
            <ul><li>one</li><li>two</li></ul>
            """
        let parts = GitHubLogic.commentParts(body)
        check(parts.count == 3, "three parts \(parts)")
        guard parts.count == 3, case .markdown(let intro) = parts[0], case .details(let summary, let inner) = parts[1], case .markdown(let notes) = parts[2] else { return check(false, "shape \(parts)") }
        check(!intro.contains("<") && intro.contains("[the docs](https://example.com/x)") && intro.contains("`log.info`") && intro.contains("Potential issue"), "intro \(intro)")
        check(summary == "\u{1F4DD} Committable suggestion", "summary \(summary)")
        check(inner.count == 3, "inner parts \(inner)")
        if inner.count == 3 {
            check(inner[0] == .markdown("Check it first."), "inner text")
            check(inner[1] == .suggestion("if x:\n\n    return"), "suggestion keeps its blank line \(inner[1])")
            check(inner[2] == .details(summary: "Inner", parts: [.markdown("deep text")]), "nested details")
        }
        check(notes.contains("### Notes") && notes.contains("- one") && notes.contains("- two") && !notes.contains("<"), "notes \(notes)")
        check(GitHubLogic.commentParts("<details><summary></summary>x") == [.details(summary: "Details", parts: [.markdown("x")])], "unclosed details and no summary")
        check(GitHubLogic.commentParts("   ").isEmpty, "blank")
    }),

    ("a suggestion block is its own part, with the code as written", {
        check(GitHubLogic.commentParts("Use this:\n```suggestion\nlet a = 1\n```\nThanks") == [.markdown("Use this:"), .suggestion("let a = 1"), .markdown("Thanks")], "suggestion")
        check(GitHubLogic.commentParts("```swift\ncode\n```") == [.markdown("```swift\ncode\n```")], "other fences stay Markdown")
        check(GitHubLogic.commentParts("```suggestion\n```") == [.suggestion("")], "an empty suggestion removes the lines")
    }),

    ("a long bot comment shows its opening paragraphs until asked for in full; short and human comments show whole", {
        let bot = """
            <!-- marker -->
            _Potential issue_ | _Major_

            **The guard skips the log line.**

            Support cannot follow a disabled tenant.

            <details><summary>Prompt</summary>

            do things

            </details>
            """
        let comments = try GitHubLogic.parseComments(commentsJSON(threads: [thread("T1", comments: [node("a", "coderabbitai", bot, bot: true), node("b", "coderabbitai", "Short", bot: true), node("c", "sara", bot)])]))
        let digest = comments.threads[0].comments[0].digest
        check(digest?.contains("Potential issue") == true && digest?.contains("**The guard skips the log line.**") == true && digest?.contains("do things") == false, "digest \(String(describing: digest))")
        check(comments.threads[0].comments[1].digest == nil, "short bot comment")
        check(comments.threads[0].comments[2].digest == nil, "people are never collapsed")
        let long = String(repeating: "word ", count: 200)
        check(GitHubLogic.digest(GitHubLogic.commentParts(long), body: long) != nil, "long without details")
        check(GitHubLogic.digest([.details(summary: "a", parts: [])], body: "x") == "", "starts with a section: nothing to preview")
    }),

    ("the comment description cleaner keeps the earlier behaviour for pull request descriptions", {
        check(GitHubLogic.cleanBody("<!-- c -->Hi <b>there</b>\n\n\n\n<img src=\"u\" alt=\"a\">") == "Hi \nthere\n\n![a](u)", GitHubLogic.cleanBody("<!-- c -->Hi <b>there</b>\n\n\n\n<img src=\"u\" alt=\"a\">"))
    }),

    ("the comment cache round trips per pull request, replaces the earlier, and clears with the GitHub cache", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("github-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        check(try store.githubComments("u1") == nil, "empty")
        let json = GitHubLogic.commentsCache(nil, adding: commentsJSON(threads: [thread("T1", comments: [node("a", "sara", "x")])]))
        try store.saveGitHubComments("u1", json: json, headSHA: "abc")
        let saved = try store.githubComments("u1")
        check(saved?.comments.threads.map(\.id) == ["T1"] && saved?.json == json && saved?.comments.headOid == "abc1234", "round trip")
        let two = GitHubLogic.commentsCache(json, adding: commentsJSON(threads: [thread("T2", comments: [node("b", "sara", "y")])]))
        try store.saveGitHubComments("u1", json: two, headSHA: "abc")
        check(try store.githubComments("u1")?.comments.threads.map(\.id) == ["T1", "T2"], "replaced")
        check(try store.githubComments("u2") == nil, "per pull request")
        _ = try store.clearGitHubCache()
        check(try store.githubComments("u1") == nil, "cleared")
    }),
]
