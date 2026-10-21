import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghactions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A stand-in for `gh`: records every call's arguments, NUL separated, and answers with the given output and exit code.
private struct FakeGH {
    let directory: URL
    let cli: URL

    init(exit status: Int32 = 0, stdout: String = "", stderr: String = "") throws {
        directory = try folder()
        cli = directory.appendingPathComponent("gh")
        let script = """
            #!/bin/sh
            printf '%s\\0' "$@" >> "$(dirname "$0")/argv.log"
            printf '\\n' >> "$(dirname "$0")/calls.log"
            cat <<'OUT'
            \(stdout)
            OUT
            cat >&2 <<'ERR'
            \(stderr)
            ERR
            exit \(status)

            """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    var calls: Int { ((try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").filter { $0 == "\n" }.count }

    var arguments: [String] {
        let data = (try? Data(contentsOf: directory.appendingPathComponent("argv.log"))) ?? Data()
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func pr(_ number: Int = 2442, repo: String = "acme/finq.api", title: String = "QDLY-1: Fix it", state: GitHubPR.State = .open,
                draft: Bool = false, checks: GitHubPR.Checks = .passed, review: GitHubPR.Review? = nil, author: String = "elin",
                me: String = "niklas") -> GitHubPR {
    GitHubPR(url: "https://github.com/\(repo)/pull/\(number)", number: number, title: title, repo: repo, isDraft: draft, state: state,
             updated: Date(timeIntervalSince1970: 1_792_300_000), review: review, checks: checks, author: author,
             activity: GitHubActivity(me: me, authorIsBot: false, threads: 0, open: [], reviews: [], reviewCount: 0, lastComment: nil, lastCommit: nil, requested: []))
}

private func request(_ action: GitHubAction, _ pr: GitHubPR = pr(), comment: String = "", deleteBranch: Bool = false) -> GitHubActionRequest {
    GitHubActionRequest(action, pr: pr).with(comment: comment, deleteBranch: deleteBranch)
}

private func target(_ pr: GitHubPR = pr()) -> GitHubActionTarget { GitHubActionTarget(pr: pr) }

private func isBlocked(_ preflight: GitHubActions.Preflight) -> Bool {
    if case .blocked = preflight { return true }
    return false
}

private func warnings(_ preflight: GitHubActions.Preflight) -> [String] {
    if case .allowed(let warnings) = preflight { return warnings }
    return []
}

private let sourceFolder: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/MeetingRecorder", isDirectory: true)

private func sources() throws -> [String: String] {
    var result: [String: String] = [:]
    for file in try FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
        result[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
    }
    return result
}

let githubActionsTests: [(name: String, run: () throws -> Void)] = [
    ("each action builds its own gh command, one argument per word", {
        check(GitHubActions.arguments(request(.approve)) == ["pr", "review", "2442", "--repo", "acme/finq.api", "--approve"], "approve without a body")
        check(GitHubActions.arguments(request(.approve, comment: "  Looks good\n")) == ["pr", "review", "2442", "--repo", "acme/finq.api", "--approve", "--body", "Looks good"],
              "approve with a trimmed body")
        check(GitHubActions.arguments(request(.requestChanges, comment: "Please add a test")) == ["pr", "review", "2442", "--repo", "acme/finq.api", "--request-changes", "--body", "Please add a test"],
              "request changes")
        check(GitHubActions.arguments(request(.comment, comment: "Question")) == ["pr", "review", "2442", "--repo", "acme/finq.api", "--comment", "--body", "Question"], "comment")
        check(GitHubActions.arguments(request(.close)) == ["pr", "close", "2442", "--repo", "acme/finq.api"], "plain close")
        check(GitHubActions.arguments(request(.close, comment: "Stale", deleteBranch: true)) == ["pr", "close", "2442", "--repo", "acme/finq.api", "--comment", "Stale", "--delete-branch"],
              "close with comment and branch")
        check(!GitHubActions.arguments(request(.close)).contains("--delete-branch"), "the branch stays by default")
        check(GitHubActions.arguments(request(.reopen)) == ["pr", "reopen", "2442", "--repo", "acme/finq.api"], "reopen")
        check(!GitHubActions.arguments(request(.approve, comment: "x", deleteBranch: true)).contains("--delete-branch"), "only close deletes a branch")
    }),

    ("the command line is shown quoted for a terminal", {
        check(GitHubActions.commandLine(request(.approve)) == "gh pr review 2442 --repo acme/finq.api --approve", "plain")
        let line = GitHubActions.commandLine(request(.close, comment: "it's stale; $HOME"))
        check(line == "gh pr close 2442 --repo acme/finq.api --comment 'it'\\''s stale; $HOME'", "quoted: \(line)")
    }),

    ("a comment with quotes, dollar signs, backticks, Swedish letters and newlines reaches gh as one argument", {
        let text = "He said \"hi\" and 'bye' $HOME `uname` $(whoami) \u{00E5}\u{00E4}\u{00F6} \u{00C5}\u{00C4}\u{00D6}\nsecond line; rm -rf / && echo -n"
        for action in [GitHubAction.approve, .requestChanges, .comment, .merge, .close, .reopen] {
            let fake = try FakeGH()
            defer { fake.remove() }
            let ask = request(action, comment: text)
            _ = GitHubActionRunner.perform(ask, cli: fake.cli)
            check(fake.arguments == GitHubActions.arguments(ask), "\(action): arguments reach gh unchanged: \(fake.arguments)")
            check(fake.arguments.contains(text), "\(action): the text is one entry")
            check(fake.calls == 1, "\(action): gh ran once")
        }
        let dashed = try FakeGH()
        defer { dashed.remove() }
        _ = GitHubActionRunner.perform(request(.comment, comment: "--approve"), cli: dashed.cli)
        check(dashed.arguments.suffix(2) == ["--body", "--approve"], "a body that looks like a flag stays a body")
    }),

    ("approving your own pull request is refused, whatever the case of the login", {
        let own = pr(author: "Niklas", me: "niklas")
        check(isBlocked(GitHubActions.preflight(request(.approve, own), target(own))), "approve")
        check(isBlocked(GitHubActions.preflight(request(.requestChanges, own, comment: "x"), target(own))), "request changes")
        check(!isBlocked(GitHubActions.preflight(request(.comment, own, comment: "x"), target(own))), "commenting on your own is fine")
        check(!isBlocked(GitHubActions.preflight(request(.close, own), target(own))), "closing your own is fine")
        let confirmation = GitHubActions.confirmation(for: request(.approve, own), target: target(own))
        check(confirmation.blocker?.contains("author") == true && !confirmation.canConfirm, "the message says why and confirm is off")
        check(confirmation.facts.contains { $0.label == "Author" && $0.value == "Niklas (you)" }, "the sheet says it is you")
    }),

    ("only open pull requests can be approved or closed; reopen needs a closed one", {
        for state in [GitHubPR.State.closed, .merged] {
            let done = pr(state: state)
            check(isBlocked(GitHubActions.preflight(request(.approve, done), target(done))), "approve \(state)")
            check(isBlocked(GitHubActions.preflight(request(.requestChanges, done, comment: "x"), target(done))), "request changes \(state)")
            check(isBlocked(GitHubActions.preflight(request(.close, done), target(done))), "close \(state)")
        }
        check(!isBlocked(GitHubActions.preflight(request(.close), target())), "close open")
        check(!isBlocked(GitHubActions.preflight(request(.comment, pr(state: .closed), comment: "x"), target(pr(state: .closed)))), "comment on a closed one")
        check(!isBlocked(GitHubActions.preflight(request(.reopen, pr(state: .closed)), target(pr(state: .closed)))), "reopen closed")
        check(isBlocked(GitHubActions.preflight(request(.reopen, pr(state: .merged)), target(pr(state: .merged)))), "a merged one cannot be reopened")
        check(isBlocked(GitHubActions.preflight(request(.reopen), target())), "an open one is not reopened")
    }),

    ("drafts and failing checks warn but stay allowed", {
        let draft = pr(draft: true)
        check(warnings(GitHubActions.preflight(request(.approve, draft), target(draft))).contains("This pull request is a draft."), "draft")
        let failing = pr(checks: .failed)
        check(warnings(GitHubActions.preflight(request(.approve, failing), target(failing))) == ["Checks are failing"], "failing checks")
        check(GitHubActions.confirmation(for: request(.approve, failing), target: target(failing)).canConfirm, "still allowed after confirmation")
        let running = pr(checks: .running, review: .changesRequested)
        let more = warnings(GitHubActions.preflight(request(.approve, running), target(running)))
        check(more.contains("Checks are still running") && more.contains("Changes were requested in an earlier review"), "running and requested changes")
        check(warnings(GitHubActions.preflight(request(.close, failing), target(failing))).isEmpty, "closing does not care about checks")
        var unknown = target()
        unknown.viewer = nil
        check(warnings(GitHubActions.preflight(request(.approve), unknown)).count == 1, "an unknown viewer is said out loud")
    }),

    ("the confirmation shows what will happen and who has to click", {
        let failing = pr(checks: .failed, review: .required)
        let approve = GitHubActions.confirmation(for: request(.approve, failing, comment: "Nice"), target: target(failing))
        check(approve.title == "Approve pull request" && approve.confirmTitle == "Approve pull request", "approve title")
        check(approve.reference == "acme/finq.api #2442" && approve.prTitle == "QDLY-1: Fix it", "reference and title")
        check(approve.facts.contains { $0.label == "Author" && $0.value == "elin" }, "author")
        check(approve.facts.contains { $0.label == "Checks" && $0.value == "Failing" && $0.tone == .bad }, "checks")
        check(approve.facts.contains { $0.label == "Review" && $0.tone == .normal }, "review decision")
        check(approve.warnings.map(\.text) == [GitHubActions.checksFailing], "warning line")
        check(approve.command == "gh pr review 2442 --repo acme/finq.api --approve --body Nice", "the exact command: \(approve.command)")
        check(approve.comment == "Nice", "the comment")
        check(!approve.confirmIsDefault, "approving needs a deliberate click, Return does not do it")
        check(!approve.offersBranchDelete, "no branch to delete when approving")
        let close = GitHubActions.confirmation(for: request(.close, comment: "Stale"), target: target())
        check(close.confirmTitle == "Close pull request" && close.confirmIsDefault, "close may use Return")
        check(close.offersBranchDelete, "the branch checkbox is offered")
        check(!close.facts.contains { $0.label == "Checks" }, "no review facts for a close")
        let main = GitHubActions.confirmation(for: request(.close), target: { var t = target(); t.head = "develop"; return t }())
        check(!main.offersBranchDelete, "a kept branch is not offered for deletion")
        let closed = GitHubActions.confirmation(for: request(.close, pr(state: .closed)), target: target(pr(state: .closed)))
        check(!closed.offersBranchDelete && !closed.canConfirm, "nothing to close")
        let change = GitHubActions.confirmation(for: request(.requestChanges), target: target())
        check(change.needsComment && !change.canConfirm, "a required comment holds confirm back")
        let written = GitHubActions.confirmation(for: request(.requestChanges, comment: "Fix"), target: target())
        check(!written.needsComment && written.canConfirm, "and releases it")
        check(GitHubActions.confirmation(for: request(.comment, comment: "  "), target: target()).needsComment, "blank is empty")
    }),

    ("which branches are offered for deletion", {
        check(GitHubActions.branchDeletable(head: "NI/QDLY-1", base: "develop"), "a feature branch")
        check(GitHubActions.branchDeletable(head: nil, base: nil), "unknown is offered, GitHub refuses what it must")
        for kept in ["main", "master", "develop", "Release/2026.10", "release-1"] {
            check(!GitHubActions.branchDeletable(head: kept, base: "main"), "\(kept) is kept")
        }
        check(!GitHubActions.branchDeletable(head: "x", base: "x"), "head equal to base")
    }),

    ("stderr of gh is classified into a readable error", {
        let fixtures: [(String, GitHubActionError)] = [
            ("gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN. You are not logged in to any GitHub hosts. To log in, run: gh auth login", .notLoggedIn),
            ("HTTP 401: Bad credentials (https://api.github.com/graphql)", .notLoggedIn),
            ("GraphQL: Resource not accessible by personal access token (addPullRequestReview)", .missingScope),
            ("error: your authentication token is missing required scopes [repo]", .missingScope),
            ("HTTP 403: Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization.", .sso),
            ("GraphQL: Can not approve your own pull request (addPullRequestReview)", .ownPullRequest),
            ("GraphQL: Can not request changes on your own pull request", .ownPullRequest),
            ("! Pull request acme/api#7 (Fix) is already closed", .alreadyClosed),
            ("GraphQL: Pull request is already merged", .alreadyClosed),
            ("Pull request acme/api#7 can't be reopened because it was already merged", .alreadyClosed),
            ("! Pull request acme/api#7 (Fix) is already open", .alreadyOpen),
            ("failed to delete remote branch: cannot delete branch protected by branch protection rules", .branchProtection("failed to delete remote branch: cannot delete branch protected by branch protection rules")),
            ("GraphQL: Base branch policy prohibits the merge", .branchProtection("GraphQL: Base branch policy prohibits the merge")),
            ("error connecting to api.github.com", .offline),
            ("dial tcp: lookup api.github.com: no such host", .offline),
            ("HTTP 403: API rate limit exceeded for user ID 1", .rateLimited),
            ("You have exceeded a secondary rate limit", .rateLimited),
            ("something odd\nsecond line", .failed("something odd")),
            ("", .failed("unknown error")),
        ]
        for (stderr, expected) in fixtures { check(GitHubActionError.classify(stderr) == expected, "\(stderr) -> \(GitHubActionError.classify(stderr))") }
        for error in [GitHubActionError.cliMissing, .notLoggedIn, .missingScope, .sso, .branchProtection("x"), .ownPullRequest, .alreadyClosed, .alreadyOpen, .offline, .rateLimited, .failed("x")] {
            check(!error.message.isEmpty, "\(error) has a message")
        }
        check(GitHubActionError.sso.message.contains("SAML") && GitHubActionError.missingScope.message.contains("repo"), "the messages say what to do")
    }),

    ("a fake gh answers success, your own pull request, SSO and branch protection", {
        let ok = try FakeGH(stdout: "\u{2713} Closed pull request acme/finq.api#2442")
        defer { ok.remove() }
        check(GitHubActionRunner.perform(request(.close), cli: ok.cli) == .success("\u{2713} Closed pull request acme/finq.api#2442"), "success")
        let own = try FakeGH(exit: 1, stderr: "GraphQL: Can not approve your own pull request (addPullRequestReview)")
        defer { own.remove() }
        check(GitHubActionRunner.perform(request(.approve), cli: own.cli) == .failure(.ownPullRequest), "own pull request")
        let sso = try FakeGH(exit: 1, stderr: "HTTP 403: Resource protected by organization SAML enforcement.")
        defer { sso.remove() }
        check(GitHubActionRunner.perform(request(.approve), cli: sso.cli) == .failure(.sso), "sso")
        let protected = try FakeGH(exit: 1, stderr: "GraphQL: Base branch policy prohibits the merge")
        defer { protected.remove() }
        if case .failure(.branchProtection) = GitHubActionRunner.perform(request(.close), cli: protected.cli) {} else { check(false, "branch protection") }
        let closed = try FakeGH(exit: 0, stderr: "! Pull request acme/finq.api#2442 (QDLY-1: Fix it) is already closed")
        defer { closed.remove() }
        check(GitHubActionRunner.perform(request(.close), cli: closed.cli) == .failure(.alreadyClosed), "gh answers an already closed pull request with exit 0")
        let open = try FakeGH(exit: 0, stderr: "! Pull request acme/finq.api#2442 (QDLY-1: Fix it) is already open")
        defer { open.remove() }
        check(GitHubActionRunner.perform(request(.reopen), cli: open.cli) == .failure(.alreadyOpen), "and an already open one")
        check(GitHubActionRunner.perform(request(.close), cli: nil) == .failure(.cliMissing), "no gh")
        check(GitHubActionRunner.perform(request(.close), cli: URL(fileURLWithPath: "/nonexistent/gh")) == .failure(.cliMissing), "gh that cannot start")
    }),

    ("a failed action is never retried", {
        let fake = try FakeGH(exit: 1, stderr: "HTTP 502: Bad Gateway")
        defer { fake.remove() }
        _ = GitHubActionRunner.perform(request(.approve), cli: fake.cli)
        check(fake.calls == 1, "one call, not a second try: \(fake.calls)")
    }),

    ("a batch goes one at a time, keeps failures and stops on the ones that would repeat", {
        let requests = (1...5).map { request(.close, pr($0, title: "Bump \($0)")) }
        var seen: [Int] = [], pauses = 0, reported: [(Int, GitHubBulk.Outcome)] = []
        let outcomes = GitHubBulk.run(requests, pause: { pauses += 1 }, perform: { ask in
            seen.append(ask.number)
            switch ask.number {
            case 2: return .failure(.alreadyClosed)
            case 4: return .failure(.branchProtection("protected"))
            default: return .success("")
            }
        }, report: { reported.append(($0, $1)) })
        check(seen == [1, 2, 3, 4, 5], "in order, every one tried: \(seen)")
        check(outcomes == [.done, .failed(.alreadyClosed), .done, .failed(.branchProtection("protected")), .done], "partial failures kept")
        check(pauses == 4, "a pause between the runs, none before the first: \(pauses)")
        check(reported.map(\.0) == [0, 1, 2, 3, 4], "each result reported as it happens")
        check(GitHubBulk.summary(.close, outcomes) == "Closed 3 of 5 pull requests \u{00B7} 2 failed", GitHubBulk.summary(.close, outcomes))

        var tried: [Int] = []
        let halted = GitHubBulk.run(requests, perform: { ask in
            tried.append(ask.number)
            return ask.number == 2 ? .failure(.notLoggedIn) : .success("")
        })
        check(tried == [1, 2], "signed out ends the batch: \(tried)")
        check(halted[2] == .skipped("Not tried after the error above") && halted[4] == .skipped("Not tried after the error above"), "the rest is skipped")
        check(GitHubBulk.summary(.close, halted) == "Closed 1 of 5 pull requests \u{00B7} 1 failed \u{00B7} 3 not tried", GitHubBulk.summary(.close, halted))

        var count = 0
        let stopped = GitHubBulk.run(requests, stop: { count >= 2 }, perform: { _ in count += 1; return .success("") })
        check(stopped == [.done, .done, .skipped("Stopped"), .skipped("Stopped"), .skipped("Stopped")], "stop after the current one")
        for error in [GitHubActionError.rateLimited, .offline, .missingScope, .cliMissing] { check(error.stopsABatch, "\(error) stops a batch") }
        for error in [GitHubActionError.alreadyClosed, .sso, .ownPullRequest, .failed("x")] { check(!error.stopsABatch, "\(error) does not") }
        check(GitHubBulk.run([], perform: { _ in .success("") }).isEmpty, "nothing to do")
    }),

    ("every action is written to the audit log, newest first, and can be cleared", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore.open(at: directory.appendingPathComponent("meetings.sqlite"))
        check(try store.githubActions().isEmpty, "empty at first")
        let start = Date(timeIntervalSince1970: 1_792_300_000)
        let closeRequest = request(.close, pr(7, title: "Bump \u{00E5}"), comment: "Stale")
        let id1 = try store.saveGitHubAction(GitHubActionRecord(at: start, request: closeRequest, succeeded: true))
        let id2 = try store.saveGitHubAction(GitHubActionRecord(at: start.addingTimeInterval(5), request: request(.approve), succeeded: false, error: "GitHub does not let you review your own pull request."))
        check(id2 > id1, "ids grow")
        let rows = try store.githubActions()
        check(rows.map(\.id) == [id2, id1], "newest first")
        check(rows[1].action == .close && rows[1].repo == "acme/finq.api" && rows[1].number == 7 && rows[1].title == "Bump \u{00E5}", "fields round trip")
        check(rows[1].command == "gh pr close 7 --repo acme/finq.api --comment Stale" && rows[1].succeeded && rows[1].error == nil, "command and result")
        check(rows[0].action == .approve && !rows[0].succeeded && rows[0].error?.contains("own pull request") == true, "failure keeps its error")
        check(rows[1].at == start, "time round trips")
        for index in 0..<60 { _ = try store.saveGitHubAction(GitHubActionRecord(at: start.addingTimeInterval(Double(index)), request: request(.comment, comment: "x"), succeeded: true)) }
        check(try store.githubActions().count == GitHubActions.recentLimit, "the last 50")
        try store.clearGitHubActions()
        check(try store.githubActions().isEmpty, "cleared")
    }),

    ("only recent closes that are still closed can be reopened from the log", {
        let now = Date(timeIntervalSince1970: 1_792_400_000)
        func record(_ id: Int64, _ action: GitHubAction, number: Int, ago: TimeInterval, ok: Bool = true) -> GitHubActionRecord {
            GitHubActionRecord(id: id, at: now.addingTimeInterval(-ago), request: request(action, pr(number)), succeeded: ok)
        }
        let records = [record(1, .close, number: 1, ago: 60), record(2, .close, number: 2, ago: 200_000), record(3, .close, number: 3, ago: 100, ok: false),
                       record(4, .approve, number: 4, ago: 10), record(5, .close, number: 5, ago: 500), record(6, .reopen, number: 5, ago: 100),
                       record(7, .close, number: 8, ago: 700), record(8, .reopen, number: 8, ago: 900, ok: true)]
        check(GitHubActionRecord.reopenable(records, now: now) == [1, 7], "\(GitHubActionRecord.reopenable(records, now: now))")
    }),

    ("the master switch is off by default and the explanation is shown once", {
        let defaults = UserDefaults(suiteName: "ghactions-\(UUID().uuidString)")!
        check(!GitHubActions.isEnabled(defaults), "off by default")
        check(!GitHubActions.isExplained(defaults), "not explained yet")
        GitHubActions.setEnabled(true, defaults)
        check(GitHubActions.isEnabled(defaults), "on when turned on")
        GitHubActions.setEnabled(false, defaults)
        check(!GitHubActions.isEnabled(defaults), "and off again")
        GitHubActions.setExplained(defaults)
        check(GitHubActions.isExplained(defaults), "explained")
        check(GitHubActions.settingNote == "Runs gh on your behalf. Every action, merging included, asks you to confirm first.", "the note")
        check(GitHubActions.disabledHelp.contains("Settings"), "the tooltip says where to turn it on")
    }),

    ("the list shows the actions only while they are allowed", {
        check(!GitHubActions.listShowsActions(enabled: false) && GitHubActions.listShowsActions(enabled: true), "hidden when off")
    }),

    ("the result texts say what happened and whether it can be undone", {
        check(GitHubActions.successText(request(.approve, pr(2442, repo: "acme/finq.api"))) == "Approved finq.api #2442 \u{00B7} Undo isn't possible \u{2014} it can be dismissed on GitHub", "approved")
        check(GitHubActions.successText(request(.close)) == "Closed finq.api #2442", "closed")
        check(GitHubActions.successText(request(.reopen)) == "Reopened finq.api #2442", "reopened")
        check(GitHubActions.successText(request(.requestChanges)).hasSuffix("dismissed on GitHub"), "changes requested")
        check(GitHubActions.failureText(request(.approve), .ownPullRequest) == "Could not approve finq.api #2442. GitHub does not let you review your own pull request.", "failure")
    }),

    ("a closed or reviewed pull request shows its new state before GitHub's search does", {
        let open = pr(1), other = pr(2)
        let now = Date(timeIntervalSince1970: 1_792_400_000)
        check(GitHubActions.patch(for: .comment, now: now) == nil, "a comment changes nothing")
        let closed = GitHubActions.patch(for: .close, now: now)!
        check(GitHubActions.apply(closed, to: open).state == .closed && GitHubActions.apply(closed, to: open).review == open.review, "close")
        check(GitHubActions.apply(GitHubActions.patch(for: .approve, now: now)!, to: open).review == .approved, "approve")
        check(GitHubActions.apply(GitHubActions.patch(for: .reopen, now: now)!, to: pr(1, state: .closed)).state == .open, "reopen")
        let fetched: [GitHubKind: [GitHubPR]] = [.created: [open, other], .reviewRequested: [open]]
        let laid = GitHubActions.overlay(fetched, [open.url: closed], now: now.addingTimeInterval(10))
        check(laid[.created]?[0].state == .closed && laid[.created]?[1].state == .open && laid[.reviewRequested]?[0].state == .closed, "laid over every tab")
        check(GitHubActions.overlay(fetched, [open.url: closed], now: now.addingTimeInterval(500)) == fetched, "it lapses")
        let approved = GitHubActions.patch(for: .approve, now: now)!
        check(GitHubActions.overlay(fetched, [open.url: approved], now: now) == fetched, "a review decision is not held over a fetch")
    }),

    ("rows are marked with command and shift and acted on together", {
        let rows = (1...6).map { pr($0) }
        let urls = rows.map(\.url)
        check(GitHubActions.toggled(urls[2], in: [], selected: urls[0]) == [urls[0], urls[2]], "command-click starts from the selected row")
        check(GitHubActions.toggled(urls[2], in: [urls[0], urls[2]], selected: urls[0]) == [urls[0]], "and removes")
        check(GitHubActions.toggled(urls[0], in: [], selected: urls[0]).isEmpty, "the selected row alone is nothing")
        check(GitHubActions.marked(through: urls[3], from: urls[1], in: rows, adding: []) == Set(urls[1...3]), "shift-click down")
        check(GitHubActions.marked(through: urls[0], from: urls[2], in: rows, adding: [urls[5]]) == Set(urls[0...2]).union([urls[5]]), "shift-click up keeps the rest")
        check(GitHubActions.marked(through: urls[4], from: nil, in: rows, adding: []) == [urls[4]], "no anchor marks the one")
        check(GitHubActions.pruned(Set(urls), in: Array(rows.prefix(2))) == Set(urls.prefix(2)), "rows that left the list are unmarked")
        check(GitHubActions.targets(for: rows[1], marked: [urls[1], urls[3]], in: rows).map(\.number) == [2, 4], "the marked rows, in list order")
        check(GitHubActions.targets(for: rows[0], marked: [urls[1], urls[3]], in: rows).map(\.number) == [1], "an unmarked row acts alone")
        check(GitHubActions.targets(for: rows[1], marked: [urls[1]], in: rows).map(\.number) == [2], "one marked row is just that row")
    }),

    ("the headless Claude run still blocks every way of writing to GitHub", {
        let denied = GitHubClaude.deniedTools, allowed = GitHubClaude.readOnlyTools
        for write in ["gh pr review", "gh pr close", "gh pr merge", "gh pr comment", "gh pr reopen", "gh pr edit", "gh api", "gh issue", "gh pr create"] {
            check(denied.contains("Bash(\(write):*)"), "\(write) is denied")
            check(!allowed.contains { $0.contains(write) }, "\(write) is not allowed")
        }
        let arguments = GitHubClaude.headlessArguments(prompt: "p", model: nil)
        check(arguments.contains("--permission-mode") && arguments.contains("dontAsk"), "anything not allowed is refused")
        for entry in allowed where entry.hasPrefix("Bash(gh") {
            check(["Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)", "Bash(gh pr list:*)", "Bash(gh run view:*)", "Bash(gh run list:*)"].contains(entry), "\(entry) reads")
        }
        check(GitHubClaude.safetyRules.contains("approve") && GitHubClaude.safetyRules.contains("Do not post"), "the prompt says so too")
    }),

    ("no tool list of the MCP server, the chat or the phone has a way to write", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore.open(at: directory.appendingPathComponent("meetings.sqlite"))
        let scopes: [ChatScope] = [.general, .meeting(1, label: nil), .notes(1, label: nil), .block(1, from: Date(), to: Date(), label: nil)]
        let tools = MCPServer.meetingTools(.success(store)) + MCPServer.githubTools(.success(store)) + scopes.flatMap { ChatToolbox.tools(for: $0, store: store, budget: ChatBudget(contextSize: 4096)) }
        check(!tools.isEmpty, "there are tools")
        let verbs = ["approve", "close", "reopen", "review", "merge", "comment", "create", "update", "delete", "post", "send", "write", "push", "set_", "edit", "gh_"]
        for tool in tools {
            let lowered = tool.name.lowercased()
            check(!verbs.contains { lowered.contains($0) }, "\(tool.name) does not sound like a write")
            check((tool.listing["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true, "\(tool.name) is marked read-only")
        }
    }),

    ("nothing outside the GitHub views and models can reach the code that writes", {
        let all = try sources()
        check(all.count > 50, "the sources were found: \(all.count)")
        let writing = ["\"--approve\"", "\"--request-changes\"", "\"--delete-branch\"", "\"pr\", \"review\"", "\"pr\", \"close\"", "\"pr\", \"reopen\"",
                       "\"pr\", \"merge\"", "\"--squash\"", "\"--merge\"", "\"--rebase\"", "\"--auto\"", "\"--admin\""]
        for (name, text) in all {
            for needle in writing where text.contains(needle) { check(name == "GitHubActions.swift", "\(needle) appears in \(name)") }
        }
        let runner = all.filter { $0.value.contains("GitHubActionRunner") }.map(\.key).sorted()
        check(runner == ["GitHubActions.swift", "GitHubActionsModel.swift"], "the runner is used by the model only: \(runner)")
        let model = all.filter { $0.value.contains("GitHubActionsModel") }.map(\.key).sorted()
        let allowed = ["GitHubActionsModel.swift", "GitHubActionsView.swift", "GitHubDetailModel.swift", "GitHubDetailView.swift", "GitHubModel.swift", "GitHubPreview.swift", "GitHubView.swift"]
        check(model.allSatisfy(allowed.contains), "the model is used by the GitHub pages only: \(model)")
        let elsewhere = ["ChatToolbox.swift", "ChatEngine.swift", "ChatCommandLine.swift", "ChatModel.swift", "ChatEntryPoints.swift", "MCPServer.swift", "MeetingRecorderApp.swift",
                         "Notifier.swift", "GlobalHotKey.swift", "GitHubClaude.swift", "GitHubClaudeModel.swift", "GitHubClaudeView.swift", "ClaudeProcess.swift",
                         "PhoneEndpoints.swift", "PhoneServer.swift", "PhoneChat.swift", "PhoneClient.swift", "PhoneCommandLine.swift", "PhoneListener.swift",
                         "PhoneSession.swift", "PhoneHTTP.swift", "EmbeddedTerminal.swift", "EmbeddedTerminalModel.swift", "EmbeddedTerminalView.swift",
                         "EmbeddedTerminalCheck.swift", "MainWindow.swift"]
        for name in elsewhere {
            guard let text = all[name] else { check(false, "\(name) exists"); continue }
            check(!text.contains("GitHubAction"), "\(name) must not know about the actions")
        }
        let terminals = all.filter { $0.key.hasPrefix("EmbeddedTerminal") || $0.key.hasPrefix("Phone") || $0.key.hasPrefix("Chat") }
        for (name, text) in terminals { check(!text.contains("GitHubClient.run("), "\(name) must not run gh") }
        let plist = try String(contentsOf: sourceFolder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist"), encoding: .utf8)
        check(!plist.contains("CFBundleURLTypes"), "no URL scheme that a link could use")
        check(all.values.allSatisfy { !$0.contains("onOpenURL") && !$0.contains("handleGetURLEvent") }, "no deep link handler")
    }),

    ("merge runs gh pr merge with one flag for the method, never auto-merge or an admin bypass", {
        for method in GitHubMergeMethod.allCases {
            var ask = request(.merge)
            ask.method = method
            check(GitHubActions.arguments(ask) == ["pr", "merge", "2442", "--repo", "acme/finq.api", method.flag], "\(method) without options")
        }
        var full = request(.merge, comment: "Thanks, \u{00E5}\u{00E4}\u{00F6}", deleteBranch: true)
        full.method = .rebase
        check(GitHubActions.arguments(full) == ["pr", "merge", "2442", "--repo", "acme/finq.api", "--rebase", "--delete-branch", "--body", "Thanks, \u{00E5}\u{00E4}\u{00F6}"], "all options")
        check(GitHubActions.commandLine(full) == "gh pr merge 2442 --repo acme/finq.api --rebase --delete-branch --body 'Thanks, \u{00E5}\u{00E4}\u{00F6}'", "the command line")
        check(!GitHubActions.arguments(request(.merge, comment: "  ")).contains("--body"), "a blank body is not sent")
        check(!GitHubActions.arguments(request(.merge)).contains("--delete-branch"), "the branch stays by default")
        for action in GitHubAction.allCases {
            check(!GitHubActions.arguments(request(action, comment: "x", deleteBranch: true)).contains { $0 == "--auto" || $0 == "--admin" }, "\(action) has no auto or admin")
        }
    }),

    ("the merge method is the first one the repository allows, and only allowed ones are offered", {
        check(GitHubMergeMethod.allowed(squash: true, merge: true, rebase: true) == [.squash, .merge, .rebase], "all allowed in order")
        check(GitHubMergeMethod.allowed(squash: false, merge: true, rebase: nil) == [.merge], "unknown and disabled are not offered")
        check(GitHubMergeMethod.allowed(squash: nil, merge: nil, rebase: nil).isEmpty, "nothing known")
        check(GitHubMergeMethod.choose(.squash, from: [.merge, .rebase]) == .merge, "squash not allowed falls to merge")
        check(GitHubMergeMethod.choose(.rebase, from: [.squash, .rebase]) == .rebase, "a choice that is allowed stays")
        check(GitHubMergeMethod.choose(.squash, from: []) == .squash, "nothing allowed keeps the choice")
    }),

    ("merge is refused when merged, closed, drafted, conflicting, unknown, or the method is not allowed", {
        func ready(_ change: (inout GitHubActionTarget) -> Void = { _ in }) -> GitHubActionTarget {
            var t = target()
            t.mergeable = .mergeable
            t.mergeMethods = [.squash, .merge, .rebase]
            t.mergeState = .clean
            t.base = "develop"
            change(&t)
            return t
        }
        check(!isBlocked(GitHubActions.preflight(request(.merge), ready())), "a ready pull request")
        check(isBlocked(GitHubActions.preflight(request(.merge), ready { $0.state = .merged })), "merged")
        check(isBlocked(GitHubActions.preflight(request(.merge), ready { $0.state = .closed })), "closed")
        check(isBlocked(GitHubActions.preflight(request(.merge), ready { $0.isDraft = true })), "draft")
        check(isBlocked(GitHubActions.preflight(request(.merge), ready { $0.mergeable = .conflicting })), "conflicts")
        check(isBlocked(GitHubActions.preflight(request(.merge), ready { $0.mergeable = .unknown })), "mergeable not known after the refresh")
        check(isBlocked(GitHubActions.preflight(request(.merge), ready { $0.mergeMethods = [] })), "no methods known")
        var rebase = request(.merge)
        rebase.method = .rebase
        check(isBlocked(GitHubActions.preflight(rebase, ready { $0.mergeMethods = [.squash, .merge] })), "rebase not allowed")
        check(!isBlocked(GitHubActions.preflight(request(.merge), ready { $0.author = "niklas"; $0.viewer = "Niklas" })), "your own pull request can be merged")
    }),

    ("failing, running and blocked checks warn, and stay allowed after confirmation", {
        func ready(_ change: (inout GitHubActionTarget) -> Void) -> GitHubActionTarget {
            var t = target()
            t.mergeable = .mergeable
            t.mergeMethods = [.squash]
            change(&t)
            return t
        }
        check(warnings(GitHubActions.preflight(request(.merge), ready { _ in })).isEmpty, "clean has no warning")
        check(warnings(GitHubActions.preflight(request(.merge), ready { $0.checks = .failed })) == [GitHubActions.checksFailing], "failing")
        check(warnings(GitHubActions.preflight(request(.merge), ready { $0.checks = .running })) == ["Checks are still running"], "running")
        check(warnings(GitHubActions.preflight(request(.merge), ready { $0.mergeState = .blocked })).count == 1, "blocked by protection")
        check(warnings(GitHubActions.preflight(request(.merge), ready { $0.mergeState = .unstable })) == ["Some checks are not passing."], "unstable")
        let failing = GitHubActions.confirmation(for: request(.merge), target: ready { $0.checks = .failed })
        check(failing.canConfirm && failing.warnings.contains { $0.text == GitHubActions.checksFailing && $0.tone == .bad }, "red line, still confirmable")
    }),

    ("the merge sheet shows the base, conflicts, review requirement, the command, and no Return default", {
        var t = target()
        t.mergeable = .mergeable
        t.mergeMethods = [.squash, .merge]
        t.base = "develop"
        t.head = "NI/QDLY-1"
        t.review = .required
        t.checks = .passed
        let c = GitHubActions.confirmation(for: request(.merge), target: t)
        check(c.confirmTitle == "Merge pull request" && !c.confirmIsDefault && c.canConfirm, "merge needs a click")
        check(c.facts.contains { $0.label == "Base" && $0.value == "develop" }, "base")
        check(c.facts.contains { $0.label == "Conflicts" && $0.value == "No conflicts" && $0.tone == .good }, "conflicts")
        check(c.facts.contains { $0.label == "Review" && $0.value == "Review required" && $0.tone == .warning }, "the requirement")
        check(c.offersBranchDelete && c.commentLabel == "Commit body (optional)", "branch and body")
        check(c.mergeMethods == [.squash, .merge], "the methods offered")
        check(c.command == "gh pr merge 2442 --repo acme/finq.api --squash", "the command: \(c.command)")
        var conflicting = t
        conflicting.mergeable = .conflicting
        let blocked = GitHubActions.confirmation(for: request(.merge), target: conflicting)
        check(!blocked.canConfirm && blocked.blocker?.contains("conflicts") == true, "conflicts hold confirm back")
        check(!GitHubActions.confirmation(for: request(.merge), target: { var d = t; d.state = .merged; return d }()).canConfirm, "merged holds it back")
    }),

    ("merge errors from gh are classified, and a conflict is not mistaken for protection", {
        let fixtures: [(String, GitHubActionError)] = [
            ("GraphQL: Pull request is not mergeable: the merge commit cannot be cleanly created", .conflicts),
            ("Pull request acme/api#7 has merge conflicts", .conflicts),
            ("GraphQL: Squash merges are not allowed on this repository.", .methodNotAllowed),
            ("GraphQL: Merge commits are not allowed on this repository.", .methodNotAllowed),
            ("GraphQL: Rebase merges are not allowed on this repository.", .methodNotAllowed),
            ("GraphQL: Pull request is not mergeable: 2 of 2 required status checks are expected", .branchProtection("GraphQL: Pull request is not mergeable: 2 of 2 required status checks are expected")),
            ("GraphQL: Pull request is not mergeable", .branchProtection("GraphQL: Pull request is not mergeable")),
            ("GraphQL: Pull request is already merged", .alreadyClosed),
        ]
        for (stderr, expected) in fixtures { check(GitHubActionError.classify(stderr) == expected, "\(stderr) -> \(GitHubActionError.classify(stderr))") }
        check(GitHubActionError.conflicts.message.contains("conflicts") && GitHubActionError.methodNotAllowed.message.contains("merge method"), "messages")
    }),

    ("a fake gh merge runs once with the exact arguments, whatever gh answers", {
        let merged = "\u{2713} Merged pull request acme/finq.api#2442"
        let cases: [(Int32, String, String, GitHubActionError?)] = [
            (0, merged, "", nil),
            (1, "", "GraphQL: Pull request is not mergeable: the merge commit cannot be cleanly created", .conflicts),
            (1, "", "GraphQL: Pull request is not mergeable: the base branch policy prohibits the merge", .branchProtection("GraphQL: Pull request is not mergeable: the base branch policy prohibits the merge")),
            (1, "", "GraphQL: Squash merges are not allowed on this repository.", .methodNotAllowed),
            (1, "", "HTTP 403: Resource protected by organization SAML enforcement.", .sso),
            (1, "", "HTTP 403: API rate limit exceeded for user ID 1", .rateLimited),
        ]
        for (status, stdout, stderr, expected) in cases {
            let fake = try FakeGH(exit: status, stdout: stdout, stderr: stderr)
            defer { fake.remove() }
            var ask = request(.merge, comment: "Ship it")
            ask.method = .squash
            let result = GitHubActionRunner.perform(ask, cli: fake.cli)
            check(fake.calls == 1, "gh ran once: \(fake.calls)")
            check(fake.arguments == GitHubActions.arguments(ask), "the arguments are the command's: \(fake.arguments)")
            check(!fake.arguments.contains("--auto") && !fake.arguments.contains("--admin"), "no auto-merge, no admin bypass")
            if let expected { check(result == .failure(expected), "\(stderr) -> \(result)") } else { check(result == .success(merged), "success: \(result)") }
        }
    }),

    ("a merge shows as merged before GitHub's search does, and the audit log keeps it", {
        let now = Date(timeIntervalSince1970: 1_792_400_000)
        let open = pr(1)
        let patch = GitHubActions.patch(for: .merge, now: now)!
        check(patch.state == .merged && patch.review == nil, "merged, no review change")
        check(GitHubActions.apply(patch, to: open).state == .merged, "applied")
        let fetched: [GitHubKind: [GitHubPR]] = [.created: [open]]
        check(GitHubActions.overlay(fetched, [open.url: patch], now: now.addingTimeInterval(10))[.created]?[0].state == .merged, "held over the fetch")
        check(GitHubActions.overlay(fetched, [open.url: patch], now: now.addingTimeInterval(500)) == fetched, "and it lapses")
        check(GitHubActions.successText(request(.merge)) == "Merged finq.api #2442 \u{00B7} GitHub can't undo a merge; you can revert it with a new PR", "the result text")
        check(GitHubActions.failureText(request(.merge), .conflicts) == "Could not merge finq.api #2442. The branch has merge conflicts. Resolve them on the branch, then try again.", "the failure text")

        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore.open(at: directory.appendingPathComponent("meetings.sqlite"))
        var ask = request(.merge, comment: "Thanks")
        ask.method = .merge
        _ = try store.saveGitHubAction(GitHubActionRecord(at: now, request: ask, succeeded: true))
        _ = try store.saveGitHubAction(GitHubActionRecord(at: now, request: request(.merge), succeeded: false, error: "The branch has merge conflicts."))
        let rows = try store.githubActions()
        check(rows.count == 2 && rows[1].action == .merge && rows[1].command == "gh pr merge 2442 --repo acme/finq.api --merge --body Thanks", "the audit row: \(rows.map(\.command))")
        check(rows[1].succeeded && !rows[0].succeeded, "results kept")
        check(GitHubActionRecord.reopenable(rows, now: now).isEmpty, "a merge cannot be reopened from the log")
    }),
]
