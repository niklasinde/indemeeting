import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class MainWindow {
    private let library = RecordingLibrary()
    private let playback = AudioPlayback()
    private let window: AppWindow

    init(recorder: Recorder, processor: MeetingProcessor) {
        let view = MainView(recorder: recorder, processor: processor, library: library, playback: playback)
        window = AppWindow(onClose: { [playback] in playback.pause() }) { Self.makeWindow(view) }
    }

    func show() {
        library.start()
        window.show()
    }

    static func makeWindow(_ view: MainView) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        if #available(macOS 14, *) { controller.sceneBridgingOptions = [.toolbars] }
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

@MainActor
final class RecordingLibrary: ObservableObject {
    private struct CachedText {
        let modified: Date
        let text: String
    }

    private static let indexedSuffixes = [".summary.md", ".transcript.md", ".meta.json"]

    @Published private(set) var recordings: [RecordingEntry] = []
    @Published var selection: URL?
    @Published var query = ""
    @Published var tab = DetailTab.summary
    @Published var confirmingDelete = false
    /// The meeting being recorded, listed before its file exists.
    @Published var recording: URL? { didSet { if oldValue != recording { rebuild() } } }
    @Published private var texts: [String: CachedText] = [:]

    let folder: URL
    private var files: [FolderItem] = []
    private var durations: [String: (modified: Date, seconds: TimeInterval)] = [:]
    private var watcher: DispatchSourceFileSystemObject?

    init(folder: URL = Recorder.folder) {
        self.folder = folder
    }

    var selected: RecordingEntry? { recordings.first { $0.id == selection } }

    var visibleRecordings: [RecordingEntry] {
        recordings.filter { LibraryLogic.matches(query, in: [title(of: $0), text(of: $0.transcript) ?? ""]) }
    }

    func start() {
        defer { refresh() }
        guard watcher == nil else { return }
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
        texts = Dictionary(uniqueKeysWithValues: values.compactMap { url, values in
            let name = url.lastPathComponent
            guard Self.indexedSuffixes.contains(where: name.hasSuffix) else { return nil }
            let modified = values?.contentModificationDate ?? .distantPast
            if let cached = texts[name], cached.modified == modified { return (name, cached) }
            return (name, CachedText(modified: modified, text: (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        })
        rebuild()
        let missing = files.map(\.name).filter { LibraryLogic.isListed($0) && durations[$0]?.modified != modified[$0] }
        guard !missing.isEmpty else { return }
        let folder = folder
        Task.detached(priority: .utility) {
            let found = missing.compactMap { name in
                (try? AudioFiles.duration(of: folder.appendingPathComponent(name))).map { (name, (modified[name] ?? .distantPast, $0)) }
            }
            await MainActor.run {
                self.durations.merge(found) { $1 }
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let listed = LibraryLogic.recordings(in: folder, files: files, durations: durations.mapValues(\.seconds))
        recordings = LibraryLogic.withRecording(recording, in: listed, now: Date())
    }

    func text(of url: URL) -> String? { texts[url.lastPathComponent]?.text }

    func meta(of entry: RecordingEntry) -> MeetingMeta { MeetingMeta.decode(text(of: entry.meta).map { Data($0.utf8) }) }

    func summary(of entry: RecordingEntry) -> ParsedSummary? {
        text(of: entry.summary).map { LibraryLogic.parseSummary($0, meta: meta(of: entry)) }
    }

    func title(of entry: RecordingEntry) -> String {
        LibraryLogic.title(override: meta(of: entry).title, aiTitle: summary(of: entry)?.title)
    }

    func language(of entry: RecordingEntry) -> MeetingLanguage {
        [entry.transcript, entry.summary].lazy.compactMap { self.text(of: $0).flatMap(LibraryLogic.language(in:)) }.first
            ?? .current
    }

    func updateMeta(of entry: RecordingEntry, _ change: (inout MeetingMeta) -> Void) {
        var meta = meta(of: entry)
        change(&meta)
        let data = meta.encoded()
        do {
            try data.write(to: entry.meta, options: .atomic)
            texts[entry.meta.lastPathComponent] = CachedText(modified: .distantPast, text: String(decoding: data, as: UTF8.self))
        } catch {
            NSAlert(error: error).runModal()
        }
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
                _ = try await NSWorkspace.shared.recycle(entry.files)
            } catch {
                NSAlert(error: error).runModal()
            }
            refresh()
        }
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
    let playback: AudioPlayback

    var body: some View {
        NavigationSplitView {
            Sidebar(recorder: recorder, processor: processor, library: library) { newMeeting() }
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            if let entry = library.selected {
                RecordingDetail(entry: entry, recorder: recorder, processor: processor, library: library, playback: playback)
                    .id(entry.id)
            } else {
                Text(library.recordings.isEmpty ? "No recordings yet" : "Select a meeting")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("Its transcript, summary and notes are moved too.")
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
                Divider()
                Button("Delete\u{2026}", role: .destructive) { library.confirmingDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .disabled(library.selected?.inProgress ?? true)
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

    private func row(_ entry: RecordingEntry, group: DateGroup) -> some View {
        Button { library.selection = entry.id } label: {
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
                .fill(library.selection == entry.id ? Color.primary.opacity(0.08) : .clear))
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
