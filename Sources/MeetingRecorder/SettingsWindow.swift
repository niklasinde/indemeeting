import AppKit
import Combine
import Speech
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    @Published var anchor: SettingsAnchor?

    private let models = SpeechModels()
    private let whisper = WhisperModels()
    let speakers = SpeakerRecognitionModels()
    let projects = ActivityProjectsModel()
    var tracker: ActivityTracker?
    private lazy var window = AppWindow { [unowned self] in
        Self.makeWindow(SettingsView(models: models, whisper: whisper, speakers: speakers, projects: projects, tracker: tracker!))
    }

    func show(tab: SettingsTab? = nil, anchor: SettingsAnchor? = nil) {
        guard tracker != nil else { return }
        models.refresh()
        whisper.refresh()
        speakers.refresh()
        projects.refresh()
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey) }
        window.show()
        self.anchor = anchor
    }

    static func makeWindow(_ view: SettingsView) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        return window
    }
}

/// The languages new recordings may be in, shared by Settings and the menu so both show the same choice.
@MainActor
final class ListenedLanguages: ObservableObject {
    static let shared = ListenedLanguages()

    @Published private(set) var languages = MeetingLanguage.listened()

    var summary: String { languages.map(\.displayName).joined(separator: ", ") }

    /// Whether `language` is listened for; the last one cannot be turned off.
    func isListening(_ language: MeetingLanguage) -> Binding<Bool> {
        Binding(get: { self.languages.contains(language) }, set: { listening in
            let updated = listening ? self.languages + [language] : self.languages.filter { $0 != language }
            guard !updated.isEmpty else { return }
            MeetingLanguage.setListened(updated)
            self.languages = MeetingLanguage.listened()
        })
    }

    func isOnly(_ language: MeetingLanguage) -> Bool { languages == [language] }
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
    @Published var leftovers: [URL] = []
    private var downloads: [WhisperModel: (task: URLSessionDownloadTask, progress: AnyCancellable)] = [:]

    var installed: [WhisperModel] { WhisperModel.all.filter { status(of: $0) == .installed } }

    func status(of model: WhisperModel) -> SpeechModelStatus { statuses[model] ?? .notDownloaded }

    func refresh() {
        leftovers = WhisperModel.leftovers()
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

    func delete(_ leftover: URL) {
        try? FileManager.default.removeItem(at: leftover)
        leftovers = WhisperModel.leftovers()
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

enum SettingsTab: String, CaseIterable {
    case meetings = "Meetings"
    case activity = "Activity"
    case models = "Models"
    case iphone = "iPhone"

    static let storageKey = "settingsTab"
}

struct SettingsView: View {
    @ObservedObject var models: SpeechModels
    @ObservedObject var whisper: WhisperModels
    @ObservedObject var speakers: SpeakerRecognitionModels
    @ObservedObject var projects: ActivityProjectsModel
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject private var listened = ListenedLanguages.shared
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.meetings
    @AppStorage(TranscriptionEngine.beamSearchKey) private var beamSearch = true
    @AppStorage(TranscriptionEngine.quietKey) private var quiet = true
    @AppStorage(SummaryEngine.storageKey) private var summaryEngine = SummaryEngine.ollama

    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    /// Longer content scrolls, so the window fits a laptop screen.
    static let maxContentHeight: CGFloat = 760

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Settings", selection: $tab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            ScrollViewReader { proxy in
                ScrollView {
                    switch tab {
                    case .meetings: meetings
                    case .activity: ActivitySettingsView(tracker: tracker, projects: projects)
                    case .iphone: PhoneSettingsSection(model: .shared)
                    case .models:
                        ModelOverview(models: models, whisper: whisper, speakers: speakers, tracker: tracker) { anchor in
                            tab = .meetings
                            DispatchQueue.main.async { withAnimation { proxy.scrollTo(anchor, anchor: .top) } }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.maxContentHeight)
                .onReceive(SettingsWindow.shared.$anchor.compactMap { $0 }) { anchor in
                    SettingsWindow.shared.anchor = nil
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(anchor, anchor: .top) } }
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
            projects.refresh()
        }
        .onChange(of: listened.languages) { models.refresh() }
    }

    private var meetings: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Meeting languages", footer: "New recordings are transcribed and summarised in the language spoken, "
                    + "detected among the ones listened for. With one language on, every recording is in that language.") {
                ForEach(Array(MeetingLanguage.allCases.enumerated()), id: \.element) { index, language in
                    if index > 0 { Divider().padding(.leading, 14) }
                    row("Listen for \(language.displayName)") {
                        Toggle("Listen for \(language.displayName)", isOn: listened.isListening(language))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(listened.isOnly(language))
                    }
                }
            }
            section("Speech models", footer: "Transcription runs on this Mac with Apple\u{2019}s speech models. Nothing is uploaded.") {
                ForEach(Array(MeetingLanguage.allCases.enumerated()), id: \.element) { index, language in
                    if index > 0 { Divider().padding(.leading, 14) }
                    speechRow(language)
                }
            }
            section("Transcription", footer: "Apple needs no download but writes Swedish without punctuation. A Whisper model "
                    + "is more accurate and follows a meeting from one language to another.") {
                row("Transcribe with") { EnginePicker(installed: whisper.installed) }
                Divider().padding(.leading, 14)
                row("Higher accuracy", detail: "Beam search with Whisper, slower") {
                    Toggle("Higher accuracy", isOn: $beamSearch)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Divider().padding(.leading, 14)
                row("Quiet transcription", detail: "Whisper on fewer cores at low priority, slower but cooler") {
                    Toggle("Quiet transcription", isOn: $quiet)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            section("Summary", footer: "Ministral runs on this Mac through Ollama. When the chosen engine is missing or "
                    + "fails, the others take over.") {
                row("Summarise with") {
                    Picker("Summarise with", selection: $summaryEngine) {
                        ForEach(SummaryEngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            ForEach(WhisperModel.families, id: \.self) { family in
                section(family.name, footer: family.about) {
                    ForEach(Array(WhisperModel.all.filter { $0.family == family }.enumerated()), id: \.element) { index, model in
                        if index > 0 { Divider().padding(.leading, 14) }
                        whisperRow(model)
                    }
                }
                .id(family == WhisperModel.families.first ? SettingsAnchor.whisper : nil)
            }
            if !whisper.leftovers.isEmpty {
                section("Other model files", footer: "Models WorkTime no longer uses. Delete them to free up space.") {
                    ForEach(Array(whisper.leftovers.enumerated()), id: \.element) { index, file in
                        if index > 0 { Divider().padding(.leading, 14) }
                        row(file.deletingPathExtension().lastPathComponent, detail: Self.size(of: file)) {
                            Button("Delete") { whisper.delete(file) }
                        }
                    }
                }
            }
            section(SpeakerModel.name, footer: "Tells the other participants apart as Speaker 1, Speaker 2, \u{2026} on this Mac "
                    + "with FluidAudio\u{2019}s pyannote models, downloaded once from Hugging Face. Click a speaker in a "
                    + "transcript to name them; named voices are recognised in later meetings.") {
                modelRow("Speaker models", size: SpeakerModel.sizeText, status: speakers.status, download: speakers.startDownload,
                         cancel: speakers.cancel, remove: speakers.remove)
            }
            .id(SettingsAnchor.speakers)
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
            ChatSettingsSection()
            ClaudeAPISettingsSection()
        }
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
        modelRow(model.name, size: [model.sizeText, model.hint].compactMap { $0 }.joined(separator: " \u{00B7} "),
                 badge: model.recommended ? "Recommended" : nil, status: whisper.status(of: model),
                 download: { whisper.download(model) }, cancel: { whisper.cancel(model) }, remove: { whisper.remove(model) })
    }

    private static func size(of file: URL) -> String? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// A downloadable model: its size and status, with Download, a cancellable progress bar, or Remove.
    private func modelRow(_ title: String, size: String, badge: String? = nil, status: SpeechModelStatus,
                          download: @escaping () -> Void, cancel: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        SettingsRow(title, detail: status == .unsupported ? status.text : "\(size) \u{00B7} \(status.text)", badge: badge) {
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
        SettingsSection(title, footer: footer, content: content)
    }

    private func row<Trailing: View>(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        SettingsRow(title, detail: detail, trailing: trailing)
    }
}

/// A titled group of rows with an optional footer, as in System Settings.
struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
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

}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    var badge: String? = nil
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, badge: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.badge = badge
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// Picks what transcribes meetings: Apple, or a downloaded Whisper model.
private struct EnginePicker: View {
    let installed: [WhisperModel]
    @AppStorage(TranscriptionEngine.storageKey) private var stored: String?

    var body: some View {
        Picker("Transcribe with", selection: Binding(
            get: { TranscriptionEngine.selected(stored: stored ?? TranscriptionEngine.stored(), installed: installed) },
            set: { stored = $0.storedValue })) {
            ForEach(TranscriptionEngine.choices(installed: installed), id: \.self) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}
