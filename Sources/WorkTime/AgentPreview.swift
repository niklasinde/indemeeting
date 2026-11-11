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
        let model = AgentModel(folder: repo)
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
                var signIn = [AgentItem(id: "user-0", kind: .user("Reply with just OK"))]
                AgentLogic.apply(.signIn, to: &signIn)
                model.preview(signIn, files: files)
                model.draft = ""
                await save(model, appearance: appearance, to: output.appendingPathComponent("agent-signin-\(name).png"))
                model.preview(Array(sample().suffix(2)), files: files)
                await save(model, appearance: appearance, to: output.appendingPathComponent("agent-permission-\(name).png"))
            }
            model.open(pr: GitHubLink.Target(repo: "niklasinde/worktime", number: 42), checkout: URL(fileURLWithPath: repo))
            await save(model, appearance: .aqua, to: output.appendingPathComponent("agent-pr-light.png"))
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
            .toolResult(id: "1", content: "Sources/WorkTime/AgentLogic.swift\nagent/src/main.ts", isError: false, auto: false),
            .toolUse(id: "3", tool: "mcp__worktime__github_pr", summary: "quiddly-com/finq.api#2483",
                     detail: "{\n  \"pr\" : \"https://github.com/quiddly-com/finq.api/pull/2483\"\n}"),
            .toolResult(id: "3", content: "{\"title\": \"Search the fields the count came from\"}", isError: false, auto: false),
            .toolUse(id: "4", tool: "Bash", summary: "git log --oneline -5", detail: "git log --oneline -5"),
            .toolResult(id: "4", content: "d1e2fdb Run the Agent window on the Claude subscription", isError: false, auto: true),
            .toolUse(id: "2", tool: "Read", summary: "Sources/WorkTime/AgentLogic.swift", detail: ""),
            .toolResult(id: "2", content: "import Foundation\n…", isError: false, auto: false),
            .text("The window answers them in `Sources/WorkTime/AgentClient.swift:120`, and the transcript marks the prompt answered in "
                  + "[AgentLogic.answer](Sources/WorkTime/AgentLogic.swift#L115).\n\n- The sidecar waits in `canUseTool` (agent/src/main.ts:93).\n"
                  + "- Deny sends `allow: false`, which the SDK turns into a refusal."),
            .result(sessionID: "preview-session", isError: false, text: "", turns: 5, model: "claude-sonnet-5-5"),
        ]
        answer.forEach { AgentLogic.apply($0, to: &items, auto: true) }
        items.append(AgentItem(id: "user-\(items.count)", kind: .user("Run the tests")))
        let command = (["swift build 2>&1 | tail -5 && ./test.sh && python3 - <<'EOF'", "import json, subprocess",
                        "result = json.loads(subprocess.check_output(['gh', 'pr', 'view', '2483', '--json', 'files']))"]
                       + (1...12).map { "print({'file': result['files'][\($0)]['path'], 'additions': result['files'][\($0)]['additions']})" }
                       + ["EOF"]).joined(separator: "\n")
        AgentLogic.apply(.permissionRequest(id: "7", tool: "Bash", summary: "swift build 2>&1 | tail -5 && ./test.sh \u{2026}", detail: command),
                         to: &items)
        return items
    }
}
#endif
