import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MainWindow {
    let library: RecordingLibrary
    let activity: ActivityModel
    private let playback = AudioPlayback()
    private let window: AppWindow

    init(recorder: Recorder, processor: MeetingProcessor, store: MeetingStore, tracker: ActivityTracker) {
        library = RecordingLibrary(store: store)
        activity = ActivityModel(store: store, tracker: tracker)
        let view = MainView(recorder: recorder, processor: processor, library: library, activity: activity, playback: playback)
        window = AppWindow(onClose: { [playback] in playback.pause() }) { Self.makeWindow(view) }
    }

    func show(selecting meeting: URL? = nil) {
        library.start()
        if let meeting {
            library.query = ""
            library.selection = meeting
            library.tab = .summary
        }
        window.show()
    }

    func show(meeting id: Int64, at time: TimeInterval?) {
        guard let url = library.meetingURL(id: id) else { return }
        show(selecting: url)
        guard let time else { return }
        library.tab = .transcript
        library.seekTarget = time
        playback.load(url)
        playback.seek(to: time)
    }

    func showActivity() {
        library.start()
        library.showsActivity = true
        window.show()
    }

    static func makeWindow(_ view: MainView) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: controller)
        window.title = "Meeting Recorder"
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 980, height: 660))
        return window
    }
}

enum DetailTab: String, CaseIterable {
    case summary = "Summary"
    case notes = "Notes"
    case transcript = "Transcript"
}

/// The recordings on disk joined with their rows in the store, plus the content of the selected meeting.
@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [RecordingEntry] = []
    @Published var selection: URL? { didSet { if oldValue != selection { loadContent() } } }
    @Published var query = "" { didSet { if oldValue != query { search() } } }
    @Published var tab = DetailTab.summary
    @Published var confirmingDelete = false
    /// The Activity page is shown instead of the selected meeting.
    @Published var showsActivity = false
    /// A moment in the selected meeting that the transcript should scroll to.
    @Published var seekTarget: TimeInterval?
    /// The meeting being recorded, listed before its file exists.
    @Published var recording: URL? { didSet { if oldValue != recording { rebuild() } } }
    @Published private var meetings: [String: Meeting] = [:]
    @Published private var matches: Set<String>?
    @Published private var content: MeetingContent?

    let folder: URL
    private let store: MeetingStore
    private var files: [FolderItem] = []
    private var durations: [String: (modified: Date, seconds: TimeInterval)] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var observer: NSObjectProtocol?

    init(store: MeetingStore, folder: URL = AppPaths.recordings) {
        self.store = store
        self.folder = folder
    }

    var selected: RecordingEntry? { showsActivity ? nil : recordings.first { $0.id == selection } }

    func select(_ entry: RecordingEntry) {
        showsActivity = false
        selection = entry.id
    }

    func meetingURL(id: Int64) -> URL? {
        (try? store.meeting(id: id)).flatMap { $0 }.map { folder.appendingPathComponent($0.audioFile) }
    }

    var databaseError: DatabaseUnavailable? { store.openError }

    /// Titles, notes and checks are only editable while there is a database to save them in.
    var canEdit: Bool { store.isAvailable }

    var visibleRecordings: [RecordingEntry] {
        guard let matches else { return recordings }
        return recordings.filter { matches.contains($0.fileName) }
    }

    func start() {
        defer { refresh() }
        guard watcher == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: MeetingStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    func refresh() {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        let values = urls.map { (url: $0, values: try? $0.resourceValues(forKeys: keys)) }
        let modified = Dictionary(values.map { ($0.url.lastPathComponent, $0.values?.contentModificationDate ?? .distantPast) }) { $1 }
        files = values.map { FolderItem(name: $0.url.lastPathComponent, created: $0.values?.creationDate ?? .distantPast) }
        do {
            try store.sync(folder: folder, files: files)
        } catch {
            FileHandle.standardError.write(Data("Sync failed: \(error.localizedDescription)\n".utf8))
        }
        reload()
        let missing = files.map(\.name).filter { LibraryLogic.isListed($0) && durations[$0]?.modified != modified[$0] }
        guard !missing.isEmpty else { return }
        let folder = folder
        let store = store
        Task.detached(priority: .utility) {
            let found = missing.compactMap { name in
                (try? AudioFiles.duration(of: folder.appendingPathComponent(name))).map { (name, (modified[name] ?? .distantPast, $0)) }
            }
            try? store.setDurations(Dictionary(found.map { ($0.0, $0.1.1) }) { $1 })
            await MainActor.run {
                self.durations.merge(found) { $1 }
                self.rebuild()
            }
        }
    }

    private func reload() {
        meetings = Dictionary(((try? store.meetings()) ?? []).map { ($0.audioFile, $0) }) { $1 }
        search()
        loadContent()
        rebuild()
    }

    private func rebuild() {
        let known = meetings.compactMapValues(\.duration).merging(durations.mapValues(\.seconds)) { $1 }
        let listed = LibraryLogic.recordings(in: folder, files: files, durations: known)
        recordings = LibraryLogic.withRecording(recording, in: listed, now: Date())
    }

    private func search() {
        matches = try? store.search(query)
    }

    private func loadContent() {
        content = selection.flatMap { try? store.content(of: $0.lastPathComponent) }
    }

    func meeting(of entry: RecordingEntry) -> Meeting? { meetings[entry.fileName] }

    func content(of entry: RecordingEntry) -> MeetingContent? {
        content?.meeting.audioFile == entry.fileName ? content : nil
    }

    func title(of entry: RecordingEntry) -> String { meeting(of: entry)?.title ?? LibraryLogic.fallbackTitle }

    func language(of entry: RecordingEntry) -> MeetingLanguage { meeting(of: entry)?.language ?? .current }

    func languageDetected(of entry: RecordingEntry) -> Bool { meeting(of: entry)?.languageDetected ?? false }

    func setTitle(_ title: String, of entry: RecordingEntry) {
        let override = LibraryLogic.titleOverride(title, aiTitle: meeting(of: entry)?.aiTitle)
        perform { try store.setTitleOverride(entry.fileName, override) }
    }

    func setNotes(_ notes: String, of entry: RecordingEntry) {
        perform { try store.setNotes(entry.fileName, notes) }
    }

    func renameSpeaker(_ speaker: Speaker, of entry: RecordingEntry, to name: String) {
        perform { try store.renameSpeaker(entry.fileName, speaker, to: name) }
    }

    func setChecked(_ item: ChecklistItem, _ checked: Bool) {
        guard let id = Int64(item.key) else { return }
        perform { try store.setChecked(actionItem: id, checked) }
    }

    func moveSelection(by offset: Int) {
        let visible = LibraryLogic.grouped(visibleRecordings, now: Date()).flatMap(\.entries)
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selection }.map { $0 + offset } ?? 0
        selection = visible[min(max(index, 0), visible.count - 1)].id
    }

    func trash(_ entry: RecordingEntry) {
        Task {
            do {
                _ = try await NSWorkspace.shared.recycle([entry.audio] + (RecordingLogic.stems(of: entry.audio) ?? []))
                try store.delete(entry.fileName)
            } catch {
                NSAlert(error: error).runModal()
            }
            refresh()
        }
    }

    func exportMarkdown(_ entry: RecordingEntry) {
        guard let content = try? store.content(of: entry.fileName) else { return }
        let panel = NSSavePanel()
        panel.title = "Export as Markdown"
        let title = content.meeting.title
        let name = title == LibraryLogic.fallbackTitle ? entry.audio.deletingPathExtension().lastPathComponent : title
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try ProcessingLogic.exportMarkdown(content).write(to: url, atomically: true, encoding: .utf8) }
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { NSAlert(error: error).runModal() }
    }
}

@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private(set) var url: URL?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL?, force: Bool = false) {
        guard force || url != self.url else { return }
        pause()
        self.url = url
        player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.delegate = self
        duration = player?.duration ?? 0
        position = 0
    }

    func toggle() {
        guard let player else { return }
        guard !player.isPlaying else { return pause() }
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.position = self?.player?.currentTime ?? 0 }
        }
    }

    func play(from time: TimeInterval) {
        seek(to: time)
        if !isPlaying { toggle() }
    }

    func pause() {
        player?.pause()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        position = player?.currentTime ?? 0
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        position = time
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.pause() }
    }
}

struct MainView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var activity: ActivityModel
    let playback: AudioPlayback

    var body: some View {
        NavigationSplitView {
            Sidebar(recorder: recorder, processor: processor, library: library) { newMeeting() }
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let error = library.databaseError { DatabaseErrorBanner(error: error) }
                if library.showsActivity {
                    ActivityView(model: activity, tracker: activity.tracker)
                } else if let entry = library.selected {
                    RecordingDetail(entry: entry, recorder: recorder, processor: processor, library: library, playback: playback)
                        .id(entry.id)
                } else {
                    Text(library.recordings.isEmpty ? "No recordings yet" : "Select a meeting")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Spacer()
                if recorder.isRecording { pauseButton }
                if let entry = library.selected, !entry.inProgress, !recorder.isBusy { ContinueButton(recorder: recorder, entry: entry) }
                recordButton
                moreMenu
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            library.refresh()
        }
        .onReceive(recorder.$meeting) { library.recording = $0 }
        .confirmationDialog("Move \(library.selected?.audio.lastPathComponent ?? "") to the Trash?",
                            isPresented: $library.confirmingDelete) {
            Button("Move to Trash", role: .destructive) { deleteSelected() }
        } message: {
            Text("Its transcript, summary and notes are deleted.")
        }
    }

    @ViewBuilder private var recordButton: some View {
        if recorder.isRecording {
            Button {
                Task {
                    if let url = await processor.finishRecording(recorder, reveal: false) { library.selection = url }
                }
            } label: {
                Label {
                    Text("Stop  \(recorder.elapsedText)").monospacedDigit()
                } icon: {
                    Image(systemName: "stop.fill").foregroundStyle(.red)
                }
                .labelStyle(.titleAndIcon)
            }
            .help("Stop Recording")
        } else {
            Button { newMeeting() } label: {
                Label {
                    Text("New Meeting")
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(.red)
                }
                .labelStyle(.titleAndIcon)
            }
            .disabled(recorder.isBusy)
            .help("Record a new meeting (\u{2318}N)")
        }
    }

    private var pauseButton: some View {
        Button { recorder.togglePause() } label: {
            Label(recorder.isPaused ? "Resume" : "Pause", systemImage: recorder.isPaused ? "record.circle" : "pause.fill")
                .labelStyle(.titleAndIcon)
        }
        .help(recorder.isPaused ? "Resume Recording" : "Pause Recording")
    }

    private func newMeeting() {
        guard !recorder.isBusy else {
            library.selection = recorder.meeting
            return
        }
        Task {
            await recorder.start()
            if let meeting = recorder.meeting {
                library.query = ""
                library.selection = meeting
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let entry = library.selected, !entry.inProgress {
                Button("Continue Recording") { Task { await recorder.start(continuing: entry.audio) } }
                    .disabled(recorder.isBusy)
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.audio]) }
                Button("Transcribe & summarise") { processor.process(entry.audio) }
                    .disabled(processor.processing == entry.audio)
                Picker("Language", selection: Binding(get: { library.language(of: entry) },
                                                      set: { processor.process(entry.audio, in: $0) })) {
                    ForEach(MeetingLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(processor.processing == entry.audio)
                .help("Transcribe and summarise the meeting again in another language")
                Button("Recognise speakers") { processor.recogniseSpeakers(entry.audio) }
                    .disabled(processor.processing == entry.audio || !Diarizer.isReady)
                    .help(Diarizer.isReady ? "Tell the speakers apart again without transcribing"
                          : "Download \(SpeakerModel.name) in Settings first")
                Button("Export as Markdown\u{2026}") { library.exportMarkdown(entry) }
                if let id = library.meeting(of: entry)?.id {
                    Button("Ask About This Meeting\u{2026}") { ChatWindow.shared.show(scope: .meeting(id, label: library.title(of: entry))) }
                }
                Divider()
                Button("Delete\u{2026}", role: .destructive) { library.confirmingDelete = true }
                Divider()
            }
            SettingsButton()
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }

    private func deleteSelected() {
        guard let entry = library.selected else { return }
        if playback.url == entry.audio { playback.load(nil) }
        library.trash(entry)
    }
}

struct Sidebar: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var library: RecordingLibrary
    let newMeeting: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SearchField(text: $library.query)
                Button(action: newMeeting) {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("n")
                .help(recorder.isBusy ? "A meeting is being recorded; this shows it" : "New meeting (\u{2318}N)")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            activityRow
            chatRow
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(LibraryLogic.grouped(library.visibleRecordings, now: Date()), id: \.group) { group, entries in
                        Text(group.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(entries) { row($0, group: group) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .onMoveCommand { direction in
                if direction == .up { library.moveSelection(by: -1) }
                if direction == .down { library.moveSelection(by: 1) }
            }
            statusFooter
        }
    }

    private var activityRow: some View {
        Button { library.showsActivity = true } label: {
            Label("Activity", systemImage: "clock")
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(library.showsActivity ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help("What you worked on, by day and week")
    }

    private var chatRow: some View {
        Button { ChatWindow.shared.show() } label: {
            Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help("Ask about your meetings and work (\u{2318}\u{21E7}A)")
    }

    private func row(_ entry: RecordingEntry, group: DateGroup) -> some View {
        Button { library.select(entry) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(library.title(of: entry))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if recorder.meeting == entry.audio {
                        RecordingStatus(recorder: recorder)
                    } else {
                        Text(([dateText(entry.date, group: group)] + [entry.duration.map(LibraryLogic.minutesText)].compactMap { $0 })
                            .joined(separator: " \u{00B7} "))
                    }
                    if processor.processing == entry.audio { ProgressView().controlSize(.mini) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(library.selected?.id == entry.id ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dateText(_ date: Date, group: DateGroup) -> String {
        switch group {
        case .today, .yesterday: return date.formatted(date: .omitted, time: .shortened)
        case .thisWeek: return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .earlier: return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
    }

    @ViewBuilder private var statusFooter: some View {
        let messages = [recorder.notice, recorder.errorMessage, processor.errorMessage].compactMap { $0 }
        if !messages.isEmpty || !Permissions.allGranted {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(messages, id: \.self) { Text($0) }
                if !Permissions.allGranted {
                    Text("Some permissions are missing")
                    Button("Open Setup\u{2026}") { OnboardingWindow.shared.show() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct DatabaseErrorBanner: View {
    let error: DatabaseUnavailable

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Meeting database unavailable").font(.body.weight(.medium))
                Text("Recordings are still saved to disk. Titles, notes and checked items cannot be edited until the database opens; quit and reopen the app once it is fixed.")
                    .foregroundStyle(.secondary)
                Text(error.url.path).textSelection(.enabled)
                Text(error.reason).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reveal in Finder") { error.reveal() }
        }
        .font(.callout)
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}

extension DatabaseUnavailable {
    @MainActor func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([existingLocation])
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

struct RecordingStatus: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(recorder.isPaused ? Color.secondary : .red).frame(width: 6, height: 6)
            Text(recorder.isRecording ? recorder.statusText : "Adding to meeting\u{2026}").monospacedDigit()
        }
    }
}

struct ContinueButton: View {
    @ObservedObject var recorder: Recorder
    let entry: RecordingEntry

    var body: some View {
        Button { Task { await recorder.start(continuing: entry.audio) } } label: {
            Label("Continue Recording", systemImage: "record.circle").labelStyle(.titleAndIcon)
        }
        .disabled(recorder.isBusy)
        .help("Record more of this meeting; it is added to the end of the same recording")
    }
}

struct ChatCommand: View {
    var body: some View {
        Button("Chat") { ChatWindow.shared.show() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

struct ExportCommand: View {
    @ObservedObject var library: RecordingLibrary

    var body: some View {
        Button("Export as Markdown\u{2026}") { library.selected.map(library.exportMarkdown) }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(library.selected?.inProgress ?? true)
    }
}
