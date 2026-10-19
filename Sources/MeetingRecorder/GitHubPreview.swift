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
            model.kind = .reviewRequested
            await shot("review-requested", appearances: [.aqua])
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

    private static var samples: [GitHubKind: [GitHubPR]] {
        let now = Date()
        func pr(_ number: Int, _ repo: String, _ title: String, ago: TimeInterval, state: GitHubPR.State = .open, draft: Bool = false,
                checks: GitHubPR.Checks = .passed, review: GitHubPR.Review? = nil, add: Int = 40, del: Int = 8, comments: Int = 0,
                author: String = "niklas") -> GitHubPR {
            GitHubPR(url: "https://github.com/\(repo)/pull/\(number)", number: number, title: title, repo: repo, isDraft: draft, state: state,
                     updated: now.addingTimeInterval(-ago), review: review, checks: checks, author: author, additions: add, deletions: del,
                     comments: comments)
        }
        return [
            .created: [
                pr(2462, "acme/finq.api", "QDLY-8786: Send enforcement cases to execution", ago: 600, add: 452, del: 46),
                pr(2442, "acme/finq.api", "QDLY-8785: Report deductions to the authority through the partner", ago: 3_000, checks: .running, add: 1131, del: 36, comments: 4),
                pr(2460, "acme/finq.api", "QDLY-8785: Recall cases at the authority", ago: 5_400, checks: .failed, review: .changesRequested, add: 313, del: 30, comments: 2),
                pr(872, "acme/finq.admin-ui", "QDLY-8690: Rating conversion table as a grid of tiers and risk indicators", ago: 14_000, review: .approved, add: 2661, del: 717, comments: 9),
                pr(2439, "acme/finq.api", "QDLY-8315: Store the journal number and date on the fields they belong to", ago: 40_000, draft: true, checks: .none, review: .required, add: 65, del: 2),
                pr(191, "niklas/devops", "Redesign landing page with modern UI and responsive layout", ago: 90_000, draft: true, checks: .none, add: 295, del: 95),
                pr(2385, "acme/finq.api", "QDLY-8782: Define API models explicitly instead of copy-and-delete", ago: 200_000, state: .merged, review: .approved, add: 113, del: 159),
                pr(2301, "acme/finq.api", "QDLY-8701: Try the older export format", ago: 400_000, state: .closed, checks: .failed, add: 12, del: 4),
            ],
            .reviewRequested: [
                pr(2376, "acme/finq.api", "QDLY-8690: Match \"-\" to a rating without risk indicator, accept a tier list", ago: 7_000, review: .required, add: 211, del: 34, comments: 3, author: "elin"),
                pr(1746, "acme/finq.api", "FIX(QDLY-7998): align receiver address placement with the print-house templates", ago: 90_000, checks: .failed, review: .required, add: 444, del: 38, author: "johan"),
            ],
        ]
    }
}
#endif
