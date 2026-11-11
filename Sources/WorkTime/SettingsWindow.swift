import AppKit
import Combine
import Speech
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    @Published var anchor: SettingsAnchor?

    private let models = SpeechModels()
    let whisper = WhisperModels()
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
        LocalLLMModels.shared.refresh()
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

/// Downloaded model files of one catalogue, and the downloads in progress.
@MainActor
class ModelDownloads<Model: DownloadableModel>: ObservableObject {
    @Published var statuses: [Model: SpeechModelStatus] = [:]
    private let catalogue: [Model]
    private var downloads: [Model: (task: URLSessionDownloadTask, progress: AnyCancellable)] = [:]

    init(_ catalogue: [Model]) { self.catalogue = catalogue }

    var installed: [Model] { catalogue.filter { status(of: $0) == .installed } }

    func status(of model: Model) -> SpeechModelStatus { statuses[model] ?? .notDownloaded }

    func isDownloading(_ model: Model) -> Bool { downloads[model] != nil }

    func refresh() {
        for model in catalogue where downloads[model] == nil {
            if model.isInstalled() {
                statuses[model] = .installed
            } else if case .failed = statuses[model] {
                continue
            } else {
                statuses[model] = .notDownloaded
            }
        }
    }

    func download(_ model: Model) {
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

    func cancel(_ model: Model) {
        downloads[model]?.task.cancel()
    }

    func remove(_ model: Model) {
        try? FileManager.default.removeItem(at: model.url())
        statuses[model] = .notDownloaded
    }

    /// Called once a download is in place.
    func didInstall(_ model: Model) {}

    private func finish(_ model: Model, _ result: Result<Void, Error>) {
        downloads[model] = nil
        switch result {
        case .success:
            statuses[model] = .installed
            didInstall(model)
        case .failure(let error as URLError) where error.code == .cancelled: statuses[model] = .notDownloaded
        case .failure(let error): statuses[model] = .failed(error.localizedDescription)
        }
    }

    /// Moves a finished download into the models folder once it is the expected file.
    private nonisolated static func install(_ model: Model, file: URL?, response: URLResponse?, error: Error?) throws {
        if let error { throw error }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw WhisperModelError.http(status) }
        guard let file else { throw URLError(.cannotOpenFile) }
        try model.verify(file)
        try FileManager.default.createDirectory(at: AppPaths.models, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: model.url())
        try FileManager.default.moveItem(at: file, to: model.url())
    }
}

/// The downloaded Whisper models, and the downloads in progress.
@MainActor
final class WhisperModels: ModelDownloads<WhisperModel> {
    @Published var leftovers: [URL] = []

    init() { super.init(WhisperModel.all) }

    override func refresh() {
        leftovers = WhisperModel.leftovers()
        super.refresh()
    }

    override func didInstall(_ model: WhisperModel) { fetchVADIfNeeded() }

    /// Fetches the small voice activity model once a Whisper model is downloaded, so Whisper skips silence.
    func fetchVADIfNeeded() {
        guard !isDownloading(.vad), WhisperModel.needsVAD() else { return }
        download(.vad)
    }

    func delete(_ leftover: URL) {
        try? FileManager.default.removeItem(at: leftover)
        leftovers = WhisperModel.leftovers()
    }
}

/// The local language models, their downloads, and whether one is loaded.
@MainActor
final class LocalLLMModels: ModelDownloads<LocalLLMModel> {
    static let shared = LocalLLMModels()

    @Published private(set) var loaded = false

    init() { super.init(LocalLLMModel.all) }

    override func refresh() {
        loaded = LocalLLM.shared.isLoaded
        super.refresh()
    }

    override func remove(_ model: LocalLLMModel) {
        LocalLLM.shared.unload()
        super.remove(model)
    }

    var state: ModelState {
        if loaded { return .loaded }
        if !installed.isEmpty { return .ready }
        return LocalLLMModel.all.contains { status(of: $0).isDownloading } ? .downloading : .notDownloaded
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
    case privacy = "Privacy"
    case projects = "Projects"
    case notchBar = "Notch bar"
    case gitHub = "GitHub"
    case jira = "Jira"
    case slack = "Slack"
    case models = "Models"
    case agent = "Agent"
    case iphone = "iPhone"

    static let storageKey = "settingsTab"

    var title: String { self == .notchBar ? "Top notch bar" : rawValue }

    var symbol: String {
        switch self {
        case .meetings: return "waveform"
        case .activity: return "chart.bar.fill"
        case .privacy: return "hand.raised.fill"
        case .projects: return "folder.fill"
        case .notchBar: return "rectangle.topthird.inset.filled"
        case .gitHub: return "chevron.left.forwardslash.chevron.right"
        case .jira: return "ticket.fill"
        case .slack: return "number"
        case .models: return "cpu.fill"
        case .agent: return "sparkles"
        case .iphone: return "iphone"
        }
    }

    var tint: Color {
        switch self {
        case .meetings: return .red
        case .activity: return .orange
        case .privacy: return .blue
        case .projects: return .cyan
        case .notchBar: return .gray
        case .gitHub: return Color(white: 0.3)
        case .jira: return .teal
        case .slack: return .purple
        case .models: return .indigo
        case .agent: return .pink
        case .iphone: return .green
        }
    }
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
    @AppStorage(SummaryEngine.storageKey) private var summaryEngine = SummaryEngine.ministral
    @ObservedObject private var ministral = LocalLLMModels.shared
    @AppStorage(AudioRetention.developerModeKey) private var developerMode = false
    @AppStorage(LiveTranscriptLogic.enabledKey) private var liveTranscription = true
    @AppStorage(LiveModel.storageKey) private var liveModel = LiveModel.best
    @State private var target: SettingsAnchor?

    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    /// Pages scroll, so the window fits a laptop screen.
    static let size = CGSize(width: 760, height: 640)

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, id: \.self, selection: Binding(get: { tab }, set: { if let tab = $0 { self.tab = tab } })) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(tab.tint.gradient))
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(tab.title).font(.title2.bold()).id(tab)
                        page { reveal($0, proxy: proxy) }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: tab) { scroll(proxy) }
                .onReceive(SettingsWindow.shared.$anchor.compactMap { $0 }) { anchor in
                    SettingsWindow.shared.anchor = nil
                    reveal(anchor, proxy: proxy)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onReceive(poll) { _ in
            models.refresh()
            whisper.refresh()
            ministral.refresh()
            speakers.refresh()
            projects.refresh()
        }
        .onChange(of: listened.languages) { models.refresh() }
    }

    @ViewBuilder private func page(show: @escaping (SettingsAnchor) -> Void) -> some View {
        switch tab {
        case .meetings: meetings
        case .activity: ActivitySettingsView(tracker: tracker, projects: projects)
        case .privacy: PrivacySettingsView(tracker: tracker, projects: projects)
        case .projects: ProjectsSettingsView(projects: projects)
        case .notchBar: NotchBarSettingsSection(model: .shared)
        case .gitHub: GitHubSettingsSection(model: .shared)
        case .jira: JiraSettingsSection(model: .shared).id(SettingsAnchor.jira)
        case .slack: SlackSettingsSection(model: .shared).id(SettingsAnchor.slack)
        case .models: ModelOverview(models: models, whisper: whisper, speakers: speakers, tracker: tracker, show: show)
        case .agent: AgentSettingsSection(store: .shared)
        case .iphone: PhoneSettingsSection(model: .shared)
        }
    }

    /// Opens the page of `anchor` and scrolls to it once the page is shown.
    private func reveal(_ anchor: SettingsAnchor, proxy: ScrollViewProxy) {
        target = anchor
        if tab == anchor.tab { scroll(proxy) } else { tab = anchor.tab }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        let anchor = target
        target = nil
        DispatchQueue.main.async {
            if let anchor {
                withAnimation { proxy.scrollTo(anchor, anchor: .top) }
            } else {
                proxy.scrollTo(tab, anchor: .top)
            }
        }
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
                Divider().padding(.leading, 14)
                row("Live transcription", detail: "A preview while recording, kept as an earlier version of the transcript") {
                    Toggle("Live transcription", isOn: $liveTranscription)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Divider().padding(.leading, 14)
                row("Live model", detail: "Best replaces Apple\u{2019}s text with Whisper\u{2019}s as it goes; Light is cooler") {
                    Picker("Live model", selection: $liveModel) {
                        ForEach(LiveModel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!liveTranscription)
                }
            }
            section("Summary", footer: "Ministral runs on this Mac once it is downloaded below. When the chosen engine is "
                    + "missing or fails, the others take over.") {
                row("Summarise with") {
                    Picker("Summarise with", selection: Binding(get: { SummaryEngine.stored() }, set: { summaryEngine = $0 })) {
                        ForEach(SummaryEngine.offered(developer: developerMode), id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            section("Ministral", footer: "Mistral\u{2019}s small language model, downloaded from Hugging Face and run on this Mac "
                    + "with llama.cpp. It summarises meetings and picks the model for Auto in the Agent window. It is loaded when "
                    + "needed and let go after three idle minutes.") {
                ForEach(Array(LocalLLMModel.all.enumerated()), id: \.element) { index, model in
                    if index > 0 { Divider().padding(.leading, 14) }
                    modelRow(model.name, size: [model.sizeText, model.hint].compactMap { $0 }.joined(separator: " \u{00B7} "),
                             badge: ministral.loaded && ministral.status(of: model) == .installed ? "Loaded" : nil,
                             status: LocalLLM.isCompiled ? ministral.status(of: model) : .unsupported,
                             download: { ministral.download(model) }, cancel: { ministral.cancel(model) }, remove: { ministral.remove(model) })
                }
            }
            .id(SettingsAnchor.ministral)
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
            section("Developer", footer: "A new recording\u{2019}s audio is deleted from this Mac for good once its transcript "
                    + "and summary are saved. Recordings made in developer mode keep their audio, also after it is turned off.") {
                row("Developer mode", detail: "Keep the audio of new recordings") {
                    Toggle("Developer mode", isOn: $developerMode)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
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
