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
        let suite = "WorkTimeAgentPreview"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        AgentModel.defaults = UserDefaults(suiteName: suite) ?? .standard
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
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
            let main = AgentModel(folder: NSHomeDirectory() + "/git", main: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                main.preview([])
                await save(main, appearance: appearance, to: output.appendingPathComponent("main-empty-\(name).png"))
                main.preview(catchUp())
                await save(main, appearance: appearance, to: output.appendingPathComponent("main-catchup-\(name).png"))
            }
            model.preview([AgentItem(id: "user-0", kind: .user(AgentInbox.prompt("Add the missing downgrade to the migration and push.")))]
                          + Array(sample().dropFirst().prefix(4)))
            await save(model, appearance: .aqua, to: output.appendingPathComponent("agent-from-main-light.png"))
            await sessions(to: output)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path

    /// The pull request page with the agent in the terminal's place, for each placement, then with the review prompt and a long
    /// draft waiting in the composer.
    @MainActor
    static func embedded(window: NSWindow, model: GitHubModel, directory: TicketDirectory, output: URL) async {
        let pr = GitHubPreview.samples[.created]![1]
        model.showSample(prs: GitHubPreview.samples, directory: directory)
        model.showSample(selecting: pr, detail: GitHubPreview.detailSamples[0].detail)
        let agent = AgentModel(folder: repo)
        agent.open(pr: GitHubLink.Target(repo: pr.repo, number: pr.number), checkout: URL(fileURLWithPath: repo))
        agent.preview(sample())
        agent.draft = ""
        PRAgents.shared.showSample(pr.url, model: agent)
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: DockPlacement.choiceKey)
        @MainActor func shot(_ name: String, _ size: NSSize, appearances: [NSAppearance.Name] = [.aqua, .darkAqua]) async {
            window.setContentSize(size)
            for appearance in appearances {
                window.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                PreviewRenderer.save(window, to: output.appendingPathComponent("agent-embed-\(name)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        for (name, size) in [("automatic-1530", NSSize(width: 1530, height: 1000)), ("automatic-1240", NSSize(width: 1240, height: 860)),
                             ("automatic-1440-tall", NSSize(width: 1440, height: 960))] {
            defaults.set(DockPlacement.Choice.automatic.rawValue, forKey: DockPlacement.choiceKey)
            await shot(name, size)
        }
        for choice in [DockPlacement.Choice.right, .below, .bottom] {
            defaults.set(choice.rawValue, forKey: DockPlacement.choiceKey)
            await shot(choice.rawValue, NSSize(width: 1530, height: 1000))
        }
        defaults.set(DockPlacement.Choice.automatic.rawValue, forKey: DockPlacement.choiceKey)
        agent.preview([])
        agent.open(pr: GitHubLink.Target(repo: pr.repo, number: pr.number), checkout: URL(fileURLWithPath: repo))
        await shot("new", NSSize(width: 1530, height: 1000), appearances: [.aqua])
        agent.draft = (1...10).map { "Line \($0) of a long prompt that keeps going so it wraps in the narrow pane beside the page." }
            .joined(separator: "\n")
        await shot("long-draft", NSSize(width: 1530, height: 1000), appearances: [.aqua])
        defaults.set(DockPlacement.Choice.below.rawValue, forKey: DockPlacement.choiceKey)
        agent.open(pr: GitHubLink.Target(repo: pr.repo, number: pr.number), checkout: URL(fileURLWithPath: repo))
        await shot("new-below", NSSize(width: 1530, height: 1000), appearances: [.aqua])
        if let stored { defaults.set(stored, forKey: DockPlacement.choiceKey) } else { defaults.removeObject(forKey: DockPlacement.choiceKey) }
    }

    @MainActor
    private static func save(_ model: AgentModel, appearance: NSAppearance.Name, to url: URL) async {
        await save(AgentView(model: model), appearance: appearance, to: url)
    }

    @MainActor
    private static func save<Content: View>(_ view: Content, size: NSSize = NSSize(width: 820, height: 640), appearance: NSAppearance.Name,
                                            to url: URL) async {
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

    /// The Main page with its agents list and a session restored from a Claude Code transcript, the session list, and a pull
    /// request's agent picked in the list. Only with `CLAUDE_CONFIG_DIR` set, since it writes its transcripts there.
    @MainActor
    private static func sessions(to output: URL) async {
        guard ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil else { return }
        let folder = "/Users/me/git", now = Date()
        let ids = ["3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", "9a8b7c6d-5e4f-4321-9876-543210fedcba", "11111111-2222-4333-8444-555555555555",
                   "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"]
        let projects = ClaudeTranscripts.folder(cwd: folder)
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try? transcript(folder: folder).write(to: projects.appendingPathComponent(ids[1] + ".jsonl"), atomically: true, encoding: .utf8)
        let other = #"{"type":"user","cwd":"/Users/me/git","message":{"role":"user","content":"Rename the voucher class to Voucher in finq.api"}}"#
        try? other.write(to: projects.appendingPathComponent(ids[3] + ".jsonl"), atomically: true, encoding: .utf8)
        let defaults = AgentModel.defaults
        func entry(_ index: Int, _ title: String, hours: Double, model: String?) -> AgentSessionEntry {
            AgentSessionEntry(id: ids[index], folder: folder, created: now.addingTimeInterval(-hours * 3600 - 600),
                              lastUsed: now.addingTimeInterval(-hours * 3600), title: title, model: model)
        }
        let api = "https://github.com/quiddly-com/finq.api/pull/2591", admin = "https://github.com/quiddly-com/finq.admin-ui/pull/664"
        let saved = "https://github.com/quiddly-com/finq.client-ui/pull/412"
        let history = [AgentOverview.mainKey: [entry(1, "Why does the VAT test skip on CI?", hours: 0.3, model: "claude-sonnet-5-5"),
                                               entry(0, "Catch up", hours: 5, model: "claude-haiku-5-5"),
                                               entry(2, "Draft the release notes for 3.14", hours: 50, model: "claude-opus-5-5")],
                       saved: [AgentSessionEntry(id: ids[2], folder: folder, created: now.addingTimeInterval(-90_000),
                                                 lastUsed: now.addingTimeInterval(-86_400), title: "Review quiddly-com/finq.client-ui#412", model: nil)]]
        defaults.set(AgentSessions.encode(history), forKey: AgentSessions.historyKey)
        defaults.set(folder, forKey: AgentLogic.mainFolderKey)
        defaults.set(ids[1], forKey: AgentLogic.mainSessionKey)
        let hub = AgentHub.shared
        for (url, busy, seen) in [(api, false, false), (admin, true, true)] {
            guard let target = GitHubLink.pullRequest(at: url) else { continue }
            let agent = AgentModel(folder: folder)
            agent.open(pr: target, checkout: nil)
            agent.preview(url == admin ? Array(sample().suffix(2)) : Array(sample().prefix(7)), busy: busy, seen: seen)
            PRAgents.shared.showSample(url, model: agent)
            PRAgents.shared.hide(url)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let size = NSSize(width: 1180, height: 760)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            hub.selected = AgentOverview.mainKey
            await save(AgentsPage(hub: hub), size: size, appearance: appearance, to: output.appendingPathComponent("main-restored-\(name).png"))
            let others = await hub.main.otherSessions()
            await save(AgentSessionList(model: hub.main, others: others, showsOthers: true).background(.background), size: NSSize(width: 340, height: 300),
                       appearance: appearance, to: output.appendingPathComponent("sessions-picker-\(name).png"))
        }
        hub.selected = api
        await save(AgentsPage(hub: hub), size: size, appearance: .aqua, to: output.appendingPathComponent("main-pr-agent-light.png"))
        hub.selected = saved
        await save(AgentsPage(hub: hub), size: size, appearance: .aqua, to: output.appendingPathComponent("main-saved-pr-light.png"))
    }

    /// A Claude Code transcript: a question, a search and a read, the answer, then a fix with an edit.
    private static func transcript(folder: String) -> String {
        func line(_ object: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
        }
        func user(_ content: Any) -> String { line(["type": "user", "cwd": folder, "message": ["role": "user", "content": content]]) }
        func assistant(_ content: [[String: Any]]) -> String { line(["type": "assistant", "cwd": folder, "message": ["role": "assistant", "content": content]]) }
        return [
            user("Why does the VAT test skip on CI?"),
            assistant([["type": "tool_use", "id": "toolu_1", "name": "Grep", "input": ["pattern": "skipif", "path": folder + "/finq.api/tests"]]]),
            user([["type": "tool_result", "tool_use_id": "toolu_1", "content": "tests/test_vat.py:12: @pytest.mark.skipif(not VAT_ENABLED)"]]),
            assistant([["type": "tool_use", "id": "toolu_2", "name": "Read", "input": ["file_path": folder + "/finq.api/tests/test_vat.py"]]]),
            user([["type": "tool_result", "tool_use_id": "toolu_2", "content": [["type": "text", "text": "import pytest\n…"]]]]),
            assistant([["type": "text", "text": "It skips because `VAT_ENABLED` is read from the environment and CI never sets it "
                        + "(finq.api/tests/test_vat.py:12). Set it in the test job, or default it to true in `conftest.py`."]]),
            user("Fix it in conftest"),
            assistant([["type": "tool_use", "id": "toolu_3", "name": "Edit", "input": ["file_path": folder + "/finq.api/tests/conftest.py",
                                                                                       "old_string": "", "new_string": "VAT_ENABLED = True"]]]),
            user([["type": "tool_result", "tool_use_id": "toolu_3", "content": "The file was updated.", "is_error": false]]),
            assistant([["type": "text", "text": "Done: `conftest.py` now turns VAT on for every test, so the skip no longer applies."]]),
        ].joined(separator: "\n")
    }

    /// Main answering Catch up, then asking to hand a prompt to a pull request's agent.
    private static func catchUp() -> [AgentItem] {
        let api = "https://github.com/quiddly-com/finq.api/pull/2591", admin = "https://github.com/quiddly-com/finq.admin-ui/pull/664"
        let review = "https://github.com/quiddly-com/finq.client-ui/pull/412"
        var items = [AgentItem(id: "user-0", kind: .user(AgentLogic.catchUpPrompt))]
        let events: [AgentEvent] = [
            .toolUse(id: "1", tool: "mcp__worktime__attention", summary: "", detail: ""),
            .toolResult(id: "1", content: "## Pull requests …", isError: false, auto: false),
            .toolUse(id: "2", tool: "mcp__worktime__agent_session", summary: "quiddly-com/finq.api#2591", detail: ""),
            .toolResult(id: "2", content: "Session …", isError: false, auto: false),
            .text("""
                Most urgent first:

                1. **finq.admin-ui#664** \u{2014} its agent is waiting for you to allow `npm run lint -- --fix`. [Open the agent](\(GitHubLink.agentLink(for: admin)))
                2. **finq.api#2591** \u{2014} the review finished 12 min ago and you haven't seen it: the migration has no downgrade and the tests skip the VAT path. [PR](\(api)) \u{00B7} [agent](\(GitHubLink.agentLink(for: api)))
                3. **finq.client-ui#412** \u{2014} Jessica asked for your review 2 h ago. [PR](\(review))
                4. **Slack** \u{2014} Anna asked in #release whether 3.14 ships Thursday.
                5. **Action item** from Tuesday's planning: send the VAT spec to Erik.
                """),
            .result(sessionID: "preview-main", isError: false, text: "", turns: 3, model: "claude-sonnet-5-5"),
        ]
        events.forEach { AgentLogic.apply($0, to: &items) }
        items.append(AgentItem(id: "user-\(items.count)", kind: .user("Have the finq.api agent add the downgrade")))
        AgentLogic.apply(.permissionRequest(id: "9", tool: "mcp__worktime__send_to_agent",
                                            summary: "quiddly-com/finq.api#2591, Add the missing downgrade to the migration and push.",
                                            detail: "{\n  \"pr_url\" : \"\(api)\",\n  \"text\" : \"Add the missing downgrade to the migration and push.\"\n}"),
                         to: &items)
        return items
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
