import AppKit
import Combine
import Speech
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private let models = SpeechModels()
    private let whisper = WhisperModels()
    let speakers = SpeakerRecognitionModels()
    private lazy var window = AppWindow { [models, whisper, speakers] in
        Self.makeWindow(SettingsView(models: models, whisper: whisper, speakers: speakers))
    }

    func show() {
        models.refresh()
        whisper.refresh()
        speakers.refresh()
        window.show()
    }

    static func makeWindow(_ view: SettingsView) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        return window
    }
}

/// The on-device speech model of each meeting language, and whether Apple Intelligence can summarise.
@MainActor
final class SpeechModels: ObservableObject {
    @Published var statuses: [MeetingLanguage: SpeechModelStatus] = [:]
    @Published private(set) var reserved: Set<String> = []
    @Published private(set) var summaryReason: SummaryUnavailable?
    private var downloads: [MeetingLanguage: AnyCancellable] = [:]

    func status(of language: MeetingLanguage) -> SpeechModelStatus { statuses[language] ?? .checking }

    func isReserved(_ language: MeetingLanguage) -> Bool { reserved.contains(language.rawValue) }

    func refresh() {
        summaryReason = Summarizer.unavailableReason(for: .current)
        Task {
            reserved = Set(await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) })
            for language in MeetingLanguage.allCases {
                var status = SpeechModelStatus.unsupported
                if let model = await SpeechModel.make(for: language) {
                    status = SpeechModelStatus(await AssetInventory.status(forModules: [model.module]))
                }
                if downloads[language] == nil { statuses[language] = status }
            }
        }
    }

    func download(_ language: MeetingLanguage) {
        statuses[language] = .downloading(nil)
        downloads[language] = AnyCancellable {}
        Task {
            do {
                guard let model = await SpeechModel.make(for: language),
                      let request = try await AssetInventory.assetInstallationRequest(supporting: [model.module]) else {
                    downloads[language] = nil
                    return refresh()
                }
                downloads[language] = request.progress.publisher(for: \.fractionCompleted)
                    .receive(on: DispatchQueue.main)
                    .sink { self.statuses[language] = .downloading($0) }
                try await request.downloadAndInstall()
                downloads[language] = nil
                refresh()
            } catch {
                downloads[language] = nil
                statuses[language] = .failed(error.localizedDescription)
            }
        }
    }

    func remove(_ language: MeetingLanguage) {
        Task {
            await AssetInventory.release(reservedLocale: language.locale)
            refresh()
        }
    }
}

/// The downloaded Whisper models, and the downloads in progress.
@MainActor
final class WhisperModels: ObservableObject {
    @Published var statuses: [WhisperModel: SpeechModelStatus] = [:]
    private var downloads: [WhisperModel: (task: URLSessionDownloadTask, progress: AnyCancellable)] = [:]

    var installed: [WhisperModel] { WhisperModel.all.filter { status(of: $0) == .installed } }

    func status(of model: WhisperModel) -> SpeechModelStatus { statuses[model] ?? .notDownloaded }

    func refresh() {
        for model in WhisperModel.all where downloads[model] == nil {
            if model.isInstalled() {
                statuses[model] = .installed
            } else if case .failed = statuses[model] {
                continue
            } else {
                statuses[model] = .notDownloaded
            }
        }
    }

    func download(_ model: WhisperModel) {
        statuses[model] = .downloading(0)
        let task = URLSession.shared.downloadTask(with: model.remoteURL) { [weak self] file, response, error in
            let result = Result { try Self.install(model, file: file, response: response, error: error) }
            Task { @MainActor in self?.finish(model, result) }
        }
        let progress = task.progress.publisher(for: \.fractionCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fraction in
                if self?.downloads[model] != nil { self?.statuses[model] = .downloading(fraction) }
            }
        downloads[model] = (task, progress)
        task.resume()
    }

    func cancel(_ model: WhisperModel) {
        downloads[model]?.task.cancel()
    }

    func remove(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: model.url())
        statuses[model] = .notDownloaded
    }

    private func finish(_ model: WhisperModel, _ result: Result<Void, Error>) {
        downloads[model] = nil
        switch result {
        case .success: statuses[model] = .installed
        case .failure(let error as URLError) where error.code == .cancelled: statuses[model] = .notDownloaded
        case .failure(let error): statuses[model] = .failed(error.localizedDescription)
        }
    }

    /// Moves a finished download into the models folder once it is the expected file.
    private nonisolated static func install(_ model: WhisperModel, file: URL?, response: URLResponse?, error: Error?) throws {
        if let error { throw error }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw WhisperModelError.http(status) }
        guard let file else { throw URLError(.cannotOpenFile) }
        try model.verify(file)
        try FileManager.default.createDirectory(at: AppPaths.models, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: model.url())
        try FileManager.default.moveItem(at: file, to: model.url())
    }
}

/// The speaker recognition models, their download, and the voices recognised across meetings.
@MainActor
final class SpeakerRecognitionModels: ObservableObject {
    @Published var status = SpeechModelStatus.notDownloaded
    @Published var voices: [KnownVoice] = []
    var store: MeetingStore?
    private var download: Task<Void, Never>?

    func refresh() {
        voices = (try? store?.knownVoices()) ?? voices
        guard download == nil else { return }
        if !Diarizer.isAvailable {
            status = .unsupported
        } else if SpeakerModel.isInstalled() {
            status = .installed
        } else if case .failed = status {
            return
        } else {
            status = .notDownloaded
        }
    }

    func startDownload() {
        status = .downloading(0)
        download = Task {
            do {
                try await Diarizer.download { fraction in
                    Task { @MainActor in if self.download != nil { self.status = .downloading(fraction) } }
                }
                status = .installed
            } catch {
                status = Task.isCancelled ? .notDownloaded : .failed(error.localizedDescription)
            }
            download = nil
        }
    }

    func cancel() { download?.cancel() }

    func remove() {
        SpeakerModel.remove()
        status = .notDownloaded
    }

    func delete(_ voice: KnownVoice) {
        try? store?.deleteKnownVoice(voice.id)
        voices.removeAll { $0.id == voice.id }
    }
}

struct SettingsView: View {
    @ObservedObject var models: SpeechModels
    @ObservedObject var whisper: WhisperModels
    @ObservedObject var speakers: SpeakerRecognitionModels
    @AppStorage(MeetingLanguage.storageKey) private var language = MeetingLanguage.swedish

    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Meeting language", footer: "New recordings are transcribed and summarised in this language.") {
                row("Default language") {
                    Picker("Default language", selection: $language) {
                        ForEach(MeetingLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            section("Speech models", footer: "Transcription runs on this Mac with Apple\u{2019}s speech models. Nothing is uploaded.") {
                ForEach(Array(MeetingLanguage.allCases.enumerated()), id: \.element) { index, language in
                    if index > 0 { Divider().padding(.leading, 14) }
                    speechRow(language)
                }
            }
            section("Transcription", footer: nil) {
                ForEach(Array(TranscriptionEngine.whisperLanguages.enumerated()), id: \.element) { index, language in
                    if index > 0 { Divider().padding(.leading, 14) }
                    row("Transcribe \(language.displayName) with") {
                        EnginePicker(language: language, installed: whisper.installed)
                    }
                }
            }
            ForEach(WhisperModel.families, id: \.self) { family in
                section(family.name, footer: family.about) {
                    ForEach(Array(WhisperModel.all.filter { $0.family == family }.enumerated()), id: \.element) { index, model in
                        if index > 0 { Divider().padding(.leading, 14) }
                        whisperRow(model)
                    }
                }
            }
            section(SpeakerModel.name, footer: "Tells the other participants apart as Speaker 1, Speaker 2, \u{2026} on this Mac "
                    + "with FluidAudio\u{2019}s pyannote models, downloaded once from Hugging Face. Click a speaker in a "
                    + "transcript to name them; named voices are recognised in later meetings.") {
                modelRow("Speaker models", size: SpeakerModel.sizeText, status: speakers.status, download: speakers.startDownload,
                         cancel: speakers.cancel, remove: speakers.remove)
            }
            section("Known voices", footer: nil) {
                if speakers.voices.isEmpty {
                    row("No voices yet", detail: "Name a speaker in a transcript to remember their voice") {}
                }
                ForEach(Array(speakers.voices.enumerated()), id: \.element.id) { index, voice in
                    if index > 0 { Divider().padding(.leading, 14) }
                    row(voice.name, detail: "Updated \(voice.updated.formatted(date: .abbreviated, time: .omitted))") {
                        Button { speakers.delete(voice) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Forget this voice")
                    }
                }
            }
            section("Summaries", footer: nil) {
                row("Apple Intelligence", detail: models.summaryReason?.sentence ?? "Ready \u{2014} meetings are summarised on this Mac") {
                    if let reason = models.summaryReason, let settings = SummaryNotice(reason).settings {
                        Button(settings.title) { Permissions.open(settings) }
                    } else if models.summaryReason == nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(poll) { _ in
            models.refresh()
            whisper.refresh()
            speakers.refresh()
        }
        .onChange(of: language) { models.refresh() }
    }

    private func speechRow(_ language: MeetingLanguage) -> some View {
        let status = models.status(of: language)
        return row(language.displayName, detail: status.text) {
            switch status {
            case .downloading(let fraction):
                ProgressView(value: fraction ?? 0).frame(width: 120).opacity(fraction == nil ? 0.4 : 1)
            case .installed where models.isReserved(language):
                Button("Remove") { models.remove(language) }
                    .help("Lets macOS delete the model when no app needs it")
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            default:
                if status.canDownload { Button("Download") { models.download(language) } }
            }
        }
    }

    private func whisperRow(_ model: WhisperModel) -> some View {
        modelRow(model.name, size: model.sizeText, status: whisper.status(of: model), download: { whisper.download(model) },
                 cancel: { whisper.cancel(model) }, remove: { whisper.remove(model) })
    }

    /// A downloadable model: its size and status, with Download, a cancellable progress bar, or Remove.
    private func modelRow(_ title: String, size: String, status: SpeechModelStatus, download: @escaping () -> Void,
                          cancel: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        row(title, detail: status == .unsupported ? status.text : "\(size) \u{00B7} \(status.text)") {
            switch status {
            case .downloading(let fraction):
                ProgressView(value: fraction ?? 0).frame(width: 120)
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel the download")
            case .installed:
                Button("Remove", action: remove)
            case .unsupported:
                EmptyView()
            default:
                Button("Download", action: download)
            }
        }
    }

    private func section<Content: View>(_ title: String, footer: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<Trailing: View>(_ title: String, detail: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// Picks what transcribes a language: Apple, or a downloaded Whisper model that supports it.
private struct EnginePicker: View {
    let language: MeetingLanguage
    let installed: [WhisperModel]
    @AppStorage private var stored: String

    init(language: MeetingLanguage, installed: [WhisperModel]) {
        self.language = language
        self.installed = installed
        _stored = AppStorage(wrappedValue: TranscriptionEngine.appleValue, TranscriptionEngine.storageKey(for: language))
    }

    var body: some View {
        Picker("Transcribe \(language.displayName) with", selection: Binding(
            get: { TranscriptionEngine.selected(for: language, stored: stored, installed: installed) },
            set: { stored = $0.storedValue })) {
            ForEach(TranscriptionEngine.choices(for: language, installed: installed), id: \.self) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}
