import AppKit
import UniformTypeIdentifiers

struct ProcessingResult {
    let transcript: URL
    let summary: URL
    let title: String?
    let unavailable: SummaryUnavailable?
}

enum MeetingPipeline {
    static func run(_ audio: URL, language: MeetingLanguage,
                    progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult {
        let name = audio.lastPathComponent
        await progress(.transcribing)
        let transcript = try await Transcriber.transcribe(audio, language: language)
        let transcriptURL = ProcessingLogic.transcriptURL(for: audio)
        try ProcessingLogic.transcriptMarkdown(audioName: name, language: language, engine: transcript.engine,
                                               segments: transcript.segments)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let summaryURL = ProcessingLogic.summaryURL(for: audio)
        do {
            let summary = try await Summarizer.summarise(transcript.segments, language: language, progress: progress)
            try ProcessingLogic.summaryMarkdown(summary, audioName: name, language: language)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
            return ProcessingResult(transcript: transcriptURL, summary: summaryURL, title: summary.title, unavailable: nil)
        } catch let reason as SummaryUnavailable {
            try ProcessingLogic.unavailableMarkdown(reason, audioName: name, language: language)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
            return ProcessingResult(transcript: transcriptURL, summary: summaryURL, title: nil, unavailable: reason)
        }
    }

    static func runFromCommandLine(_ audio: URL, language: MeetingLanguage) -> Never {
        Task {
            do {
                let result = try await run(audio, language: language) { print($0.text(for: audio.lastPathComponent)) }
                print("Transcript: \(result.transcript.path)")
                print("Summary: \(result.summary.path)")
                if let reason = result.unavailable { print(reason.menuText) }
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
    @Published private(set) var latestSummary: URL?
    @Published private(set) var processing: URL?

    private let notifier: Notifier?
    private var queue: Task<Void, Never>?

    init(notifier: Notifier?) {
        self.notifier = notifier
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
        panel.directoryURL = Recorder.folder
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
            let result = try await MeetingPipeline.run(audio, language: .current) { [weak self] in
                self?.status = $0.text(for: name)
            }
            latestSummary = result.summary
            if let reason = result.unavailable {
                status = reason.menuText
                notifier?.postProcessed(title: "Transcript ready, no summary", body: reason.menuText, file: result.summary)
            } else {
                status = "Summary ready: \(name)"
                notifier?.postProcessed(title: "Meeting summary ready", body: result.title ?? name, file: result.summary)
            }
        } catch {
            status = nil
            errorMessage = "\(name): \(error.localizedDescription)"
            notifier?.postProcessed(title: "Meeting processing failed", body: errorMessage ?? name, file: nil)
        }
    }
}
