#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-assistants <folder> --data-dir <scratch>` saves PNGs of the Main page with the assistants
/// under each Main (one with an error badge) and the Developer assistant answering Main, and of the instructions editor.
enum AssistantPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-assistants", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func run(to output: URL) -> Never {
        guard AppPaths.dataDirectory != nil else { fatalError("--render-assistants needs --data-dir, so the real data is never touched") }
        let suite = "WorkTimeAssistantPreview"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        AgentModel.defaults = UserDefaults(suiteName: suite) ?? .standard
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await render(to: output)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            exit(0)
        }
        app.run()
        exit(0)
    }

    @MainActor
    private static func render(to output: URL) async {
        let store = AssistantStore.shared, hub = AgentHub.shared
        store.start()
        store.files.write("---\nname: Planner\ndescription: Plans the sprint\nmodel: gpt\n---\nPlan.", workspace: "work", slug: "planner")
        store.refresh(force: true)
        guard let developer = store.entry("assistant:work:developer"), let reporter = store.entry("assistant:work:time-reporter") else { return }
        var items = [AgentItem(id: "user-0", kind: .user(AgentInbox.prompt("Work on QDLY-123 in finq.api: the VAT test skips on CI.")))]
        let events: [AgentEvent] = [
            .toolUse(id: "1", tool: "mcp__worktime__jira_issue", summary: "QDLY-123", detail: ""),
            .toolResult(id: "1", content: "# QDLY-123 VAT test skipped on CI …", isError: false, auto: false),
            .toolUse(id: "2", tool: "Bash", summary: "git switch -c NI/QDLY-123", detail: "git switch -c NI/QDLY-123"),
            .text("I read QDLY-123 and the repository\u{2019}s CLAUDE.md. `VAT_ENABLED` is only set locally, so CI skips the test (tests/test_vat.py:12). "
                  + "I will default it to true in `conftest.py`, run `pytest tests/test_vat.py`, and ask before I push."),
            .result(sessionID: "preview-developer", isError: false, text: "", turns: 3, model: "claude-opus-5-5", mode: .ask),
        ]
        events.forEach { AgentLogic.apply($0, to: &items) }
        store.load(developer).preview(items, seen: false)
        let size = NSSize(width: 1180, height: 760)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        hub.selected = developer.key
        await save(AgentsPage(hub: hub), size: size, appearance: .aqua, to: output.appendingPathComponent("assistants-main-light.png"))
        await save(AssistantEditorSheet(entry: reporter) {}.background(.background), size: NSSize(width: 760, height: 620), appearance: .darkAqua,
                   to: output.appendingPathComponent("assistants-editor-dark.png"))
        hub.selected = "main:work"
        store.stopAll()
    }

    @MainActor
    private static func save<Content: View>(_ view: Content, size: NSSize, appearance: NSAppearance.Name, to url: URL) async {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(size)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 900_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }
}
#endif
