#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-agent <folder>` saves PNGs of the Agent window with a made-up transcript (tool
/// calls, a pending permission and code references into this checkout) and the `@` file picker, in light and dark.
enum AgentPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-agent", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func run(to output: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let model = AgentModel(folder: repo, key: { "preview" })
        let files = ["Sources/WorkTime/AgentLogic.swift", "Sources/WorkTime/AgentClient.swift", "Sources/WorkTime/AgentView.swift",
                     "Sources/WorkTime/ChatLogic.swift", "agent/src/main.ts"]

        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                model.preview(sample(), files: files)
                model.draft = ""
                await save(model, appearance: appearance, to: output.appendingPathComponent("agent-\(name).png"))
                model.preview([], files: files)
                model.draft = "Explain how @agent"
                await save(model, appearance: appearance, to: output.appendingPathComponent("agent-mention-\(name).png"))
            }
            exit(0)
        }
        app.run()
        exit(0)
    }

    @MainActor
    private static func save(_ model: AgentModel, appearance: NSAppearance.Name, to url: URL) async {
        let window = AgentWindow.makeWindow(AgentView(model: model))
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 900_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }

    private static func sample() -> [AgentItem] {
        var items = [AgentItem(id: "user-0", kind: .user("Where are agent permission prompts answered? @Sources/WorkTime/AgentClient.swift"))]
        let answer: [AgentEvent] = [
            .session("preview-session"),
            .toolUse(id: "1", tool: "Grep", summary: "permission_request in Sources", detail: "{\n  \"pattern\" : \"permission_request\"\n}"),
            .toolResult(id: "1", content: "Sources/WorkTime/AgentLogic.swift\nagent/src/main.ts", isError: false),
            .toolUse(id: "2", tool: "Read", summary: "Sources/WorkTime/AgentLogic.swift", detail: ""),
            .toolResult(id: "2", content: "import Foundation\n…", isError: false),
            .text("The window answers them in `Sources/WorkTime/AgentClient.swift:120`, and the transcript marks the prompt answered in "
                  + "[AgentLogic.answer](Sources/WorkTime/AgentLogic.swift#L115).\n\n- The sidecar waits in `canUseTool` (agent/src/main.ts:93).\n"
                  + "- Deny sends `allow: false`, which the SDK turns into a refusal."),
            .result(sessionID: "preview-session", isError: false, text: "", cost: 0.04, turns: 3),
        ]
        answer.forEach { AgentLogic.apply($0, to: &items) }
        items.append(AgentItem(id: "user-\(items.count)", kind: .user("Run the tests")))
        AgentLogic.apply(.permissionRequest(id: "7", tool: "Bash", summary: "./test.sh", detail: ""), to: &items)
        return items
    }
}
#endif
