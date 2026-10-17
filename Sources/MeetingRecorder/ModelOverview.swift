import SwiftUI

/// Where a downloadable model's row is in Settings › Meetings, so the overview can scroll to it.
enum SettingsAnchor: Hashable {
    case whisper
    case speakers
}

/// Which model does each step, whether it comes with macOS or is downloaded, and whether it is ready.
struct ModelOverview: View {
    @ObservedObject var models: SpeechModels
    @ObservedObject var whisper: WhisperModels
    @ObservedObject var speakers: SpeakerRecognitionModels
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject private var listened = ListenedLanguages.shared
    @AppStorage(TranscriptionEngine.storageKey(for: .swedish)) private var swedishEngine = TranscriptionEngine.appleValue
    let show: (SettingsAnchor) -> Void

    private enum Source {
        case builtIn
        case download

        var chip: Chip {
            self == .builtIn ? Chip(text: "Built into macOS", tint: .teal) : Chip(text: "Optional download", tint: .purple)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                FlowChips([Source.builtIn.chip]).fixedSize()
                Text("nothing to download")
                FlowChips([Source.download.chip]).fixedSize().padding(.leading, 8)
                Text("get it under Meetings")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            SettingsSection("Models", footer: "Everything runs on this Mac. Nothing is uploaded.") {
                step("Language detection", "Apple speech + NaturalLanguage", .builtIn, detail: "Scores each language you listen for",
                     state: listened.languages.count > 1 ? speechState : .off)
                Divider().padding(.leading, 14)
                step("Transcription", "Apple speech", .builtIn, detail: "About 400 MB per language \u{00B7} the default", state: speechState)
                Divider().padding(.leading, 14)
                step("Transcription", "KB-Whisper", .download, detail: whisperDetail, state: whisperState, anchor: .whisper)
                Divider().padding(.leading, 14)
                step("Speaker recognition", "FluidAudio", .download, detail: "\(SpeakerModel.sizeText) \u{00B7} tells the other participants apart",
                     state: ModelState(speakers.status), anchor: .speakers)
                Divider().padding(.leading, 14)
                step("Summaries", "Apple Intelligence", .builtIn, detail: models.summaryReason?.sentence ?? "AFM 3 Core, about 7 GB",
                     state: ModelState(summary: models.summaryReason))
                Divider().padding(.leading, 14)
                step("Activity categories", "Apple Intelligence", .builtIn, detail: "The same model, for content tagging", state: categoryState)
            }
        }
    }

    private var speechState: ModelState { ModelState(all: listened.languages.map(models.status(of:))) }

    private var whisperState: ModelState {
        if !whisper.installed.isEmpty { return .ready }
        return WhisperModel.all.contains { whisper.status(of: $0).isDownloading } ? .downloading : .notDownloaded
    }

    private var whisperDetail: String {
        let sizes = WhisperModel.all.map(\.bytes)
        let range = [sizes.min() ?? 0, sizes.max() ?? 0].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            .joined(separator: "\u{2013}")
        let engine = TranscriptionEngine.selected(for: .swedish, stored: swedishEngine, installed: whisper.installed)
        if engine != .apple { return "\(range) \u{00B7} \(engine.displayName) transcribes Svenska" }
        return "\(range) \u{00B7} " + (whisper.installed.isEmpty ? "Swedish" : "Apple still transcribes Svenska")
    }

    private var categoryState: ModelState {
        guard ActivityClassifier.isAvailable else { return .unavailable }
        return tracker.settings.enabled && tracker.settings.classify ? .ready : .off
    }

    private func step(_ title: String, _ model: String, _ source: Source, detail: String, state: ModelState,
                      anchor: SettingsAnchor? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(model)
                    FlowChips([source.chip]).fixedSize()
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let anchor {
                Button { show(anchor) } label: { status(state, link: true) }
                    .buttonStyle(.plain)
                    .help("Show in Meetings")
            } else {
                status(state, link: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func status(_ state: ModelState, link: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color(state)).frame(width: 7, height: 7)
            Text(state.text)
            if link { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }

    private func color(_ state: ModelState) -> Color {
        switch state {
        case .ready: return .green
        case .downloading, .checking: return .orange
        case .notDownloaded, .off: return .secondary.opacity(0.5)
        case .unavailable: return .red
        }
    }
}
