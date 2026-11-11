#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-workspaces <folder> --data-dir <scratch>` saves PNGs of the Main page with the Work and
/// Personal workspaces, each with its Main and agents, the collapsed and single-workspace views, and Settings → Agent.
enum WorkspacePreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-workspaces", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func run(to output: URL) -> Never {
        let suite = "WorkTimeWorkspacePreview"
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
        let store = WorkspaceStore.shared
        let hub = AgentHub.shared
        let home = NSHomeDirectory()
        let prs = [("https://github.com/quiddly-com/finq.api/pull/2591", home + "/git/quiddly/finq.api", true, false),
                   ("https://github.com/quiddly-com/finq.admin-ui/pull/664", home + "/git/quiddly/finq.admin-ui", false, true),
                   ("https://github.com/niklasinde/worktime/pull/42", home + "/git/inde/worktime", true, true),
                   ("https://github.com/niklasinde/papercut/pull/17", home + "/git/inde/papercut", false, true)]
        for (url, folder, waiting, seen) in prs {
            guard let target = GitHubLink.pullRequest(at: url) else { continue }
            let agent = AgentModel(folder: folder)
            agent.open(pr: target, checkout: URL(fileURLWithPath: folder))
            agent.preview([AgentItem(id: "user-0", kind: .user("Review \(url)")), AgentItem(id: "text-1", kind: .text("Looks good, one nit."))],
                          busy: waiting && !seen, seen: seen)
            PRAgents.shared.showSample(url, model: agent)
            PRAgents.shared.hide(url)
        }
        if let work = store.workspace("work"), let personal = store.workspace("personal") {
            store.instructions.write("# Main for Personal\n\nCatch up on my own projects first. Keep it short.", for: personal)
            _ = store.instructions.ensure(work)
            hub.mains[work.id]?.preview(catchUp(work: true))
            hub.mains[personal.id]?.preview(catchUp(work: false))
        }
        store.move("https://github.com/niklasinde/papercut/pull/17", to: "work")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let size = NSSize(width: 1180, height: 760)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            hub.selected = "main:work"
            await save(AgentsPage(hub: hub), size: size, appearance: appearance, to: output.appendingPathComponent("workspaces-work-\(name).png"))
            hub.selected = "main:personal"
            await save(AgentsPage(hub: hub), size: size, appearance: appearance, to: output.appendingPathComponent("workspaces-personal-\(name).png"))
        }
        UserDefaults.standard.set("personal", forKey: Workspaces.selectedKey)
        UserDefaults.standard.set("work", forKey: Workspaces.collapsedKey)
        await save(AgentsPage(hub: hub), size: size, appearance: .aqua, to: output.appendingPathComponent("workspaces-switcher-personal-light.png"))
        UserDefaults.standard.set(Workspaces.allChoice, forKey: Workspaces.selectedKey)
        await save(AgentsPage(hub: hub), size: size, appearance: .aqua, to: output.appendingPathComponent("workspaces-collapsed-light.png"))
        UserDefaults.standard.removeObject(forKey: Workspaces.selectedKey)
        UserDefaults.standard.removeObject(forKey: Workspaces.collapsedKey)
        let settings = AgentSettingsSection(store: AgentRuleStore.shared).padding(24).frame(width: 620, alignment: .topLeading)
        await save(ScrollView { settings }, size: NSSize(width: 620, height: 1500), appearance: .aqua,
                   to: output.appendingPathComponent("workspaces-settings-light.png"))
    }

    private static func catchUp(work: Bool) -> [AgentItem] {
        var items = [AgentItem(id: "user-0", kind: .user(AgentLogic.catchUpPrompt))]
        let reply = work
            ? "1. **finq.api#2591** waits for your review, the checks passed.\n2. **finq.admin-ui#664** has an agent asking to run `npm test`."
            : "1. **niklasinde/worktime#42** has a new comment from a reviewer.\n2. Nothing else in Personal needs you."
        AgentLogic.apply(.text(reply), to: &items)
        AgentLogic.apply(.result(sessionID: "preview-\(work)", isError: false, text: "", turns: 2, model: "claude-sonnet-5-5"), to: &items)
        return items
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
