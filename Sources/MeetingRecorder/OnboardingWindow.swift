import AVFoundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private static let seenKey = "onboardingShown"

    var recorder: Recorder?
    private var window: NSWindow?

    func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        show()
    }

    func show() {
        guard let recorder else { return }
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: OnboardingView(recorder: recorder) { [weak self] in self?.window?.close() }))
            window.title = "Meeting Recorder Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var microphone = Permissions.microphoneStatus
    @Published var screenRecording = Permissions.screenRecordingGranted
    @Published var testing = false
    @Published var testFile: URL?
    @Published var testFailed = false

    func refresh() {
        microphone = Permissions.microphoneStatus
        screenRecording = Permissions.screenRecordingGranted
    }

    func requestMicrophone() {
        Task {
            _ = await Permissions.requestMicrophone()
            refresh()
        }
    }

    func runTest(with recorder: Recorder) {
        testing = true
        testFailed = false
        Task {
            testFile = await recorder.recordTest()
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
    private var screenRecording: Bool { model.screenRecording }
    private var testFile: URL? { model.testFile }
    private var allSet: Bool { microphone == .authorized && screenRecording && testFile != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                Text("Set up Meeting Recorder").font(.title2.bold())
            }
            Text("Meeting Recorder lives in the menu bar and has no Dock icon. Grant two permissions, then run a quick test.")
                .foregroundStyle(.secondary)

            step("1. Microphone", done: microphone == .authorized,
                 detail: microphone == .denied ? "Access denied. Enable it in Privacy settings." : "Records your own voice.") {
                if microphone == .denied {
                    Button("Open Microphone Settings") { Permissions.openMicrophoneSettings() }
                } else if microphone != .authorized {
                    Button("Allow Microphone") { model.requestMicrophone() }
                }
            }

            step("2. Screen & System Audio Recording", done: screenRecording,
                 detail: screenRecording ? "Granted." : "Needed to capture the other participants. After allowing it, macOS requires a relaunch.") {
                if !screenRecording {
                    Button("Allow Screen Recording") { _ = CGRequestScreenCaptureAccess() }
                    Button("Open Settings") { Permissions.openScreenRecordingSettings() }
                    Button("Relaunch App") { Permissions.relaunch() }
                }
            }

            step("3. Record a 5-second test", done: testFile != nil, detail: testDetail) {
                Button(model.testing ? "Recording…" : "Record Test") { model.runTest(with: recorder) }
                    .disabled(model.testing || microphone != .authorized || !screenRecording)
                if let testFile {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([testFile]) }
                }
            }

            Label("Look for the waveform icon at the top right of the menu bar. If the menu bar is full (or hidden behind the notch) it may not show. Quit a few menu-bar apps or use Setup & Help… from here to reopen this window.",
                  systemImage: "menubar.arrow.up.rectangle")
                .font(.callout)
                .foregroundStyle(.secondary)

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

    private var testDetail: String {
        if model.testFailed { return recorder.errorMessage ?? "The test recording failed." }
        if let testFile { return "Saved \(testFile.lastPathComponent)." }
        return "Confirms that both microphone and system audio work."
    }

    private func step<Actions: View>(_ title: String, done: Bool, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                HStack { actions() }
            }
        }
    }
}
