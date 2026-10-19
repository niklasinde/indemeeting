#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `MeetingRecorder --render-projects <folder>` saves PNGs of the work breakdown (rule, guessed and
/// unassigned rows) and the project setup, from a scratch database in the folder.
enum ProjectPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-projects"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let database = output.appendingPathComponent("projects.sqlite")
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: database.path + $0) }
        guard let store = try? MeetingStore.open(at: database), (try? write(to: store)) != nil else { exit(1) }
        let model = ActivityModel(store: store, tracker: ActivityTracker(store: store))
        model.start()
        let breakdown = VStack(alignment: .leading, spacing: 16) {
            ProjectSetupHint(model: model)
            WorkBreakdown(model: model, range: model.day)
        }
        Task { @MainActor in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let mode = appearance == .aqua ? "light" : "dark"
                await render(breakdown.frame(width: 860), appearance: appearance, to: output.appendingPathComponent("breakdown-\(mode).png"))
                await render(ProjectSetupView(store: store) {}, appearance: appearance, to: output.appendingPathComponent("setup-\(mode).png"))
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    @MainActor
    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) async {
        let controller = NSHostingController(rootView: view.padding(20).background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }

    /// The shape of a real day: finq.api work without a rule, a few blocks the AI guessed as the only project it knew.
    private static func write(to store: MeetingStore) throws {
        let papercut = try store.addProject("Papercut")
        let waste = try store.addProject("Waste")
        try store.addRule(project: papercut.id, field: .host, pattern: "papercut.work")
        try store.addRule(project: waste.id, field: .host, pattern: "www.youtube.com")
        let day = Calendar.current.startOfDay(for: Date())
        var cursor = 0.0
        func add(_ minutes: Double, app: String, title: String? = nil, url: String? = nil, repo: String? = nil, branch: String? = nil,
                 guess: Int64? = nil, owner: String? = nil) throws {
            var key = ActivityKey(appBundle: "com.\(app)", appName: app, windowTitle: title, url: url, repo: repo, branch: branch,
                                  ticket: ActivityLogic.ticket(in: branch, title, url), claude: [], idle: false, claudeFocus: nil, redaction: nil)
            key.owner = owner
            try store.saveBlock(ActivityBlock(id: 0, start: day.addingTimeInterval(cursor * 60), end: day.addingTimeInterval((cursor + minutes) * 60),
                                              key: key, projectID: nil, aiProjectID: guess))
            cursor += minutes
        }
        let api = "NI/QDLY-8315-reminder-fees"
        try add(33, app: "PyCharm", repo: "finq.api", branch: api)
        for _ in 0..<8 { try add(1, app: "PyCharm", repo: "finq.api", branch: api, guess: papercut.id) }
        try add(40, app: "PyCharm", repo: "finq.api", branch: "develop")
        try add(18, app: "Safari", title: "Pull request", url: "github.com/quiddly-com/finq.api/pull/2094", repo: "finq.api",
                branch: "NI/pr-2094-review", guess: papercut.id, owner: "quiddly-com")
        try add(26, app: "Safari", url: "quiddly.atlassian.net/browse/ISD-13089")
        try add(35, app: "Xcode", repo: "indemeeting", branch: "main")
        try add(22, app: "Safari", title: "Invoices", url: "papercut.work/invoices", branch: "NI/papercut-invoices")
        try add(15, app: "Safari", url: "www.youtube.com/watch")
    }
}
#endif
