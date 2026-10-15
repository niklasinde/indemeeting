import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class MainWindow {
    private let recorder: Recorder
    private let processor: MeetingProcessor
    private let library = RecordingLibrary()
    private let playback = AudioPlayback()

    private lazy var window: AppWindow = AppWindow(onClose: { [playback] in playback.pause() }) { [unowned self] in
        let controller = NSHostingController(rootView: MainView(
            recorder: recorder, processor: processor, library: library, playback: playback))
        if #available(macOS 14, *) { controller.sceneBridgingOptions = [.toolbars] }
        let window = NSWindow(contentViewController: controller)
        window.title = "Meeting Recorder"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 600))
        return window
    }

    init(recorder: Recorder, processor: MeetingProcessor) {
        self.recorder = recorder
        self.processor = processor
    }

    func show() {
        library.start()
        window.show()
    }
}

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [RecordingEntry] = []
    @Published var selection: URL?

    private let folder = Recorder.folder
    private var files: [FolderItem] = []
    private var durations: [String: TimeInterval] = [:]
    private var watcher: DispatchSourceFileSystemObject?

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
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        files = urls.map {
            FolderItem(name: $0.lastPathComponent,
                       created: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        rebuild()
        let missing = files.map(\.name).filter { LibraryLogic.isListed($0) && durations[$0] == nil }
        guard !missing.isEmpty else { return }
        let folder = folder
        Task.detached(priority: .utility) {
            let found = missing.compactMap { name in Self.duration(of: folder.appendingPathComponent(name)).map { (name, $0) } }
            await MainActor.run {
                self.durations.merge(found) { $1 }
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        recordings = LibraryLogic.recordings(in: folder, files: files, durations: durations)
    }

    nonisolated private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
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

    func load(_ url: URL?) {
        guard url != self.url else { return }
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
            List(library.recordings, selection: $library.selection) { RecordingRow(entry: $0) }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            if let entry = library.recordings.first(where: { $0.id == library.selection }) {
                RecordingDetail(entry: entry, processor: processor, playback: playback, library: library)
            } else {
                Text(library.recordings.isEmpty ? "No recordings yet" : "Select a recording")
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { recordButton }
        }
        .frame(minWidth: 720, minHeight: 440)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            library.refresh()
        }
    }

    @ViewBuilder private var recordButton: some View {
        if recorder.isRecording {
            Button {
                Task {
                    if let url = await processor.finishRecording(recorder, reveal: false) { library.selection = url }
                }
            } label: {
                Label("Stop Recording  \(recorder.elapsedText)", systemImage: "stop.circle.fill")
                    .monospacedDigit()
            }
            .tint(.red)
        } else {
            Button { Task { await recorder.start() } } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([recorder.notice, recorder.errorMessage, processor.errorMessage].compactMap { $0 }, id: \.self) {
                Text($0).font(.caption).foregroundStyle(.secondary)
            }
            if !Permissions.allGranted {
                Label("Some permissions are missing", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                Button("Open Setup\u{2026}") { OnboardingWindow.shared.show() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

struct RecordingRow: View {
    let entry: RecordingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
            HStack(spacing: 6) {
                if let duration = entry.duration { Text(LibraryLogic.durationText(duration)).monospacedDigit() }
                if entry.hasTranscript { Image(systemName: "text.quote").help("Transcript") }
                if entry.hasSummary { Image(systemName: "list.bullet.rectangle").help("Summary") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

@MainActor
final class DetailState: ObservableObject {
    enum Section: String, CaseIterable {
        case summary = "Summary"
        case transcript = "Transcript"
    }

    @Published var section = Section.summary
    @Published var summary: String?
    @Published var transcript: String?
    @Published var confirmingDelete = false
}

struct RecordingDetail: View {

    private struct ContentKey: Hashable {
        let entry: RecordingEntry
        let processing: Bool
    }

    let entry: RecordingEntry
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var playback: AudioPlayback
    let library: RecordingLibrary

    @StateObject private var state = DetailState()

    private var isProcessing: Bool { processor.processing == entry.audio }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                    .font(.title2.bold())
                Text(entry.audio.lastPathComponent).foregroundStyle(.secondary)
            }
            player
            actions
            Picker("", selection: $state.section) {
                ForEach(DetailState.Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                MarkdownText(markdown: (state.section == .summary ? state.summary : state.transcript) ?? placeholder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(20)
        .task(id: entry.audio) { playback.load(entry.audio) }
        .task(id: ContentKey(entry: entry, processing: isProcessing)) {
            state.summary = try? String(contentsOf: entry.summary, encoding: .utf8)
            state.transcript = try? String(contentsOf: entry.transcript, encoding: .utf8)
        }
        .confirmationDialog("Move \(entry.audio.lastPathComponent) to the Trash?", isPresented: $state.confirmingDelete) {
            Button("Move to Trash", role: .destructive) { delete() }
        } message: {
            Text(entry.files.count > 1 ? "Its transcript and summary are moved too." : "")
        }
    }

    private var placeholder: String {
        isProcessing ? "" : "No \(state.section.rawValue.lowercased()) yet. Choose Transcribe & summarise."
    }

    private var player: some View {
        HStack(spacing: 10) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .disabled(playback.duration == 0)
            Slider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 0.1))
            Text("\(LibraryLogic.durationText(playback.position)) / \(LibraryLogic.durationText(playback.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.audio]) }
            Button("Transcribe & summarise") { processor.process(entry.audio) }
                .disabled(isProcessing)
            if isProcessing {
                ProgressView().controlSize(.small)
                Text(processor.status ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Delete\u{2026}", role: .destructive) { state.confirmingDelete = true }
        }
    }

    private func delete() {
        if playback.url == entry.audio { playback.load(nil) }
        Task {
            do {
                _ = try await NSWorkspace.shared.recycle(entry.files)
            } catch {
                NSAlert(error: error).runModal()
            }
            library.refresh()
        }
    }
}

struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(LibraryLogic.markdownBlocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(level == 1 ? .title2.bold() : .headline).padding(.top, level == 1 ? 0 : 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline) { Text("\u{2022}"); inline(text) }
                case .task(let text):
                    HStack(alignment: .firstTextBaseline) { Image(systemName: "square"); inline(text) }
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}
