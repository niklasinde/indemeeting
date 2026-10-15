import AppKit
import UniformTypeIdentifiers

struct ProcessingResult {
    let title: String?
    let unavailable: SummaryUnavailable?
}

enum MeetingPipeline {
    /// Transcribes and summarises `audio` into the store. A failure is recorded on the meeting and rethrown.
    static func run(_ audio: URL, language: MeetingLanguage, store: MeetingStore,
                    progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult {
        let name = audio.lastPathComponent
        do {
            await progress(.transcribing)
            let transcript = try await Transcriber.transcribe(audio, language: language)
            try store.saveTranscript(name, segments: transcript.segments, language: language, engine: transcript.engine)
            do {
                let summary = try await Summarizer.summarise(transcript.segments, language: language, progress: progress)
                try store.saveSummary(name, ParsedSummary(summary))
                return ProcessingResult(title: summary.title, unavailable: nil)
            } catch let reason as SummaryUnavailable {
                try store.saveSummary(name, ParsedSummary(unavailable: reason.message))
                return ProcessingResult(title: nil, unavailable: reason)
            }
        } catch {
            try? store.setFailed(name, message: error.localizedDescription)
            throw error
        }
    }

    static func runFromCommandLine(_ audio: URL, language: MeetingLanguage, store: MeetingStore) -> Never {
        Task {
            do {
                let result = try await run(audio, language: language, store: store) { print($0.text(for: audio.lastPathComponent)) }
                print("Saved to \(AppPaths.database.path)")
                print(result.unavailable?.menuText ?? "Summary: \(result.title ?? "")")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}

@MainActor
final class MeetingProcessor: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var errorMessage: String?
    /// The audio of the meeting processed last, for "Open summary".
    @Published private(set) var latestMeeting: URL?
    @Published private(set) var processing: URL?

    private let notifier: Notifier?
    private let store: MeetingStore
    private var queue: Task<Void, Never>?

    init(notifier: Notifier?, store: MeetingStore) {
        self.notifier = notifier
        self.store = store
    }

    func process(_ audio: URL) {
        let previous = queue
        queue = Task {
            await previous?.value
            await run(audio)
        }
    }

    @discardableResult
    func finishRecording(_ recorder: Recorder, reveal: Bool = true) async -> URL? {
        guard let url = await recorder.stop(reveal: reveal) else { return nil }
        process(url)
        return url
    }

    func chooseRecording() {
        let panel = NSOpenPanel()
        panel.title = "Transcribe & summarise a recording"
        panel.allowedContentTypes = [.audio]
        panel.directoryURL = AppPaths.recordings
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        process(url)
    }

    private func run(_ audio: URL) async {
        let name = audio.lastPathComponent
        errorMessage = nil
        processing = audio
        defer { processing = nil }
        do {
            let result = try await MeetingPipeline.run(audio, language: .current, store: store) { [weak self] in
                self?.status = $0.text(for: name)
            }
            latestMeeting = audio
            if let reason = result.unavailable {
                status = reason.menuText
                notifier?.postProcessed(title: "Transcript ready, no summary", body: reason.menuText, meeting: audio)
            } else {
                status = "Summary ready: \(name)"
                notifier?.postProcessed(title: "Meeting summary ready", body: result.title ?? name, meeting: audio)
            }
        } catch {
            status = nil
            errorMessage = "\(name): \(error.localizedDescription)"
            notifier?.postProcessed(title: "Meeting processing failed", body: errorMessage ?? name, meeting: audio)
        }
    }
}
