import SwiftUI

@main
enum Main {
    static func main() {
        #if DEBUG
        if let output = PreviewRenderer.outputFolder(CommandLine.arguments), #available(macOS 14, *) {
            MainActor.assumeIsolated { PreviewRenderer.run(to: output) }
        }
        #endif
        if let job = ProcessingLogic.processArguments(CommandLine.arguments) {
            MeetingPipeline.runFromCommandLine(job.audio, language: job.language ?? .current, store: .openDefault())
        }
        if let job = RecordingLogic.recordArguments(CommandLine.arguments) {
            recordFromCommandLine(job)
        }
        MeetingRecorderApp.main()
    }

    private static func recordFromCommandLine(_ job: RecordJob) -> Never {
        if job.continuing == nil, let output = job.output, FileManager.default.fileExists(atPath: output.path) {
            FileHandle.standardError.write(Data("Failed: \(output.path) already exists\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            let recorder = Recorder()
            let recording = Task { await recorder.record(job) }
            TerminationSignals.observe { recording.cancel() }
            print("Recording \(job.seconds)s\u{2026}")
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
            MenuContent(recorder: delegate.recorder, processor: delegate.processor) { delegate.mainWindow.show(selecting: $0) }
        } label: {
            MenuLabel(recorder: delegate.recorder)
        }
        .commands {
            CommandGroup(after: .saveItem) { ExportCommand(library: delegate.mainWindow.library) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()
    private let store = MeetingStore.openDefault()
    private lazy var notifier: Notifier = Notifier(onRecord: { [recorder] in await recorder.start() },
                                         onOpen: { [weak self] in self?.mainWindow.show(selecting: $0) },
                                         onStop: { [weak self] in await self?.stopRecording() },
                                         onKeepRecording: { [weak self] in self?.meetingWatcher.keepRecording() })
    lazy var processor: MeetingProcessor = MeetingProcessor(notifier: notifier, store: store)
    private lazy var meetingWatcher = MeetingWatcher(recorder: recorder, notifier: notifier) { [weak self] in
        await self?.stopRecording()
    }
    lazy var mainWindow: MainWindow = MainWindow(recorder: recorder, processor: processor, store: store)

    func applicationWillFinishLaunching(_ notification: Notification) {
        meetingWatcher.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TerminationSignals.observe { NSApp.terminate(nil) }
        OnboardingWindow.shared.recorder = recorder
        OnboardingWindow.shared.showIfSetupNeeded()
    }

    private func stopRecording() async {
        await processor.finishRecording(recorder, reveal: false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isBusy else { return .terminateNow }
        Task {
            await recorder.stop(reveal: false)
            while recorder.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
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
    let openApp: (URL?) -> Void
    @AppStorage(MeetingWatcher.enabledKey) private var notifyOnMeetingStart = true
    @AppStorage(MeetingWatcher.autoStopKey) private var stopWhenMeetingEnds = true
    @AppStorage(MeetingLanguage.storageKey) private var language = MeetingLanguage.swedish

    var body: some View {
        Button("Open Meeting Recorder") { openApp(nil) }
            .keyboardShortcut("o")
        Divider()
        if recorder.isRecording {
            Text(recorder.statusText)
            Button(recorder.isPaused ? "Resume Recording" : "Pause Recording") { recorder.togglePause() }
            Button("Stop Recording") {
                Task { await processor.finishRecording(recorder) }
            }
        } else if recorder.meeting != nil {
            Text("Adding to meeting\u{2026}")
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
        if let meeting = processor.latestMeeting {
            Button("Open summary") { openApp(meeting) }
        }
        Button("Transcribe & summarise a recording\u{2026}") { processor.chooseRecording() }
        Picker("Meeting language", selection: $language) {
            ForEach(MeetingLanguage.allCases) { Text($0.displayName).tag($0) }
        }
        Divider()
        Toggle("Notify when a meeting starts", isOn: $notifyOnMeetingStart)
        Toggle("Stop automatically when the meeting ends", isOn: $stopWhenMeetingEnds)
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
