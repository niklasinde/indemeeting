#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `MeetingRecorder --render-claude-api-previews <folder>` saves PNGs of the Claude API chat window and its
/// Settings group in light and dark appearance, with a sample chat, a fake key kept in memory and a sample pull request.
enum ClaudeAPIPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-claude-api-previews"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func run(to output: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let database = output.appendingPathComponent("claude-api.sqlite")
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: database.path + $0) }
        guard let store = try? MeetingStore.open(at: database) else {
            FileHandle.standardError.write(Data("Failed: could not open the preview database\n".utf8))
            exit(1)
        }
        let keys = ClaudeAPIKeyStore(secrets: MemorySecretStore())
        try? keys.save("sk-ant-api03-PREVIEW-ONLY-0000abcd")
        let pr = ClaudeAPIContext.PullRequest(title: "Show the merge method only when merging a pull request",
                                              url: "https://github.com/niklasinde/indemeeting/pull/412",
                                              repo: "niklasinde/indemeeting", checks: "5 passed \u{00B7} 1 running",
                                              description: "The merge method picker only appears when the pull request is merged from the page.")
        let model = ClaudeAPIChatModel(store: store, keys: keys, selectedPullRequest: { pr })
        seed(store)
        model.reload()
        model.open(model.chats.first { $0.title == "Release checklist" } ?? model.chats[0])
        model.includesPullRequest = true

        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let window = ClaudeAPIWindow.makeWindow(ClaudeAPIView(model: model))
                window.appearance = NSAppearance(named: appearance)
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                window.orderBack(nil)
                try? await Task.sleep(nanoseconds: 900_000_000)
                PreviewRenderer.save(window, to: output.appendingPathComponent("claude-api-chat-\(name).png"))
                window.orderOut(nil)

                let settings = NSHostingController(rootView: ClaudeAPISettingsSection(keys: keys, store: store).padding(20).frame(width: 560))
                let panel = NSWindow(contentViewController: settings)
                panel.appearance = NSAppearance(named: appearance)
                panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                panel.orderBack(nil)
                try? await Task.sleep(nanoseconds: 700_000_000)
                PreviewRenderer.save(panel, to: output.appendingPathComponent("claude-api-settings-\(name).png"))
                panel.orderOut(nil)
            }
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static func seed(_ store: MeetingStore) {
        let now = Date()
        guard let first = try? store.createClaudeAPIChat(title: "Release checklist", now: now.addingTimeInterval(-600)) else { return }
        try? store.addClaudeAPIMessage(chat: first, role: .user, text: "What does the release checklist need before we ship 4.12?", now: now.addingTimeInterval(-600))
        try? store.addClaudeAPIMessage(chat: first, role: .assistant,
                                       text: "Before shipping **4.12** the checklist needs:\n\n- Validation signed off by the test team.\n- Release notes in `release-notes/4.12.md`.\n- The Bluetooth regression checked on two headsets.\n\nThe tag can go out once all three are ticked.",
                                       usage: ClaudeAPIUsage(inputTokens: 812, outputTokens: 236), now: now.addingTimeInterval(-590))
        guard let second = try? store.createClaudeAPIChat(title: "Summarise this PR", now: now) else { return }
        try? store.addClaudeAPIMessage(chat: second, role: .user, text: "Is this PR safe to merge?", now: now)
    }
}
#endif
