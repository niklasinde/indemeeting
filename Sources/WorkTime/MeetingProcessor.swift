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
    /// Transcribes and summarises `audio` into the store, in the one of `languages` it is in. A failure is recorded on
    /// the meeting and rethrown.
    static func run(_ audio: URL, languages: [MeetingLanguage], store: MeetingStore,
                    progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult {
        try await recordingFailure(of: audio, in: store) {
            let language = await detectLanguage(of: audio, among: languages, progress: progress)
            await progress(.transcribing())
            let transcript = try await Transcriber.transcribeMeeting(audio, language: language.language, among: languages,
                                                                     vocabulary: try? store.vocabularyPrompt()) { fraction in
                Task { @MainActor in progress(.transcribing(progress: fraction)) }
            }
            let recognised = await recogniseSpeakers(transcript.segments, in: audio, store: store, progress: progress)
            try Task.checkCancellation()
            try store.saveTranscript(audio.lastPathComponent, segments: recognised.segments, language: language.language,
                                     detected: language.detected, engine: transcript.engine, transcribedAt: Date(),
                                     speakers: recognised.speakers, keepingPrevious: true)
            return try await summarise(audio, segments: recognised.segments, names: recognised.names, language: language.language,
                                       store: store, progress: progress)
        }
    }

    /// The languages to transcribe a meeting in again: the one chosen for it, or those listened for.
    static func languages(for audio: URL, store: MeetingStore) -> [MeetingLanguage] {
        guard let meeting = try? store.content(of: audio.lastPathComponent)?.meeting, let language = meeting.language,
              !meeting.languageDetected else { return MeetingLanguage.listened() }
        return [language]
    }

    /// The only candidate, or the one detected in a sample of the speech; a failed detection falls back to the
    /// preferred one.
    private static func detectLanguage(of audio: URL, among languages: [MeetingLanguage],
                                       progress: @escaping @MainActor (ProcessingStage) -> Void) async
    -> (language: MeetingLanguage, detected: Bool) {
        guard languages.count > 1 else { return (languages.first ?? .current, false) }
        await progress(.detectingLanguage)
        do {
            let decision = try await LanguageDetector.detect(audio, among: languages)
            log("\(audio.lastPathComponent) language: \(decision.summary)")
            return (decision.language, true)
        } catch {
            log("\(audio.lastPathComponent) language detection failed: \(ProcessingLogic.errorDetails(error))")
            return (LanguageLogic.preferred(among: languages, preferred: Locale.preferredLanguages), true)
        }
    }

    /// Tells the speakers of the stored transcript apart again without transcribing, or runs the whole pipeline when
    /// there is no transcript.
    static func recogniseSpeakers(_ audio: URL, store: MeetingStore,
                                  progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult {
        guard let content = try store.content(of: audio.lastPathComponent), content.meeting.transcribed else {
            return try await run(audio, languages: MeetingLanguage.listened(), store: store, progress: progress)
        }
        return try await recordingFailure(of: audio, in: store) {
            await progress(.recognisingSpeakers())
            let recognised = try await Diarizer.recognise(content.segments, in: audio, known: try store.knownVoices()) { fraction in
                Task { @MainActor in progress(.recognisingSpeakers(progress: fraction)) }
            }
            try Task.checkCancellation()
            let meeting = content.meeting
            try store.saveTranscript(meeting.audioFile, segments: recognised.segments, language: meeting.language ?? .current,
                                     detected: meeting.languageDetected, engine: meeting.transcriptEngine ?? "transcription",
                                     speakers: recognised.speakers)
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
            return try await run(audio, languages: MeetingLanguage.listened(), store: store, progress: progress)
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
            let event = try? store.calendarEvent(of: name)
            let context = CalendarLogic.summaryContext(title: event?.event.title, attendees: event?.event.attendees.map(\.label) ?? [],
                                                       agenda: event?.agenda)
            let (summary, engine) = try await Summarizer.summarise(segments, names: names, language: language, context: context,
                                                                   progress: progress)
            try Task.checkCancellation()
            try store.saveSummary(name, ParsedSummary(summary, engine: engine.model))
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
        } catch where Task.isCancelled {
            log("\(name) stopped")
            try? store.setStopped(name)
            throw CancellationError()
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

    static func runFromCommandLine(_ audio: URL, languages: [MeetingLanguage], mode: ProcessingLogic.ProcessMode, store: MeetingStore) -> Never {
        Task {
            do {
                let progress: @MainActor (ProcessingStage) -> Void = { print($0.text(for: audio.lastPathComponent)) }
                let result = switch mode {
                case .process: try await run(audio, languages: languages, store: store, progress: progress)
                case .recogniseSpeakers: try await recogniseSpeakers(audio, store: store, progress: progress)
                case .resummarise: try await resummarise(audio, store: store, progress: progress)
                }
                print("Saved to \(AppPaths.database.path)")
                if let content = try store.content(of: audio.lastPathComponent) {
                    let meeting = content.meeting
                    print("Language: \(meeting.language?.displayName ?? "-")" + (meeting.languageDetected ? " (detected)" : ""))
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
    private var queued: [URL: Int] = [:]
    /// How often each meeting was stopped; a job queued before the latest stop is skipped.
    private var stops: [URL: Int] = [:]
    private var current: Task<ProcessingResult, Error>?
    private var modelWatch: Task<Void, Never>?

    init(notifier: Notifier?, store: MeetingStore) {
        self.notifier = notifier
        self.store = store
    }

    /// Transcribes and summarises a meeting in the language chosen for it, or the one detected among those listened for.
    func process(_ audio: URL) {
        enqueue(audio) { [store] in
            try await MeetingPipeline.run(audio, languages: MeetingPipeline.languages(for: audio, store: store), store: store,
                                          progress: $0)
        }
    }

    /// Transcribes and summarises a meeting again in `language`.
    func process(_ audio: URL, in language: MeetingLanguage) {
        enqueue(audio) { [store] in try await MeetingPipeline.run(audio, languages: [language], store: store, progress: $0) }
    }

    /// Summarises the meeting's stored transcript, transcribing first only when it has none.
    func summarise(_ audio: URL) {
        enqueue(audio) { [store] in try await MeetingPipeline.resummarise(audio, store: store, progress: $0) }
    }

    /// Tells the speakers of the stored transcript apart, transcribing first only when it has none.
    func recogniseSpeakers(_ audio: URL) {
        enqueue(audio) { [store] in try await MeetingPipeline.recogniseSpeakers(audio, store: store, progress: $0) }
    }

    /// Queues the meetings left unprocessed when the app last quit.
    func resumeUnfinished() {
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: AppPaths.recordings.path)) ?? [])
        let unfinished = ProcessingLogic.unfinished((try? store.meetings()) ?? [], files: files, now: Date())
        for job in unfinished {
            switch job {
            case .process(let name): process(AppPaths.recordings.appendingPathComponent(name))
            case .summarise(let name): summarise(AppPaths.recordings.appendingPathComponent(name))
            }
        }
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
            .filter { !busyFiles.contains($0.lastPathComponent) }
        guard let newest = audio.first else { return }
        notifier?.postProcessed(title: "Apple Intelligence is ready",
                                body: "Summarising \(audio.count) meeting\(audio.count == 1 ? "" : "s")", meeting: newest)
        audio.forEach(summarise)
    }

    private typealias Job = (@escaping @MainActor (ProcessingStage) -> Void) async throws -> ProcessingResult

    /// The meetings being processed or waiting for it.
    var busyFiles: Set<String> { Set(queued.keys.map(\.lastPathComponent)) }

    private func enqueue(_ audio: URL, _ job: @escaping Job) {
        queued[audio, default: 0] += 1
        let previous = queue
        let stop = stops[audio, default: 0]
        queue = Task {
            await previous?.value
            await run(audio, stop: stop, job)
        }
    }

    /// Stops the meeting's running job and drops those queued for it; it stays as it is until processed again.
    func stop(_ audio: URL) {
        guard busyFiles.contains(audio.lastPathComponent) else { return }
        stops[audio, default: 0] += 1
        if processing == audio {
            status = "Stopping\u{2026}"
            current?.cancel()
        } else {
            try? store.setStopped(audio.lastPathComponent)
        }
    }

    @discardableResult
    func finishRecording(_ recorder: Recorder, reveal: Bool = true) async -> URL? {
        guard let url = await recorder.stop(reveal: reveal) else { return nil }
        saveLiveTranscript(recorder.liveSegments, of: url, language: recorder.live.language)
        process(url)
        return url
    }

    private func saveLiveTranscript(_ segments: [TranscriptSegment], of audio: URL, language: MeetingLanguage?) {
        guard LiveTranscriptLogic.isEnabled(), !segments.isEmpty else { return }
        do {
            try store.saveLiveTranscript(audio.lastPathComponent, segments: segments, language: language, at: Date())
        } catch {
            Logger(subsystem: "MeetingRecorder", category: "processing")
                .error("Saving the live transcript failed: \(error.localizedDescription, privacy: .public)")
        }
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

    private func run(_ audio: URL, stop: Int, _ job: @escaping Job) async {
        let name = audio.lastPathComponent
        defer {
            let left = (queued[audio] ?? 1) - 1
            queued[audio] = left > 0 ? left : nil
        }
        guard stops[audio, default: 0] == stop else { return }
        errorMessage = nil
        processing = audio
        let work = Task { [weak self] in try await job { self?.status = $0.text(for: name) } }
        current = work
        defer {
            current = nil
            processing = nil
        }
        do {
            let result = try await work.value
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
        } catch where work.isCancelled {
            status = "Stopped: \(name)"
        } catch {
            status = nil
            errorMessage = "\(name): \(error.localizedDescription)"
            notifier?.postProcessed(title: "Meeting processing failed", body: errorMessage ?? name, meeting: audio)
        }
    }
}
