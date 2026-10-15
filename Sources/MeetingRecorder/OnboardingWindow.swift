import AVFoundation
import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private static let seenKey = "onboardingShown"

    var recorder: Recorder?
    private lazy var window: AppWindow = AppWindow { [unowned self] in
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: OnboardingView(recorder: recorder!) { [weak self] in self?.window.close() }))
        window.title = "Meeting Recorder Setup"
        window.styleMask = [.titled, .closable]
        return window
    }

    func showIfSetupNeeded() {
        let seen = UserDefaults.standard.bool(forKey: Self.seenKey)
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        if !seen || !Permissions.microphoneReady { show() }
    }

    func show() {
        guard recorder != nil else { return }
        window.show()
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var microphone = Permissions.microphoneStatus
    @Published var systemAudio = Permissions.systemAudio
    @Published var notifications = UNAuthorizationStatus.notDetermined
    @Published var testing = false
    @Published var testFile: URL?
    @Published var testFailed = false

    init() { refresh() }

    func refresh() {
        microphone = Permissions.microphoneStatus
        systemAudio = Permissions.systemAudio
        Task { notifications = await Permissions.notificationStatus }
    }

    func requestMicrophone() { request { _ = await Permissions.requestMicrophone() } }
    func requestNotifications() { request { _ = await Permissions.requestNotifications() } }
    func requestSystemAudio() { request { _ = await Permissions.requestSystemAudio() } }

    private func request(_ ask: @escaping () async -> Void) {
        Task {
            await ask()
            refresh()
        }
    }

    func runTest(with recorder: Recorder) {
        testing = true
        testFailed = false
        Task {
            testFile = await recorder.record(seconds: 5)
            testFailed = testFile == nil
            testing = false
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var recorder: Recorder
    let close: () -> Void

    @StateObject private var model = OnboardingModel()

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var microphone: AVAuthorizationStatus { model.microphone }
    private var systemAudio: Bool { model.systemAudio == .granted }
    private var testFile: URL? { model.testFile }
    private var allSet: Bool { microphone == .authorized && systemAudio && testFile != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up Meeting Recorder").font(.title2.bold())
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Meeting Recorder lives in the menu bar and has no Dock icon. Allow the microphone and system audio, then run a quick test.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step("1. Microphone", done: microphone == .authorized,
                 detail: microphone == .denied ? "Access denied. Enable it in Privacy settings." : "Records your own voice.") {
                if microphone == .denied {
                    Button("Open Microphone Settings") { Permissions.openMicrophoneSettings() }
                } else if microphone != .authorized {
                    Button("Allow Microphone") { model.requestMicrophone() }
                }
            }

            step("2. System audio (the other participants)", done: systemAudio, detail: systemAudioDetail) {
                if model.systemAudio != .granted {
                    if model.systemAudio != .denied {
                        Button("Allow System Audio") { model.requestSystemAudio() }
                    }
                    Button("Open Settings") { Permissions.openSystemAudioSettings() }
                }
            }

            step("3. Notifications (Optional)", done: notificationsAllowed, detail: notificationDetail) {
                if model.notifications == .denied {
                    Button("Open Notification Settings") { Permissions.openNotificationSettings() }
                } else if !notificationsAllowed {
                    Button("Allow Notifications") { model.requestNotifications() }
                }
            }

            step("4. Record a 5-second test", done: testFile != nil, detail: testDetail) {
                Button(model.testing ? "Recording…" : "Record Test") { model.runTest(with: recorder) }
                    .disabled(model.testing || microphone != .authorized)
                if let testFile {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([testFile]) }
                }
            }

            Label("Look for the waveform icon at the top right of the menu bar. If the menu bar is full (or hidden behind the notch) it may not show. Quit a few menu-bar apps or use Setup & Help… from here to reopen this window.",
                  systemImage: "menubar.arrow.up.rectangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                if allSet { Label("You're all set", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                Spacer()
                if allSet {
                    Button("Start Recording") {
                        Task { await recorder.start() }
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button(allSet ? "Done" : "Close") { close() }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(poll) { _ in model.refresh() }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    private var notificationsAllowed: Bool { [.authorized, .provisional].contains(model.notifications) }

    private var notificationDetail: String {
        if model.notifications == .denied { return "Turned off. Enable them in Notification settings." }
        return "Offers to record when another app starts using the microphone, e.g. a Zoom or Teams call."
    }

    private var testDetail: String {
        if model.testFailed { return recorder.errorMessage ?? "The test recording failed." }
        if let testFile { return "Saved \(testFile.lastPathComponent)." }
        return systemAudio ? "Confirms that both microphone and system audio work." : "Confirms that the microphone works."
    }

    private var systemAudioDetail: String {
        switch model.systemAudio {
        case .granted: return "Granted. The other participants are recorded too."
        case .denied: return "Denied, so only your own voice is recorded. Allow Meeting Recorder under System Audio Recording Only in Settings."
        case .unknown: return "Required to record the meeting: other participants come through system audio. Uses System Audio Recording Only, not Screen Recording."
        }
    }

    private func step<Actions: View>(_ title: String, done: Bool, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { actions() }
            }
        }
    }
}
