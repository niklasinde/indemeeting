import SwiftUI

@main
enum Main {
    static func main() {
        if let job = ProcessingLogic.processArguments(CommandLine.arguments) {
            MeetingPipeline.runFromCommandLine(job.audio, language: job.language ?? .current)
        }
        if let job = RecordingLogic.recordArguments(CommandLine.arguments) {
            recordFromCommandLine(seconds: job.seconds, to: job.output)
        }
        MeetingRecorderApp.main()
    }

    private static func recordFromCommandLine(seconds: Double, to output: URL?) -> Never {
        if let output, FileManager.default.fileExists(atPath: output.path) {
            FileHandle.standardError.write(Data("Failed: \(output.path) already exists\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            let recorder = Recorder()
            let recording = Task { await recorder.record(seconds: seconds, to: output) }
            TerminationSignals.observe { recording.cancel() }
            print("Recording \(seconds)s\u{2026}")
            guard let url = await recording.value else {
                FileHandle.standardError.write(Data("Failed: \(recorder.errorMessage ?? "not recording")\n".utf8))
                exit(1)
            }
            if let notice = recorder.notice { print(notice) }
            for source in AudioSource.allCases {
                guard let level = recorder.level(of: source) else { continue }
                print("\(source): \(level.count) samples, rms \(String(format: "%.5f", level.rms))\(level.isSilent ? " (silent)" : "")")
            }
            print("Saved: \(url.path)")
            exit(0)
        }
        dispatchMain()
    }
}

/// Turns SIGTERM, SIGINT and SIGHUP into a clean shutdown so a recording in progress is finalized.
enum TerminationSignals {
    private static var sources: [DispatchSourceSignal] = []

    static func observe(_ handler: @escaping () -> Void) {
        sources = [SIGTERM, SIGINT, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }
}

struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: delegate.recorder, processor: delegate.processor) { delegate.mainWindow.show() }
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
    lazy var mainWindow = MainWindow(recorder: recorder, processor: processor)

    func applicationWillFinishLaunching(_ notification: Notification) {
        meetingWatcher.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TerminationSignals.observe { NSApp.terminate(nil) }
        OnboardingWindow.shared.recorder = recorder
        OnboardingWindow.shared.showIfSetupNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isRecording else { return .terminateNow }
        Task {
            await recorder.stop(reveal: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
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
    let openApp: () -> Void
    @AppStorage(MeetingWatcher.enabledKey) private var notifyOnMeetingStart = true
    @AppStorage(MeetingLanguage.storageKey) private var language = MeetingLanguage.swedish

    var body: some View {
        Button("Open Meeting Recorder") { openApp() }
            .keyboardShortcut("o")
        Divider()
        if recorder.isRecording {
            Text("Recording  \(recorder.elapsedText)")
            Button("Stop Recording") {
                Task { await processor.finishRecording(recorder) }
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
