import AppKit
import SwiftUI

/// Watches the installed copy of the app and offers a restart once a newer build is on disk.
@MainActor
final class AppUpgrade: ObservableObject {
    static let shared = AppUpgrade()
    static let checkInterval: TimeInterval = 60

    @Published private(set) var ready = false
    @Published private(set) var dismissed = false
    /// Why the restart did not happen, shown under the banner.
    @Published private(set) var message: String?
    /// Set once the app has agreed to quit so that it can open the new copy.
    private(set) var relaunching = false

    private var launched: BuildIdentity?
    private var bundleURL = Bundle.main.bundleURL
    private var recorder: Recorder?
    private var timer: Timer?

    func start(recorder: Recorder, bundleURL: URL = Bundle.main.bundleURL) {
        guard timer == nil else { return }
        self.recorder = recorder
        self.bundleURL = bundleURL
        launched = UpgradeLogic.identity(of: bundleURL)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        guard let launched else { return }
        ready = UpgradeLogic.isReady(launched: launched, installed: UpgradeLogic.identity(of: bundleURL))
    }

    func later() {
        dismissed = true
        message = nil
    }

    func restartNow() {
        guard let recorder else { return }
        switch UpgradeLogic.restartDecision(recording: recorder.isBusy, sessions: EmbeddedTerminalModel.shared.runningCount) {
        case .blocked:
            message = UpgradeLogic.recordingMessage
        case .confirm(let sessions):
            if confirm(sessions) { quit() }
        case .restart:
            quit()
        }
    }

    /// Called as the app terminates; the new copy opens only once this process has exited.
    func relaunchIfRequested() {
        guard relaunching else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = UpgradeLogic.relaunchScript(pid: ProcessInfo.processInfo.processIdentifier, bundle: bundleURL)
        try? process.run()
    }

    private func quit() {
        if let problem = UpgradeLogic.launchProblem(of: bundleURL) {
            message = "Couldn't restart: \(problem)"
            return
        }
        relaunching = true
        NSApp.terminate(nil)
    }

    private func confirm(_ sessions: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = UpgradeLogic.confirmMessage(sessions: sessions)
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    #if DEBUG
    /// Debug previews show the banner without a newer copy on disk.
    func showSample(ready: Bool, message: String? = nil) {
        self.ready = ready
        self.message = message
    }
    #endif
}

/// The notice at the top of the main window that offers the restart.
struct UpgradeBanner: View {
    @ObservedObject var upgrade: AppUpgrade

    var body: some View {
        if UpgradeLogic.showsBanner(ready: upgrade.ready, dismissed: upgrade.dismissed) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(UpgradeLogic.bannerTitle)
                    if let message = upgrade.message {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Restart now") { upgrade.restartNow() }
                Button("Later") { upgrade.later() }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(10)
            .background(.quaternary)
        }
    }
}
