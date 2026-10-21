import SwiftUI

@main
enum Main {
    static func main() {
        #if DEBUG
        if let output = ProjectPreview.outputFolder(CommandLine.arguments) {
            MainActor.assumeIsolated { ProjectPreview.run(to: output) }
        }
        if let output = GitHubPreview.outputFolder(CommandLine.arguments) {
            MainActor.assumeIsolated { GitHubPreview.run(to: output) }
        }
        if let output = PhonePreview.outputFolder(CommandLine.arguments) {
            MainActor.assumeIsolated { PhonePreview.run(to: output) }
        }
        if let output = PreviewRenderer.outputFolder(CommandLine.arguments) {
            MainActor.assumeIsolated { PreviewRenderer.run(to: output) }
        }
        #endif
        if let link = PhoneCommandLine.value("--open-link", in: CommandLine.arguments) { GitHubLink.printFromCommandLine(link) }
        if CommandLine.arguments.contains("--mcp") { MCPServer.runFromCommandLine() }
        if CommandLine.arguments.contains("--github-prs") { GitHubClient.runFromCommandLine() }
        if let reference = PhoneCommandLine.value("--github-pr", in: CommandLine.arguments) { GitHubClient.runDetailFromCommandLine(reference) }
        if let reference = PhoneCommandLine.value("--github-pr-comments", in: CommandLine.arguments) { GitHubCommentsProbe.runFromCommandLine(reference) }
        if let reference = PhoneCommandLine.value("--github-pr-threads", in: CommandLine.arguments) { GitHubThreadsProbe.runFromCommandLine(reference) }
        if CommandLine.arguments.contains("--serve") { PhoneCommandLine.serve(CommandLine.arguments) }
        #if DEBUG
        if PhoneClient.isRequested(CommandLine.arguments) { PhoneClient.run(CommandLine.arguments) }
        #endif
        if let job = ChatLogic.chatArguments(CommandLine.arguments) { ChatCommandLine.run(job) }
        if let job = ProcessingLogic.processArguments(CommandLine.arguments) {
            let store = MeetingStore.openDefault()
            if let error = store.openError {
                FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            MeetingPipeline.runFromCommandLine(job.audio, languages: job.language.map { [$0] } ?? MeetingLanguage.listened(),
                                               recogniseOnly: job.recogniseOnly, store: store)
        }
        if let job = LanguageLogic.detectArguments(CommandLine.arguments) {
            LanguageDetector.runFromCommandLine(job.audio, among: job.candidates ?? MeetingLanguage.listened())
        }
        if CommandLine.arguments.contains("--download-speaker-model") { downloadSpeakerModel() }
        if let hours = ActivityLogic.contextArguments(CommandLine.arguments) { printContext(hours: hours) }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--simulate-activity"), index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { ActivitySimulation.run(URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        }
        #endif
        if let job = RecordingLogic.recordArguments(CommandLine.arguments) {
            recordFromCommandLine(job)
        }
        MeetingRecorderApp.main()
    }

    private static func downloadSpeakerModel() -> Never {
        Task {
            do {
                try await Diarizer.download { print("Downloading \(SpeakerModel.name)\u{2026} \(ProcessingLogic.percent($0))") }
                print("Saved to \(SpeakerModel.folder().path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    /// `--context [hours]`: prints a Markdown summary of the last hours of activity and meetings, then exits.
    private static func printContext(hours: Double) -> Never {
        let store = MeetingStore.openDefault()
        if let error = store.openError {
            FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        do {
            print(try store.contextMarkdown(hours: hours), terminator: "")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
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
            MenuContent(recorder: delegate.recorder, processor: delegate.processor, tracker: delegate.tracker,
                        databaseError: delegate.databaseError, openActivity: { delegate.mainWindow.showActivity() },
                        openGitHub: { delegate.mainWindow.showGitHub() }) {
                delegate.mainWindow.show(selecting: $0)
            }
        } label: {
            MenuLabel(recorder: delegate.recorder)
        }
        .commands {
            CommandGroup(after: .saveItem) { ExportCommand(library: delegate.mainWindow.library) }
            CommandGroup(after: .windowList) { ChatCommand() }
            CommandGroup(replacing: .appSettings) { SettingsButton() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()
    private let store = MeetingStore.openDefault()
    lazy var tracker = ActivityTracker(store: store)
    private lazy var classifier = ActivityClassifier(store: store)
    private lazy var notifier: Notifier = Notifier(onRecord: { [recorder] in await recorder.start() },
                                         onOpen: { [weak self] in self?.mainWindow.show(selecting: $0) },
                                         onStop: { [weak self] in await self?.stopRecording() },
                                         onKeepRecording: { [weak self] in self?.meetingWatcher.keepRecording() })
    lazy var processor: MeetingProcessor = MeetingProcessor(notifier: notifier, store: store)
    private lazy var meetingWatcher = MeetingWatcher(recorder: recorder, notifier: notifier) { [weak self] in
        await self?.stopRecording()
    }
    lazy var mainWindow: MainWindow = MainWindow(recorder: recorder, processor: processor, store: store, tracker: tracker)

    var databaseError: DatabaseUnavailable? { store.openError }
    private var hotKey: GlobalHotKey?

    func applicationWillFinishLaunching(_ notification: Notification) {
        meetingWatcher.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TerminationSignals.observe { NSApp.terminate(nil) }
        CommandLineLink.refresh()
        GitHubClaude.purge(GitHubClaude.promptFolder(), now: Date())
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.record.keyCode, modifiers: GlobalHotKey.record.carbonModifiers) { [weak self] in
            self?.toggleRecording()
        }
        GitHubModel.shared.store = store
        GitHubModel.shared.start()
        PhoneAccess.shared.configure(store: store)
        ChatWindow.shared.configure(store: store) { [weak self] in self?.mainWindow.show(meeting: $0, at: $1) }
        OnboardingWindow.shared.recorder = recorder
        OnboardingWindow.shared.tracker = tracker
        SettingsWindow.shared.speakers.store = store
        SettingsWindow.shared.projects.store = store
        SettingsWindow.shared.tracker = tracker
        OnboardingWindow.shared.showIfSetupNeeded()
        processor.summariseWhenModelReady()
        tracker.start()
        classifier.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        EmbeddedTerminalModel.shared.terminateAll()
        tracker.flush()
    }

    private func stopRecording() async {
        await processor.finishRecording(recorder, reveal: false)
    }

    private func toggleRecording() {
        Task {
            if recorder.isRecording { await stopRecording() } else { await recorder.start() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let message = EmbeddedTerminalModel.shared.quitMessage() {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "Quitting ends Claude and everything it started."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == GitHubLink.scheme {
            guard let target = GitHubLink.parse(url.absoluteString) else {
                mainWindow.show()
                GitHubModel.shared.showLinkNotice("Couldn't open that link")
                continue
            }
            mainWindow.showGitHub()
            GitHubModel.shared.open(target)
        }
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
    @ObservedObject var tracker: ActivityTracker
    let databaseError: DatabaseUnavailable?
    let openActivity: () -> Void
    let openGitHub: () -> Void
    let openApp: (URL?) -> Void
    @AppStorage(MeetingWatcher.enabledKey) private var notifyOnMeetingStart = true
    @AppStorage(MeetingWatcher.autoStopKey) private var stopWhenMeetingEnds = true
    @ObservedObject private var listened = ListenedLanguages.shared
    @ObservedObject private var github = GitHubModel.shared

    var body: some View {
        Button("Open Meeting Recorder") { openApp(nil) }
            .keyboardShortcut("o")
        if let error = databaseError {
            Divider()
            Text("Meeting database unavailable \u{2014} recordings still save")
            Text(error.url.path)
            Text(error.reason)
            Button("Reveal in Finder") { error.reveal() }
        }
        Divider()
        if recorder.isRecording {
            Text(recorder.statusText)
            Button(recorder.isPaused ? "Resume Recording" : "Pause Recording") { recorder.togglePause() }
            Button("Stop Recording") {
                Task { await processor.finishRecording(recorder) }
            }
            .keyboardShortcut(GlobalHotKey.record.key, modifiers: GlobalHotKey.record.modifiers)
        } else if recorder.meeting != nil {
            Text("Adding to meeting\u{2026}")
        } else {
            Button("Start Recording") { Task { await recorder.start() } }
                .keyboardShortcut(GlobalHotKey.record.key, modifiers: GlobalHotKey.record.modifiers)
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
        Button("Chat\u{2026}") { ChatWindow.shared.show() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        Menu("Languages: \(listened.summary)") {
            ForEach(MeetingLanguage.allCases) { language in
                Toggle(language.displayName, isOn: listened.isListening(language)).disabled(listened.isOnly(language))
            }
        }
        Divider()
        if let status = tracker.statusText {
            Text(status)
            Toggle("Pause activity tracking", isOn: Binding(get: { tracker.settings.paused }, set: { tracker.setPaused($0) }))
            Button("Open Activity") { openActivity() }
        }
        if let summary = github.menuSummary {
            Divider()
            Button(summary) { openGitHub() }
        }
        Divider()
        Toggle("Notify when a meeting starts", isOn: $notifyOnMeetingStart)
        Toggle("Stop automatically when the meeting ends", isOn: $stopWhenMeetingEnds)
        Button("Open Recordings Folder") { recorder.openFolder() }
        SettingsButton()
        Button("Setup & Help…") { OnboardingWindow.shared.show() }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsButton: View {
    var body: some View {
        Button("Settings\u{2026}") { SettingsWindow.shared.show() }
            .keyboardShortcut(",")
    }
}

enum MenuIcon {
    static func image(recording: Bool) -> NSImage {
        let name = recording ? "record.circle.fill" : "waveform.circle.fill"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Meeting Recorder") ?? NSImage()
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if recording { config = config.applying(.init(paletteColors: [.systemRed])) }
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = !recording
        return image
    }
}
