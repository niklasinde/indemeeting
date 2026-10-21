#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `MeetingRecorder --render-sessions <folder>` saves PNGs of the Sessions section with three sample sessions (one
/// running and waiting, one saved with a review run, one ended) and of the pull request page, in light and dark.
enum SessionsPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-sessions"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    private static let runningID = "5b1d6e2a-1c3f-4a7b-9e8d-0a1b2c3d4e51"
    private static let savedID = "5b1d6e2a-1c3f-4a7b-9e8d-0a1b2c3d4e52"
    private static let endedID = "5b1d6e2a-1c3f-4a7b-9e8d-0a1b2c3d4e53"

    @MainActor
    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let database = output.appendingPathComponent("sessions.sqlite")
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: database.path + $0) }
        guard let store = try? MeetingStore.open(at: database) else { exit(1) }
        let projects = output.appendingPathComponent("projects", isDirectory: true)
        ClaudeTranscripts.projectsFolder = projects
        let samples = GitHubPreview.detailSamples
        let running = samples[0], saved = samples[1], ended = samples[2]
        let directory = output.appendingPathComponent("work", isDirectory: true)
        let runningCWD = directory.appendingPathComponent(running.pr.repo, isDirectory: true).path
        let savedCWD = directory.appendingPathComponent(saved.pr.repo, isDirectory: true).path
        let endedCWD = directory.appendingPathComponent(ended.pr.repo, isDirectory: true).path

        writeTranscript(runningTranscript, id: runningID, cwd: runningCWD, root: projects)
        writeTranscript(savedTranscript, id: savedID, cwd: savedCWD, root: projects)
        writeTranscript(endedTranscript, id: endedID, cwd: endedCWD, root: projects)

        let model = GitHubModel.shared
        model.store = store
        let folder = URL(fileURLWithPath: runningCWD)
        EmbeddedTerminalModel.shared.showSample(running.pr.url, title: "Review \u{00B7} \(running.pr.repo) #\(running.pr.number)", directory: folder,
                                                output: "Claude Code\n\n> Reading the migration and its tests.\n", running: true)
        EmbeddedTerminalModel.shared.showSample(ended.pr.url, title: "Checks \u{00B7} \(ended.pr.repo) #\(ended.pr.number)",
                                                directory: URL(fileURLWithPath: endedCWD), output: "Claude Code\n\n> Finished.\n", running: false)
        for (pr, id, cwd, title, preset) in [(running.pr, runningID, runningCWD, "Review this pull request", GitHubClaude.Preset.review),
                                             (saved.pr, savedID, savedCWD, "Summarise for the ticket", .summary),
                                             (ended.pr, endedID, endedCWD, "Investigate failing checks", .checks)] {
            try? store.saveGitHubSession(GitHubClaudeSession(url: pr.url, id: id, cwd: cwd, kind: .interactive, preset: preset, title: title,
                                                             updated: Date()))
        }
        GitHubClaudeModel.shared.load()
        GitHubClaudeModel.shared.showSample(reviews: [saved.pr.url: sampleReview(saved.pr.url)])

        let library = RecordingLibrary(store: store, folder: output.appendingPathComponent("empty", isDirectory: true))
        let window = MainWindow.makeWindow(MainView(recorder: Recorder(), processor: MeetingProcessor(notifier: nil, store: store), library: library,
                                                    activity: ActivityModel(store: store, tracker: ActivityTracker(store: store)),
                                                    playback: AudioPlayback()))
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        Task { @MainActor in
            @MainActor func shot(_ name: String, appearances: [NSAppearance.Name] = [.aqua, .darkAqua]) async {
                for appearance in appearances {
                    window.appearance = NSAppearance(named: appearance)
                    SessionsModel.shared.tick()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    PreviewRenderer.save(window, to: output.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
            library.showsSessions = true
            SessionsModel.shared.showSample(selecting: running.pr.url, tab: .chat)
            await shot("sessions-waiting")
            SessionsModel.shared.showSample(selecting: saved.pr.url, tab: .chat)
            await shot("sessions-saved", appearances: [.aqua])
            SessionsModel.shared.showSample(selecting: ended.pr.url, tab: .chat)
            await shot("sessions-ended", appearances: [.aqua])
            library.showsGitHub = true
            model.showSample(prs: GitHubPreview.samples, directory: TicketDirectory())
            model.showSample(selecting: running.pr, detail: running.detail)
            await shot("pull-request-sessions")
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    private static func writeTranscript(_ lines: [[String: Any]], id: String, cwd: String, root: URL) {
        let folder = ClaudeTranscripts.folder(cwd: cwd, root: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: folder.appendingPathComponent(id + ".jsonl"))
    }

    private static func user(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": text]]
    }

    private static func assistant(_ blocks: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "message": ["role": "assistant", "content": blocks]]
    }

    private static func say(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

    private static func tool(_ name: String, _ command: String) -> [String: Any] {
        ["type": "tool_use", "name": name, "input": ["command": command]]
    }

    private static let runningTranscript: [[String: Any]] = [
        user("Review this pull request and tell me whether the migration is safe to run on production."),
        assistant([say("I'll read the diff and the migration first.")]),
        assistant([tool("Bash", "gh pr diff 2462")]),
        assistant([say("The migration drops `legacy_totals` in one step, and the rollback only re-creates the table. Should I keep a backup table before I write the review?")]),
    ]

    private static let savedTranscript: [[String: Any]] = [
        user("Summarise what changed for the ticket."),
        assistant([say("Three files changed: the invoice totals, the export and one test.")]),
        assistant([tool("Read", "Sources/export/totals.py")]),
        assistant([say("The export now rounds per line instead of per invoice. Nothing is left open.")]),
    ]

    private static let endedTranscript: [[String: Any]] = [
        user("Investigate the failing checks."),
        assistant([say("The integration job timed out waiting for the database, not on the code.")]),
        assistant([tool("Bash", "gh run view 991 --log-failed")]),
        assistant([say("Re-run the job once the database is back. There is nothing to change on the branch.")]),
    ]

    private static func sampleReview(_ url: String) -> GitHubReview {
        GitHubReview(url: url, headSHA: "e4748c4", preset: .summary,
                     text: "**Verdict: approve.** The export rounding is covered by the new test.", created: Date().addingTimeInterval(-900),
                     duration: 96, cost: 0.42)
    }
}
#endif
