import AppKit
import os
import UniformTypeIdentifiers

struct ProcessingResult {
    var title: String?
    var unavailable: SummaryUnavailable?
    /// How many speakers "Recognise speakers" told apart, when that is all that ran.
    var speakers: Int?
}

enum MeetingPipeline {
    /// Transcribes and summarises `audio` into the store. A failure is recorded on the meeting and rethrown.
    static func run(_ audio: URL, language: MeetingLanguage, store: MeetingStore,
                    progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult {
        try await recordingFailure(of: audio, in: store) {
            await progress(.transcribing())
            let transcript = try await Transcriber.transcribeMeeting(audio, language: language) { fraction in
                Task { @MainActor in progress(.transcribing(progress: fraction)) }
            }
            let recognised = await recogniseSpeakers(transcript.segments, in: audio, store: store, progress: progress)
            try store.saveTranscript(audio.lastPathComponent, segments: recognised.segments, language: language,
                                     engine: transcript.engine, speakers: recognised.speakers)
            return try await summarise(audio, segments: recognised.segments, names: recognised.names, language: language,
                                       store: store, progress: progress)
        }
    }

    /// Tells the speakers of the stored transcript apart again without transcribing, or runs the whole pipeline when
    /// there is no transcript.
    static func recogniseSpeakers(_ audio: URL, store: MeetingStore,
                                  progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult {
        guard let content = try store.content(of: audio.lastPathComponent), content.meeting.transcribed else {
            return try await run(audio, language: .current, store: store, progress: progress)
        }
        return try await recordingFailure(of: audio, in: store) {
            await progress(.recognisingSpeakers())
            let recognised = try await Diarizer.recognise(content.segments, in: audio, known: try store.knownVoices()) { fraction in
                Task { @MainActor in progress(.recognisingSpeakers(progress: fraction)) }
            }
            let meeting = content.meeting
            try store.saveTranscript(meeting.audioFile, segments: recognised.segments, language: meeting.language ?? .current,
                                     engine: meeting.transcriptEngine ?? "transcription", speakers: recognised.speakers)
            return ProcessingResult(speakers: recognised.speakers.count)
        }
    }

    /// Numbered speakers when the speaker recognition models are downloaded; a failure keeps the transcript as it is.
    private static func recogniseSpeakers(_ segments: [TranscriptSegment], in audio: URL, store: MeetingStore,
                                          progress: @escaping @MainActor (ProcessingStage) -> Void) async
    -> (segments: [TranscriptSegment], speakers: [SpeakerProfile], names: SpeakerNames) {
        guard Diarizer.isReady else { return (segments, [], [:]) }
        await progress(.recognisingSpeakers())
        do {
            let recognised = try await Diarizer.recognise(segments, in: audio, known: try store.knownVoices()) { fraction in
                Task { @MainActor in progress(.recognisingSpeakers(progress: fraction)) }
            }
            let names = SpeakerNames(recognised.speakers.compactMap { profile in profile.name.map { (profile.speaker, $0) } }) { $1 }
            return (recognised.segments, recognised.speakers, names)
        } catch {
            log("\(audio.lastPathComponent) speaker recognition failed: \(ProcessingLogic.errorDetails(error))")
            return (segments, [], [:])
        }
    }

    /// Summarises the stored transcript of `audio` in its saved language, or runs the whole pipeline when there is none.
    static func resummarise(_ audio: URL, store: MeetingStore,
                            progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult {
        let content = try store.content(of: audio.lastPathComponent)
        guard let content, content.meeting.transcribed else {
            return try await run(audio, language: .current, store: store, progress: progress)
        }
        return try await recordingFailure(of: audio, in: store) {
            try await summarise(audio, segments: content.segments, names: content.names,
                                language: content.meeting.language ?? .current, store: store, progress: progress)
        }
    }

    private static func summarise(_ audio: URL, segments: [TranscriptSegment], names: SpeakerNames, language: MeetingLanguage,
                                  store: MeetingStore,
                                  progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult {
        let name = audio.lastPathComponent
        do {
            let summary = try await Summarizer.summarise(segments, names: names, language: language, progress: progress)
            try store.saveSummary(name, ParsedSummary(summary))
            return ProcessingResult(title: summary.title, unavailable: nil)
        } catch let reason as SummaryUnavailable {
            try store.saveSummary(name, ParsedSummary(unavailable: reason.message))
            return ProcessingResult(title: nil, unavailable: reason)
        }
    }

    private static func recordingFailure(of audio: URL, in store: MeetingStore,
                                         _ body: () async throws -> ProcessingResult) async throws -> ProcessingResult {
        let name = audio.lastPathComponent
        do {
            return try await body()
        } catch {
            let details = ProcessingLogic.errorDetails(error)
            log("\(name) failed: \(details)")
            try? store.setFailed(name, message: details)
            throw error
        }
    }

    private static func log(_ message: String) {
        Logger(subsystem: "MeetingRecorder", category: "processing").error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func runFromCommandLine(_ audio: URL, language: MeetingLanguage, recogniseOnly: Bool, store: MeetingStore) -> Never {
        Task {
            do {
                let progress: @MainActor (ProcessingStage) -> Void = { print($0.text(for: audio.lastPathComponent)) }
                let result = recogniseOnly ? try await recogniseSpeakers(audio, store: store, progress: progress)
                    : try await run(audio, language: language, store: store, progress: progress)
                print("Saved to \(AppPaths.database.path)")
                if let content = try store.content(of: audio.lastPathComponent) {
                    let speakers = Set(content.segments.compactMap(\.speaker))
                    print("Speakers: " + speakers.map { content.names.name(of: $0, in: .english) }.sorted().joined(separator: ", "))
                }
                print(result.speakers.map { "Recognised \($0) speakers" } ?? result.unavailable?.message ?? "Summary: \(result.title ?? "")")
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
    private var modelWatch: Task<Void, Never>?

    init(notifier: Notifier?, store: MeetingStore) {
        self.notifier = notifier
        self.store = store
    }

    func process(_ audio: URL) {
        enqueue(audio) { [store] in try await MeetingPipeline.run(audio, language: .current, store: store, progress: $0) }
    }

    /// Summarises the meeting's stored transcript, transcribing first only when it has none.
    func summarise(_ audio: URL) {
        enqueue(audio) { [store] in try await MeetingPipeline.resummarise(audio, store: store, progress: $0) }
    }

    /// Tells the speakers of the stored transcript apart, transcribing first only when it has none.
    func recogniseSpeakers(_ audio: URL) {
        enqueue(audio) { [store] in try await MeetingPipeline.recogniseSpeakers(audio, store: store, progress: $0) }
    }

    /// While Apple Intelligence is off or downloading, waits for it and then summarises every meeting left without a summary.
    func summariseWhenModelReady() {
        guard modelWatch == nil, Summarizer.isWaitingForModel, (try? store.awaitingSummary())?.isEmpty == false else { return }
        modelWatch = Task { [weak self] in
            await Summarizer.waitUntilAvailable()
            self?.modelWatch = nil
            self?.summariseAwaiting()
        }
    }

    private func summariseAwaiting() {
        let audio = ((try? store.awaitingSummary()) ?? []).map { AppPaths.recordings.appendingPathComponent($0.audioFile) }
            .filter { $0 != processing }
        guard let newest = audio.first else { return }
        notifier?.postProcessed(title: "Apple Intelligence is ready",
                                body: "Summarising \(audio.count) meeting\(audio.count == 1 ? "" : "s")", meeting: newest)
        audio.forEach(summarise)
    }

    private typealias Job = (@escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult

    private func enqueue(_ audio: URL, _ job: @escaping Job) {
        let previous = queue
        queue = Task {
            await previous?.value
            await run(audio, job)
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

    private func run(_ audio: URL, _ job: Job) async {
        let name = audio.lastPathComponent
        errorMessage = nil
        processing = audio
        defer { processing = nil }
        do {
            let result = try await job { [weak self] in self?.status = $0.text(for: name) }
            latestMeeting = audio
            if let speakers = result.speakers {
                status = "\(speakers) speaker\(speakers == 1 ? "" : "s") recognised: \(name)"
                notifier?.postProcessed(title: "Speakers recognised", body: status ?? name, meeting: audio)
            } else if let reason = result.unavailable {
                status = reason.message
                notifier?.postProcessed(title: "Transcript ready, no summary", body: reason.message, meeting: audio)
                summariseWhenModelReady()
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
