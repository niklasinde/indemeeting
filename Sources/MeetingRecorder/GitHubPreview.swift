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
        let content = GitHubDetailContent(pr: sample.pr, detail: sample.detail, directory: directory, ask: {})
            .padding(32).frame(width: 840, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
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

    private static var detailSamples: [(name: String, pr: GitHubPR, detail: GitHubPRDetail)] {
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

    private static var samples: [GitHubKind: [GitHubPR]] {
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
