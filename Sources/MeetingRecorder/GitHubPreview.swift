#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `MeetingRecorder --render-github <folder>` saves PNGs of the GitHub page with sample pull requests,
/// its empty and error states and its settings, from a scratch database in the folder.
enum GitHubPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-github"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let database = output.appendingPathComponent("github.sqlite")
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: database.path + $0) }
        guard let store = try? MeetingStore.open(at: database) else { exit(1) }
        let model = GitHubModel.shared
        model.store = store
        let library = RecordingLibrary(store: store, folder: output.appendingPathComponent("empty", isDirectory: true))
        library.showsGitHub = true
        let window = MainWindow.makeWindow(MainView(recorder: Recorder(), processor: MeetingProcessor(notifier: nil, store: store), library: library,
                                                    activity: ActivityModel(store: store, tracker: ActivityTracker(store: store)),
                                                    playback: AudioPlayback()))
        window.setContentSize(NSSize(width: 1040, height: 760))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        var directory = TicketDirectory()
        directory.sites["QDLY"] = "quiddly.atlassian.net"
        if CommandLine.arguments.contains("--terminal-check") {
            Task { @MainActor in
                await TerminalCheck.run(window: window, model: model, directory: directory, output: output)
                exit(0)
            }
            NSApplication.shared.run()
            exit(0)
        }
        Task { @MainActor in
            @MainActor func shot(_ name: String, appearances: [NSAppearance.Name] = [.aqua, .darkAqua]) async {
                for appearance in appearances {
                    window.appearance = NSAppearance(named: appearance)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    PreviewRenderer.save(window, to: output.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
            model.showSample(prs: samples, directory: directory)
            await shot("created")
            model.filter.sort = .needsAttention
            await shot("needs-attention")
            model.filter.sort = .mostDiscussed
            await shot("most-discussed", appearances: [.aqua])
            model.filter = GitHubLogic.Filter(quick: [.newFeedback], hideBotOnly: true, sort: .needsAttention)
            await shot("quick-filters", appearances: [.aqua])
            model.filter = GitHubLogic.Filter(quick: [.unresolved], sort: .unresolved)
            await shot("unresolved-first", appearances: [.aqua])
            model.filter = GitHubLogic.Filter()
            model.kind = .reviewRequested
            model.filter.sort = .needsAttention
            await shot("review-requested", appearances: [.aqua])
            model.filter = GitHubLogic.Filter()
            model.kind = .created
            model.filter.state = .all
            await shot("all-states", appearances: [.aqua])
            model.filter = GitHubLogic.Filter(state: .open, repo: "acme/finq.api", query: "zzz")
            await shot("no-match", appearances: [.aqua])
            let sample = detailSamples[0]
            let selected = samples[.created]?[1]
            model.showSample(prs: samples, directory: directory)
            model.showSample(selecting: selected, detail: sample.detail)
            await shot("split-selected")
            model.filter = GitHubLogic.Filter(state: .all, repo: "acme/finq.api", quick: [.unresolved], hideBotOnly: true, sort: .needsAttention)
            await shot("split-many-filters", appearances: [.aqua])
            model.filter = GitHubLogic.Filter()
            window.setContentSize(NSSize(width: 800, height: 700))
            await shot("narrow-window")
            window.setContentSize(NSSize(width: 1040, height: 760))
            model.showSample(prs: samples, directory: directory, error: .rateLimited)
            await shot("error-with-cache", appearances: [.aqua])
            model.showSample(prs: [:], error: .cliMissing, fetched: nil)
            await shot("gh-missing")
            model.showSample(prs: [:], error: .notLoggedIn, fetched: nil)
            await shot("not-logged-in")
            model.showSample(prs: [:], error: .sso("Authorize the token for acme."), fetched: nil)
            await shot("sso", appearances: [.aqua])
            model.showSample(enabled: false, prs: [:], fetched: nil)
            await shot("off")
            model.showSample(prs: [:], fetched: nil)
            await shot("empty", appearances: [.aqua])
            model.showSample(prs: samples, directory: directory)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                await renderSettings(model, appearance: appearance, to: output.appendingPathComponent("settings-\(appearance == .aqua ? "light" : "dark").png"))
            }
            for sample in detailSamples {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    await renderDetail(sample, directory: directory, appearance: appearance,
                                       to: output.appendingPathComponent("detail-\(sample.name)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
            let claudeSample = detailSamples[0]
            let url = claudeSample.pr.url
            let review = GitHubReview(url: url, headSHA: "e4748c4", preset: .review, text: "**Verdict: approve.** No blockers.\n\n## Findings\n\n1. **Low.** The guard skips the log line (`sending.py:41`).\n2. **Low.** The migration has no downgrade.",
                                      created: Date().addingTimeInterval(-600), duration: 149, cost: 1.15)
            let states: [(String, [String: GitHubClaudeModel.State], [String: GitHubReview], [String: Bool])] = [
                ("notrun", [:], [:], [:]),
                ("running", [url: .running(.init(preset: .review, started: Date().addingTimeInterval(-42), text: "Reading the diff.\n\nThe guard in `order_to_pay` looks right.", status: "Bash gh pr diff 2462"))], [:], [:]),
                ("done", [:], [url: review], [:]),
                ("outdated", [:], [url: review], [url: true]),
                ("failed", [url: .failed(.notLoggedIn, .review)], [:], [:]),
            ]
            for (name, live, reviews, outdated) in states {
                GitHubClaudeModel.shared.showSample(live: live, reviews: reviews, outdated: outdated)
                await renderDetail(claudeSample, directory: directory, appearance: .aqua, to: output.appendingPathComponent("claude-\(name).png"))
            }
            await renderSettings(model, appearance: .darkAqua, to: output.appendingPathComponent("claude-settings-dark.png"))
            let commentPR = detailSamples[0].pr
            let sampleComments = commentSamples
            let commentStates: [(String, GitHubComments, GitHubCommentsFilter, Set<String>)] = [
                ("unresolved", sampleComments, GitHubCommentsFilter(scope: .unresolved), []),
                ("all", sampleComments, GitHubCommentsFilter(scope: .all), ["T2"]),
                ("mine", sampleComments, GitHubCommentsFilter(scope: .mine), []),
                ("hide-bots", sampleComments, GitHubCommentsFilter(scope: .all, hideBots: true), []),
                ("search", sampleComments, GitHubCommentsFilter(scope: .all, query: "guard"), []),
                ("bot-full", sampleComments, GitHubCommentsFilter(scope: .all), ["T2", "B1"]),
                ("empty", GitHubComments(), GitHubCommentsFilter(), []),
            ]
            for (name, comments, filter, expanded) in commentStates {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    await render(GitHubCommentsSection(model: GitHubCommentsModel(pr: commentPR, sample: comments, filter: filter, expanded: expanded), lazy: false),
                                 appearance: appearance, to: output.appendingPathComponent("comments-\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
            await render(GitHubDetailContent(pr: commentPR, detail: detailSamples[0].detail,
                                             comments: GitHubCommentsModel(pr: commentPR, sample: sampleComments, filter: GitHubCommentsFilter(scope: .unresolved)),
                                             directory: directory, ask: {}, lazyComments: false),
                         appearance: .aqua, to: output.appendingPathComponent("comments-page-light.png"))
            await renderActions(model: model, window: window, directory: directory, shot: shot, output: output)
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    @MainActor
    private static func renderSettings(_ model: GitHubModel, appearance: NSAppearance.Name, to url: URL) async {
        let controller = NSHostingController(rootView: GitHubSettingsSection(model: model).padding(24).frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }

    @MainActor
    private static func renderDetail(_ sample: (name: String, pr: GitHubPR, detail: GitHubPRDetail), directory: TicketDirectory,
                                     appearance: NSAppearance.Name, to url: URL) async {
        await render(GitHubDetailContent(pr: sample.pr, detail: sample.detail, comments: GitHubCommentsModel(pr: sample.pr, sample: nil), directory: directory, ask: {}),
                     appearance: appearance, to: url)
    }

    @MainActor
    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) async {
        let content = view.padding(32).frame(width: 840, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }

    @MainActor
    private static func renderActions(model: GitHubModel, window: NSWindow, directory: TicketDirectory,
                                      shot: (String, [NSAppearance.Name]) async -> Void, output: URL) async {
        let actions = GitHubActionsModel.shared
        let folder = output.deletingLastPathComponent().appendingPathComponent("ghactions-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let both: [NSAppearance.Name] = [.aqua, .darkAqua]
        func name(_ base: String, _ appearance: NSAppearance.Name) -> URL {
            folder.appendingPathComponent("\(base)-\(appearance == .aqua ? "light" : "dark").png")
        }
        let failing = samples[.reviewRequested]![1]
        let approve = GitHubActionDraft(request: GitHubActionRequest(.approve, pr: failing).with(comment: "Looks right to me, thanks for the quick fix.", deleteBranch: false),
                                        pr: failing, target: GitHubActionTarget(pr: failing))
        let closing = samples[.created]![0]
        var closeTarget = GitHubActionTarget(pr: closing)
        closeTarget.head = "NI/QDLY-8315-strawbay-send-guard"
        closeTarget.base = "develop"
        let close = GitHubActionDraft(request: GitHubActionRequest(.close, pr: closing).with(comment: "Superseded by the new batch sender.", deleteBranch: true),
                                      pr: closing, target: closeTarget)
        let own = samples[.created]![1]
        let blocked = GitHubActionDraft(request: GitHubActionRequest(.approve, pr: own), pr: own, target: GitHubActionTarget(pr: own))
        let checking = GitHubActionDraft(request: GitHubActionRequest(.approve, pr: failing), pr: failing, target: GitHubActionTarget(pr: failing), checking: true)
        let sheets: [(String, AnyView)] = [
            ("approve-failing-checks", AnyView(ActionConfirmSheet(draft: approve, confirm: {}, cancel: {}))),
            ("close-delete-branch", AnyView(ActionConfirmSheet(draft: close, confirm: {}, cancel: {}))),
            ("approve-own-blocked", AnyView(ActionConfirmSheet(draft: blocked, confirm: {}, cancel: {}))),
            ("approve-checking", AnyView(ActionConfirmSheet(draft: checking, confirm: {}, cancel: {}))),
            ("explain", AnyView(ActionExplainSheet(continueAction: {}, cancel: {}))),
        ]
        for (base, view) in sheets {
            for appearance in both { await renderSheet(view, appearance: appearance, to: name(base, appearance)) }
        }
        let snyk = stalePRs
        let bulk: [(String, [GitHubBulk.Outcome?], Bool, Bool)] = [
            ("bulk-close", [], false, false),
            ("bulk-close-progress", [.done, .done, nil, nil, nil], true, false),
            ("bulk-close-result", [.done, .done, .failed(.branchProtection("Base branch policy prohibits the merge")), .done, .skipped("Already closed")], false, true),
        ]
        for (base, outcomes, running, finished) in bulk {
            let draft = GitHubBulkDraft(.close, prs: snyk, offersBranchDelete: true)
            draft.showSample(outcomes: outcomes, running: running, finished: finished)
            for appearance in both { await renderSheet(BulkActionSheet(draft: draft, confirm: {}, cancel: {}), appearance: appearance, to: name(base, appearance)) }
        }
        let now = Date()
        func record(_ action: GitHubAction, _ pr: GitHubPR, ago: TimeInterval, error: GitHubActionError? = nil) -> GitHubActionRecord {
            GitHubActionRecord(id: Int64(1_000 - ago), at: now.addingTimeInterval(-ago), request: GitHubActionRequest(action, pr: pr), succeeded: error == nil, error: error?.message)
        }
        let records = [record(.close, snyk[0], ago: 40), record(.close, snyk[1], ago: 45), record(.approve, failing, ago: 900),
                       record(.approve, own, ago: 4_000, error: .ownPullRequest), record(.reopen, samples[.created]![8], ago: 9_000),
                       record(.close, samples[.created]![8], ago: 12_000), record(.comment, failing, ago: 90_000)]
        try? model.store?.clearGitHubActions()
        for record in records.reversed() { _ = try? model.store?.saveGitHubAction(record) }
        actions.showSample(enabled: true, records: records)
        model.showSample(prs: samples, directory: directory)
        for appearance in both { await renderSettings(model, appearance: appearance, to: name("settings-actions", appearance)) }
        actions.showSample(enabled: false)
        await renderSettings(model, appearance: .aqua, to: name("settings-actions-off", .aqua))
        let sample = detailSamples[0]
        for (base, enabled) in [("page-actions", true), ("page-actions-off", false)] {
            actions.showSample(enabled: enabled)
            for appearance in both {
                await renderDetail(sample, directory: directory, appearance: appearance, to: name(base, appearance))
            }
        }
        actions.showSample(enabled: true, banner: .init(text: GitHubActions.successText(GitHubActionRequest(.close, pr: snyk[0])), reopen: [GitHubActionRequest(.reopen, pr: snyk[0])]))
        model.showSample(prs: samples, directory: directory)
        model.showMarked(Set(samples[.created]!.prefix(4).map(\.url)))
        await shot("list-marked", both)
        actions.showSample(enabled: true, banner: .init(text: GitHubActions.successText(GitHubActionRequest(.approve, pr: failing))))
        await shot("banner-approved", [.aqua])
        actions.showSample(enabled: true, banner: .init(text: GitHubActions.failureText(GitHubActionRequest(.approve, pr: own), .ownPullRequest), isError: true,
                                                         details: GitHubActions.commandLine(GitHubActionRequest(.approve, pr: own))))
        await shot("banner-error", [.aqua])
        actions.showSample(enabled: false)
        model.showMarked([])
    }

    @MainActor
    private static func renderSheet(_ view: some View, appearance: NSAppearance.Name, to url: URL) async {
        let controller = NSHostingController(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }

    static var stalePRs: [GitHubPR] {
        let now = Date()
        let bumps = [("cryptography", "45.0.7", "46.0.5"), ("urllib3", "2.2.1", "2.5.0"), ("jinja2", "3.1.4", "3.1.6"), ("requests", "2.31.0", "2.32.4"), ("werkzeug", "3.0.1", "3.0.6")]
        return bumps.enumerated().map { index, bump in
            GitHubPR(url: "https://github.com/niklas/devops/pull/\(180 + index)", number: 180 + index, title: "[Snyk] Security upgrade \(bump.0) from \(bump.1) to \(bump.2)",
                     repo: "niklas/devops", state: .open, updated: now.addingTimeInterval(-Double(index + 3) * 86_400 * 20), checks: .passed, author: "snyk-bot", additions: 1, deletions: 1)
        }
    }

    static var commentSamples: GitHubComments {
        let now = Date()
        func who(_ login: String) -> GitHubActivity.Actor { GitHubActivity.Actor(login: login, isBot: GitHubLogic.isBot(login: login, typename: nil)) }
        func said(_ id: String, _ login: String, _ ago: Double, _ body: String, review: GitHubPRDetail.ReviewState? = nil) -> GitHubComment {
            let parts = GitHubLogic.commentParts(body)
            let author = who(login)
            return GitHubComment(id: id, author: author, body: body, parts: parts, digest: author.isBot ? GitHubLogic.digest(parts, body: body) : nil,
                                 created: now.addingTimeInterval(-ago), url: "https://github.com/acme/finq.api/pull/2462#discussion_\(id)", review: review)
        }
        let guardDiff = GitHubLogic.diffLines("""
            @@ -38,7 +38,12 @@ def order_to_pay(case):
                 case = load(case_id)
                 if case is None:
                     return
            -    send(case)
            +    if not setting("strawbay_send_to_kronofogden"):
            +        return
            +    batch = build_batch(case)
            +    send(batch)
                 log.info("sent")
            """)
        let longBot = """
            <!-- This is an auto-generated comment: summarize by coderabbit.ai -->
            _\u{26A0}\u{FE0F} Potential issue_ | _\u{1F7E0} Major_

            **The guard skips the log line, so a disabled tenant leaves no trace.**

            When the setting is off the function returns before `log.info`, which makes support cases hard to follow.

            <details>
            <summary>\u{1F4DD} Committable suggestion</summary>

            > \u{203C}\u{FE0F} **IMPORTANT**
            > Carefully review the code before committing.

            ```suggestion
            if not setting("strawbay_send_to_kronofogden"):
                log.info("skipped")
                return
            ```

            </details>

            <details>
            <summary>\u{1F916} Prompt for AI Agents</summary>

            ```
            In finq/jobs/enforcement/delivery_api/strawbay/sending.py around lines 41 to 44, log before returning.
            ```

            </details>

            <!-- fingerprinting:phantom:triton:hamster -->
            """
        let threads: [GitHubThread] = [
            GitHubThread(id: "T1", path: "finq/jobs/enforcement/delivery_api/strawbay/sending.py", line: 44, startLine: 41, diff: guardDiff,
                         comments: [said("a1", "sara", 7_200, "Can the guard live in `order_to_pay` instead? Then the batch builder stays pure.\n\n```suggestion\nif not setting(\"strawbay_send_to_kronofogden\"):\n    return\n```"),
                                    said("a2", "niklas", 3_600, "Moved it, thanks. I kept the log line.")], commentCount: 2),
            GitHubThread(id: "T2", path: "finq/jobs/enforcement/delivery_api/strawbay/sending.py", line: 52, isResolved: true, resolvedBy: "sara", diff: guardDiff,
                         comments: [said("b0", "sara", 9_000, "Nit: name this `batch`, not `b`."), said("b1", "niklas", 8_000, "Done.")], commentCount: 2),
            GitHubThread(id: "T3", path: "finq/jobs/enforcement/delivery_api/strawbay/sending.py", line: nil, originalLine: 61, isOutdated: true, diff: guardDiff,
                         comments: [said("c1", "elin", 90_000, "This branch never runs with the new setting, can it go?", review: .changesRequested)], commentCount: 1),
            GitHubThread(id: "T4", path: "finq/api/resources/engine_rule/engine_rule.py", line: 17, diff: guardDiff,
                         comments: [said("B1", "coderabbitai[bot]", 5_000, longBot),
                                    said("d2", "elin", 600, "Agreed with the bot, the guard should log.")], commentCount: 2),
            GitHubThread(id: "T5", path: "README.md", line: nil, isFile: true,
                         comments: [said("e1", "copilot-pull-request-reviewer", 20_000, "The README does not mention the new setting.")], commentCount: 1),
            GitHubThread(id: "T6", path: "db/migrations/versions/5a248b7f1722_setting.py", line: 12, isResolved: true, resolvedBy: "johan", diff: guardDiff,
                         comments: [said("f1", "johan", 40_000, "Please add a downgrade.")], commentCount: 1),
        ]
        let conversation = [
            said("i1", "johan", 80_000, "LGTM once the guard logs.", review: .approved),
            said("i2", "coderabbitai[bot]", 70_000, "## Walkthrough\n\nThe change guards the sending job behind a tenant setting and adds the migration.\n\n<details>\n<summary>Changes</summary>\n\n| File | Summary |\n|---|---|\n| sending.py | Guard |\n\n</details>"),
            said("i3", "niklas", 1_000, "Pushed the fix, ready for another look."),
        ]
        return GitHubComments(me: "niklas", threads: threads, threadTotal: 94, conversation: conversation,
                              cursors: .init(threads: .init(after: "x", more: true)), cost: 1, remaining: 4990)
    }

    static var detailSamples: [(name: String, pr: GitHubPR, detail: GitHubPRDetail)] {
        let now = Date()
        func detail(_ name: String, _ number: Int, _ title: String, state: GitHubPR.State = .open, draft: Bool = false, review: GitHubPR.Review? = nil,
                    mergeable: GitHubPRDetail.Mergeable = .mergeable, body: String, checks: [GitHubPRDetail.Check] = [],
                    reviewers: [GitHubPRDetail.Reviewer] = [], files: Int = 7, fileTotal: Int? = nil, commits: Int = 3) -> (name: String, pr: GitHubPR, detail: GitHubPRDetail) {
            let url = "https://github.com/acme/finq.api/pull/\(number)"
            let list = GitHubPR(url: url, number: number, title: title, repo: "acme/finq.api", isDraft: draft, state: state, updated: now, checks: .passed, author: "niklas")
            let paths = ["finq/api/resources/engine_rule/engine_rule.py", "finq/jobs/enforcement/delivery_api/strawbay/sending.py", "tests/fixtures/setting.yaml",
                         "README.md", "db/migrations/versions/5a248b7f1722_setting.py", "finq/common/constants.py", "docs/old.md"]
            let kinds: [GitHubPRDetail.Change] = [.modified, .added, .modified, .modified, .added, .modified, .removed]
            let rows = (0..<files).map { index -> GitHubPRDetail.File in
                let base = paths[index % paths.count]
                return GitHubPRDetail.File(path: index < paths.count ? base : "finq/module\(index)/" + (base.split(separator: "/").last.map(String.init) ?? base),
                                           additions: (index * 7) % 60, deletions: (index * 3) % 20, change: kinds[index % kinds.count])
            }
            let log = (0..<commits).map { index in
                GitHubPRDetail.Commit(oid: String(format: "%07x%06x", 0xe4748c4 + index * 977, index), headline: ["Only send batches when sending is enabled", "Add the setting and its migration", "Review: rename the guard", "Fix the fixture"][index % 4],
                                      author: index % 3 == 2 ? "elin" : "niklas", date: now.addingTimeInterval(-Double(index) * 5_400 - 3_000), url: url,
                                      checks: index == commits - 1 ? (checks.contains { $0.status == .failed } ? .failed : checks.contains { $0.status == .running } ? .running : .passed) : .passed)
            }
            let full = GitHubPRDetail(url: url, repo: "acme/finq.api", number: number, title: title, body: body, author: "niklas", state: state, isDraft: draft,
                                      mergeable: mergeable, review: review, base: "develop", head: "NI/QDLY-8315-strawbay-send-guard",
                                      created: now.addingTimeInterval(-26_000), updated: now.addingTimeInterval(-900), additions: 452, deletions: 46,
                                      changedFiles: fileTotal ?? files, labels: ["backend", "needs-review"], assignees: ["niklas"], reviewers: reviewers,
                                      commits: log, commitCount: commits, files: rows, fileCount: fileTotal ?? files, checks: checks, checkCount: checks.count,
                                      rollup: checks.contains { $0.status == .failed } ? .failed : checks.contains { $0.status == .running } ? .running : .passed)
            return (name, list, full)
        }
        func check(_ name: String, _ status: GitHubPRDetail.CheckStatus, _ seconds: TimeInterval? = nil, workflow: String = "CI") -> GitHubPRDetail.Check {
            GitHubPRDetail.Check(name: name, workflow: workflow, status: status, started: seconds.map { _ in now.addingTimeInterval(-200) },
                                 completed: seconds.map { now.addingTimeInterval($0 - 200) }, url: "https://github.com/acme/finq.api/actions/runs/1")
        }
        let body = """
            ## Summary
            Only send Strawbay batches to the authority when the **sending** setting is on. See `QDLY-8315` and [the spec](https://example.com/spec).

            - [x] Add the setting and its migration
            - [x] Guard `order_to_pay`
            - [ ] Backfill the tenants that already send
              - ask Elin first

            ```python
            if not setting("strawbay_send_to_kronofogden"):
                return
            ```

            | Tenant | Sending |
            |---|---|
            | Gaia | on |
            | Nebula | off |

            ![Settings page](https://github.com/user-attachments/assets/1)

            1. Merge
            2. Enable per tenant
            """
        let long = body + "\n\n" + (1...14).map { "Detail paragraph \($0) about the migration and how it was verified on the test tenant." }.joined(separator: "\n\n")
        let mixed = [check("e2e / checkout", .failed, 95), check("lint", .passed, 41), check("unit tests (3.12)", .passed, 312), check("build", .running),
                     check("deploy preview", .pending), check("docs", .skipped, 0), check("snyk", .passed, 20, workflow: "Security")]
        let reviewers: [GitHubPRDetail.Reviewer] = [.init(name: "sara", state: .changesRequested), .init(name: "elin", state: .pending),
                                                    .init(name: "backend", isTeam: true, state: .pending), .init(name: "johan", state: .approved),
                                                    .init(name: "copilot-pull-request-reviewer", state: .commented)]
        return [
            detail("open-running", 2462, "QDLY-8315: Only send Strawbay batches to Kronofogden when sending is enabled", review: .required, body: body, checks: mixed, reviewers: reviewers),
            detail("draft-conflicts", 2439, "QDLY-8315: Store the journal number and date", draft: true, mergeable: .conflicting, body: "", checks: [], commits: 1),
            detail("merged", 2385, "QDLY-8782: Define API models explicitly", state: .merged, review: .approved, body: "Short description.", checks: [check("lint", .passed, 40), check("tests", .passed, 300)], reviewers: [.init(name: "johan", state: .approved)]),
            detail("checks-failing", 2460, "QDLY-8785: Recall cases at the authority", review: .changesRequested, body: long, checks: [check("tests", .failed, 280), check("lint", .failed, 12), check("build", .passed, 60), check("e2e", .cancelled, 30)], reviewers: reviewers),
            detail("many-files", 872, "QDLY-8690: Rating conversion table as a grid of tiers", review: .approved, body: body, checks: [check("lint", .passed, 40)], files: 100, fileTotal: 240, commits: 100),
        ]
    }

    static var samples: [GitHubKind: [GitHubPR]] {
        let now = Date()
        func pr(_ number: Int, _ repo: String, _ title: String, ago: TimeInterval, state: GitHubPR.State = .open, draft: Bool = false,
                checks: GitHubPR.Checks = .passed, review: GitHubPR.Review? = nil, add: Int = 40, del: Int = 8, comments: Int = 0,
                author: String = "niklas", activity: GitHubActivity? = nil) -> GitHubPR {
            GitHubPR(url: "https://github.com/\(repo)/pull/\(number)", number: number, title: title, repo: repo, isDraft: draft, state: state,
                     updated: now.addingTimeInterval(-ago), review: review, checks: checks, author: author, additions: add, deletions: del,
                     comments: comments, activity: activity)
        }
        func person(_ login: String) -> GitHubActivity.Actor { GitHubActivity.Actor(login: login) }
        func bot(_ login: String) -> GitHubActivity.Actor { GitHubActivity.Actor(login: login, isBot: true) }
        func said(_ actor: GitHubActivity.Actor, _ ago: TimeInterval) -> GitHubActivity.Event { GitHubActivity.Event(actor: actor, date: now.addingTimeInterval(-ago)) }
        func activity(threads: Int = 0, open: [GitHubActivity.Event] = [], reviews: [GitHubActivity.Review] = [], comment: GitHubActivity.Event? = nil,
                      commit: TimeInterval = 90_000, requested: [String] = [], botAuthor: Bool = false) -> GitHubActivity {
            GitHubActivity(me: "niklas", authorIsBot: botAuthor, threads: threads, open: open, reviews: reviews, reviewCount: reviews.count, lastComment: comment,
                           lastCommit: now.addingTimeInterval(-commit), requested: requested)
        }
        return [
            .created: [
                pr(2462, "acme/finq.api", "QDLY-8786: Send enforcement cases to execution", ago: 600, add: 452, del: 46),
                pr(2442, "acme/finq.api", "QDLY-8785: Report deductions to the authority through the partner", ago: 3_000, checks: .running, add: 1131, del: 36, comments: 4,
                   activity: activity(threads: 6, open: [said(person("elin"), 3_000), said(person("elin"), 40_000), said(bot("coderabbitai"), 20_000)], comment: said(person("johan"), 9_000), commit: 30_000)),
                pr(2460, "acme/finq.api", "QDLY-8785: Recall cases at the authority", ago: 5_400, checks: .failed, review: .changesRequested, add: 313, del: 30, comments: 2,
                   activity: activity(threads: 4, open: [said(person("sara"), 5_400), said(person("sara"), 6_000)], commit: 20_000)),
                pr(872, "acme/finq.admin-ui", "QDLY-8690: Rating conversion table as a grid of tiers and risk indicators", ago: 14_000, review: .approved, add: 2661, del: 717, comments: 9,
                   activity: activity(threads: 34, open: (0..<20).map { said(person("jakob"), 20_000 + Double($0) * 100) }, comment: said(person("niklas"), 13_000), commit: 15_000)),
                pr(2439, "acme/finq.api", "QDLY-8315: Store the journal number and date on the fields they belong to", ago: 40_000, draft: true, checks: .none, review: .required, add: 65, del: 2,
                   activity: activity(threads: 3, open: [said(bot("copilot-pull-request-reviewer"), 35_000)], commit: 60_000)),
                pr(191, "niklas/devops", "Redesign landing page with modern UI and responsive layout", ago: 90_000, draft: true, checks: .none, add: 295, del: 95, activity: activity()),
                pr(199, "niklas/devops", "[Snyk] Security upgrade cryptography from 45.0.7 to 46.0.5", ago: 120_000, add: 1, del: 1, author: "snyk-bot", activity: activity(botAuthor: true)),
                pr(2385, "acme/finq.api", "QDLY-8782: Define API models explicitly instead of copy-and-delete", ago: 200_000, state: .merged, review: .approved, add: 113, del: 159),
                pr(2301, "acme/finq.api", "QDLY-8701: Try the older export format", ago: 400_000, state: .closed, checks: .failed, add: 12, del: 4),
            ],
            .reviewRequested: [
                pr(2376, "acme/finq.api", "QDLY-8690: Match \"-\" to a rating without risk indicator, accept a tier list", ago: 7_000, review: .required, add: 211, del: 34, comments: 3, author: "elin",
                   activity: activity(threads: 2, open: [said(person("niklas"), 8_000)], requested: ["niklas"])),
                pr(1746, "acme/finq.api", "FIX(QDLY-7998): align receiver address placement with the print-house templates", ago: 90_000, checks: .failed, review: .required, add: 444, del: 38, author: "johan",
                   activity: activity(threads: 1, open: [said(person("johan"), 90_000)], reviews: [GitHubActivity.Review(actor: person("niklas"), state: "COMMENTED", date: now.addingTimeInterval(-200_000))], commit: 80_000)),
            ],
        ]
    }
}
#endif
