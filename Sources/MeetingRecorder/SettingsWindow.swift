import AppKit
import Combine
import Speech
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private let models = SpeechModels()
    private lazy var window = AppWindow { [models] in Self.makeWindow(SettingsView(models: models)) }

    func show() {
        models.refresh()
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

struct SettingsView: View {
    @ObservedObject var models: SpeechModels
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
            section("Summaries", footer: nil) {
                row("Apple Intelligence", detail: models.summaryReason?.sentence ?? "Ready \u{2014} meetings are summarised on this Mac") {
                    if let reason = models.summaryReason, SummaryNotice(reason).showsSettings {
                        Button("Open Settings") { Permissions.openAppleIntelligenceSettings() }
                    } else if models.summaryReason == nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(poll) { _ in models.refresh() }
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
