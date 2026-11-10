#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-notch <folder>` saves PNGs of the notch bar with made-up Slack messages, in several panel
/// setups, and of the Notch bar and Slack settings. Nothing is stored and nothing is fetched.
enum NotchPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-notch", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let slack = SlackModel.shared
        let panels = NotchPanelsModel.shared
        let bar = NotchBar(screen: NSScreen.main ?? NSScreen.screens[0])
        let standard = NotchPanelSetup.standard
        let swapped = standard.turning(.gitHub, on: false).turning(.slack, on: true)
        Task { @MainActor in
            @MainActor func shot(_ name: String, _ view: some View, appearance: NSAppearance.Name = .darkAqua) async {
                await render(view, appearance: appearance, to: output.appendingPathComponent("\(name).png"))
            }
            @MainActor func notch(_ name: String, setup: NotchPanelSetup, list: NotchPanelID?, hasNotch: Bool = true) async {
                panels.showSample(setup)
                await shot(name, bar.sample(list: list, hasNotch: hasNotch).frame(width: 600).padding(.bottom, 8).background(Color.gray.opacity(0.35)))
            }
            slack.showSample(messages: messages, badge: 3)
            await notch("bar-default", setup: standard, list: nil)
            await notch("bar-slack-for-github", setup: swapped, list: nil)
            await notch("bar-slack-for-github-no-notch", setup: swapped, list: nil, hasNotch: false)
            await notch("bar-one", setup: NotchPanelSetup(order: standard.order, enabled: [.slack]), list: nil)
            await notch("bar-two", setup: NotchPanelSetup(order: standard.order, enabled: [.jira, .slack]), list: nil)
            await notch("bar-four", setup: NotchPanelSetup(order: standard.order, enabled: Set(NotchPanelID.allCases).subtracting([.todo])), list: nil)
            await notch("bar-five-no-notch", setup: NotchPanelSetup(order: standard.order, enabled: Set(NotchPanelID.allCases)), list: nil, hasNotch: false)
            await notch("slack-all", setup: swapped, list: .slack)
            slack.showSample(messages: messages.filter { $0.kind == .mention }, unreadKnown: false)
            await notch("slack-recent-dms-fallback", setup: swapped, list: .slack)
            slack.showSample(messages: [], hasToken: false)
            await notch("slack-not-set-up", setup: swapped, list: .slack)
            slack.showSample(messages: [], error: .missingScope("search:read"))
            await notch("slack-missing-scope", setup: swapped, list: .slack)
            slack.showSample(messages: messages, badge: 3)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                let settings = VStack(spacing: 22) {
                    NotchBarSettingsSection(model: panels)
                    SlackSettingsSection(model: slack)
                }
                panels.showSample(swapped)
                await shot("notch-settings-\(suffix)", settings.padding(24).frame(width: 520).background(Color(nsColor: .windowBackgroundColor)), appearance: appearance)
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    @MainActor
    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) async {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 900_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }

    private static let names = ["U0ANNA": "Anna Berg", "U0ME": "Niklas", "U0BO": "Bo Lind"]

    private static var messages: [SlackMessage] {
        let now = Date().timeIntervalSince1970
        func message(_ kind: SlackMessage.Kind, _ channel: String, _ place: String, _ author: String?, _ text: String, minutes: Double,
                     unread: Int? = nil) -> SlackMessage {
            SlackMessage(kind: kind, teamID: "T0ACME", channelID: channel, place: place, author: author,
                         text: SlackLogic.clean(text, names: names), ts: String(format: "%.6f", now - minutes * 60), permalink: nil, unread: unread)
        }
        return SlackLogic.merged(mentions: [
            message(.mention, "C0DEV", "#dev", "Anna Berg", "<@U0ME> can you look at <https://github.com/acme/api/pull/7|finq.api #7> before the release? :eyes:", minutes: 12),
            message(.mention, "C0OPS", "#ops-alerts", "Bo Lind", "<!here> deploy of env-d is stuck, <@U0ME> did the migration in <#C0DEV|dev> run?", minutes: 95),
            message(.mention, "G0GRP", "anna, bo, niklas", "Anna Berg", "<@U0ME> Friday works for the retro &amp; planning", minutes: 60 * 26),
        ], direct: [
            message(.direct, "D0ANNA", "Anna Berg", "Anna Berg", "lunch at 12? :ramen:", minutes: 4, unread: 2),
            message(.direct, "D0BO", "Bo Lind", "Bo Lind", "Sent you the invoice draft, see <https://docs.example.com/x|the doc>", minutes: 48, unread: 1),
        ])
    }
}
#endif
