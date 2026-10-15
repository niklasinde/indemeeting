import SwiftUI

@main
enum Main {
    static func main() {
        if let job = ProcessingLogic.processArguments(CommandLine.arguments) {
            MeetingPipeline.runFromCommandLine(job.audio, language: job.language ?? .current)
        }
        MeetingRecorderApp.main()
    }
}

struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: delegate.recorder, processor: delegate.processor)
        } label: {
            MenuLabel(recorder: delegate.recorder)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()
    private lazy var notifier = Notifier { [recorder] in await recorder.start() }
    lazy var processor = MeetingProcessor(notifier: notifier)
    private lazy var meetingWatcher = MeetingWatcher(recorder: recorder, notifier: notifier)

    func applicationWillFinishLaunching(_ notification: Notification) {
        meetingWatcher.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OnboardingWindow.shared.recorder = recorder
        OnboardingWindow.shared.showIfSetupNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        OnboardingWindow.shared.show()
        return true
    }
}

struct MenuLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        Image(nsImage: MenuIcon.image(recording: recorder.isRecording))
    }
}

struct MenuContent: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var processor: MeetingProcessor
    @AppStorage(MeetingWatcher.enabledKey) private var notifyOnMeetingStart = true
    @AppStorage(MeetingLanguage.storageKey) private var language = MeetingLanguage.swedish

    var body: some View {
        if recorder.isRecording {
            Text("Recording  \(recorder.elapsedText)")
            Button("Stop Recording") {
                Task { if let url = await recorder.stop() { processor.process(url) } }
            }
        } else {
            Button("Start Recording") { Task { await recorder.start() } }
        }
        if let notice = recorder.notice {
            Divider()
            Text(notice)
        }
        if let message = recorder.errorMessage {
            Divider()
            Text(message)
            if recorder.permissionDenied {
                Button("Open Privacy Settings") { Permissions.openPrivacySettings() }
            }
        }
        Divider()
        if let status = processor.status { Text(status) }
        if let message = processor.errorMessage { Text(message) }
        if let summary = processor.latestSummary {
            Button("Open summary") { NSWorkspace.shared.open(summary) }
        }
        Button("Transcribe & summarise a recording\u{2026}") { processor.chooseRecording() }
        Picker("Meeting language", selection: $language) {
            ForEach(MeetingLanguage.allCases) { Text($0.displayName).tag($0) }
        }
        Divider()
        Toggle("Notify when a meeting starts", isOn: $notifyOnMeetingStart)
        Button("Open Recordings Folder") { recorder.openFolder() }
        Button("Setup & Help…") { OnboardingWindow.shared.show() }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum MenuIcon {
    static func image(recording: Bool) -> NSImage {
        let name = recording ? "record.circle.fill" : "waveform.circle"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Meeting Recorder") ?? NSImage()
        guard recording else {
            base.isTemplate = true
            return base
        }
        let image = base.withSymbolConfiguration(.init(paletteColors: [.systemRed])) ?? base
        image.isTemplate = false
        return image
    }
}
