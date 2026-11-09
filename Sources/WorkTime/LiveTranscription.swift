import AVFoundation
import Combine
import os
import Speech

/// A preview of what is being said while recording, from Apple's streaming speech model fed with the recorder's two
/// stems, replaced stretch by stretch by the meeting's Whisper model when the live model is Best. The meeting's
/// transcript is made from the recording after it stops; this one is kept as an earlier version.
@MainActor
final class LiveTranscription: ObservableObject {
    @Published private(set) var transcript = LiveTranscript()
    @Published private(set) var language: MeetingLanguage?
    @Published private(set) var note: String?
    @Published private(set) var isListening = false

    /// The languages a meeting may be in; the live preview uses the first.
    var languages: (URL) -> [MeetingLanguage] = { _ in MeetingLanguage.listened() }

    private var mixer: AudioMixer?
    private var paused = false
    private var streams: [LiveStream] = []
    private var candidates: [MeetingLanguage] = []
    private var whisper: LiveWhisper?
    private var feed: LiveWhisperFeed?
    private var generation = 0
    private var recording = 0
    private var finishing = 0
    private var settingObserver: NSObjectProtocol?

    init() {
        settingObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSetting() }
        }
    }

    func start(meeting: URL, mixer: AudioMixer) {
        endStreams()
        whisper?.cancel()
        whisper = nil
        transcript = LiveTranscript()
        note = nil
        paused = false
        recording += 1
        candidates = languages(meeting)
        language = LiveTranscriptLogic.language(among: candidates)
        self.mixer = mixer
        listen()
    }

    func pause() {
        paused = true
        endStreams()
    }

    func resume() {
        paused = false
        listen()
    }

    func stop() {
        endStreams()
        mixer = nil
    }

    /// The finished lines once the streams have turned what they heard into final results, or after `timeout`, and
    /// Whisper has transcribed what it still can within `whisperTimeout`. The Whisper model is let go before returning.
    func finalLines(timeout: TimeInterval = 5, whisperTimeout: TimeInterval = 10) async -> [LiveLine] {
        let deadline = Date().addingTimeInterval(timeout)
        while finishing > 0, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if let whisper {
            self.whisper = nil
            await whisper.finish(until: Date().addingTimeInterval(whisperTimeout))
            transcript.expectWhisper(false)
        }
        return transcript.lines.filter(\.isFinal)
    }

    #if DEBUG
    func preview(_ transcript: LiveTranscript, language: MeetingLanguage) {
        self.transcript = transcript
        self.language = language
    }
    #endif

    private func followSetting() {
        guard mixer != nil, !paused else { return }
        let enabled = LiveTranscriptLogic.isEnabled()
        if enabled, !isListening { listen() } else if !enabled, isListening { endStreams() }
    }

    private func listen() {
        guard LiveTranscriptLogic.isEnabled(), let mixer, let language, !isListening else { return }
        generation += 1
        let generation = generation, recording = recording
        isListening = true
        Task {
            var started: [LiveStream] = []
            do {
                for source in AudioSource.allCases {
                    let speaker = LiveTranscriptLogic.speaker(of: source)
                    started.append(try await LiveStream.make(language: language) { [weak self] segments, isFinal in
                        guard let self, self.recording == recording else { return }
                        transcript.hear(segments, from: speaker, isFinal: isFinal)
                    })
                }
            } catch {
                started.forEach { stream in Task { await stream.finish() } }
                guard generation == self.generation else { return }
                note = (error as? LiveTranscriptError ?? .failed(error.localizedDescription)).note
                isListening = false
                return
            }
            guard generation == self.generation else {
                started.forEach { stream in Task { await stream.finish() } }
                return
            }
            streams = started
            note = nil
            if whisper == nil { whisper = makeWhisper(language: language) }
            let feed = whisper.map { _ in LiveWhisperFeed() }
            self.feed = feed
            let start = mixer.listen { [weak self] source, samples in
                started[source.rawValue].feed(samples)
                guard let feed, case let chunks = feed.add(samples, from: source), !chunks.isEmpty else { return }
                Task { @MainActor in self?.transcribe(chunks, from: feed) }
            }
            let offset = Double(start) / PCMNormalizer.format.sampleRate
            started.forEach { $0.offset = offset }
            feed?.offset = offset
        }
    }

    private func endStreams() {
        generation += 1
        mixer?.listen(nil)
        if let feed { transcribe(feed.flush(), from: feed) }
        feed = nil
        let ending = streams
        streams = []
        isListening = false
        guard !ending.isEmpty else { return }
        finishing += 1
        Task {
            for stream in ending { await stream.finish() }
            finishing -= 1
        }
    }

    private func transcribe(_ chunks: [LiveChunk], from feed: LiveWhisperFeed) {
        whisper?.add(chunks.map { $0.shifted(by: feed.offset) })
    }

    private func makeWhisper(language: MeetingLanguage) -> LiveWhisper? {
        guard let model = LiveTranscriptLogic.whisperModel(LiveModel.stored(), engine: TranscriptionEngine.current()) else { return nil }
        let recording = recording
        let options = Transcriber.whisperOptions(language: language, among: candidates, vocabulary: nil, beamSearch: false)
        transcript.expectWhisper(true)
        return LiveWhisper(model: model, options: options, settle: { [weak self] span in
            guard let self, self.recording == recording else { return }
            transcript.settle(span)
        }, gaveUp: { [weak self] in
            guard let self, self.recording == recording else { return }
            transcript.expectWhisper(false)
        })
    }
}

/// Cuts each stem into chunks at pauses as it is recorded, at Whisper's sample rate. Fed on the mixer's queue;
/// `offset`, where in the recording the feed starts, is set and read on the main actor.
final class LiveWhisperFeed: @unchecked Sendable {
    var offset: TimeInterval = 0
    private var chunkers = AudioSource.allCases.map { LiveChunker(speaker: LiveTranscriptLogic.speaker(of: $0), start: 0) }
    private let normalizers = AudioSource.allCases.map { _ in PCMNormalizer(format: PCMNormalizer.whisperFormat) }

    func add(_ samples: [Float], from source: AudioSource) -> [LiveChunk] {
        guard let buffer = PCMNormalizer.buffer(samples) else { return [] }
        return chunkers[source.rawValue].add(normalizers[source.rawValue].samples(from: buffer))
    }

    /// What each stem holds after its last pause; called once nothing more is fed.
    func flush() -> [LiveChunk] { chunkers.indices.flatMap { chunkers[$0].flush() } }
}

/// The Whisper pass behind Apple's live text: one engine, loaded once for the recording, transcribes both stems' chunks
/// in turn on its own queue at the quiet pace. When more than `LiveTranscriptLogic.maximumBacklog` seconds wait, the
/// oldest chunks keep Apple's text.
@MainActor
final class LiveWhisper {
    private static let log = Logger(subsystem: "MeetingRecorder", category: "live")

    private let model: WhisperModel
    private let settle: (LiveSpan) -> Void
    private let gaveUp: () -> Void
    private var engine: WhisperEngine?
    private var loading: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var pending: [LiveChunk] = []
    private var finished = false

    init(model: WhisperModel, options: WhisperOptions, settle: @escaping (LiveSpan) -> Void, gaveUp: @escaping () -> Void) {
        self.model = model
        self.settle = settle
        self.gaveUp = gaveUp
        loading = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { Result { try WhisperEngine(model: model, options: options) } }.value
            guard let self else { return }
            loading = nil
            switch loaded {
            case .success(let engine):
                guard !finished else { return }
                self.engine = engine
                next()
            case .failure(let error):
                Self.log.error("Live Whisper could not load \(model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                finished = true
                pending.forEach(keep)
                pending = []
                gaveUp()
            }
        }
    }

    func add(_ chunks: [LiveChunk]) {
        for chunk in chunks {
            if chunk.spoken, !finished { pending.append(chunk) } else { keep(chunk) }
        }
        let backlog = LiveTranscriptLogic.backlog(pending)
        if let oldest = backlog.skipped.first {
            let behind = pending.reduce(0) { $0 + $1.duration }
            Self.log.notice("""
                Live Whisper is \(Int(behind), privacy: .public) s behind; keeping Apple's text for \
                \(backlog.skipped.count, privacy: .public) chunk(s) from \(Int(oldest.start), privacy: .public) s
                """)
            backlog.skipped.forEach(keep)
            pending = backlog.waiting
        }
        next()
    }

    /// Transcribes what waits until `deadline`, keeps Apple's text for the rest and lets the model go.
    func finish(until deadline: Date) async {
        while !finished, running != nil || loading != nil || (engine != nil && !pending.isEmpty), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        finished = true
        engine?.cancel()
        await running?.value
        await loading?.value
        pending.forEach(keep)
        pending = []
        engine = nil
    }

    /// Lets the model go without waiting for anything.
    func cancel() {
        finished = true
        engine?.cancel()
        pending = []
        engine = nil
    }

    private func keep(_ chunk: LiveChunk) {
        settle(LiveSpan(speaker: chunk.speaker, start: chunk.start, end: chunk.end, outcome: .kept))
    }

    private func next() {
        guard running == nil, !finished, let engine, !pending.isEmpty else { return }
        let chunk = pending.removeFirst()
        let model = model.id
        running = Task { [weak self] in
            var outcome = LiveSpan.Outcome.kept
            do {
                let segments = try await engine.transcribe(samples: chunk.samples)
                outcome = .whisper(model: model, segments: LiveTranscriptLogic.shifted(segments, by: chunk.start))
            } catch is CancellationError {
            } catch {
                Self.log.error("Live Whisper failed at \(Int(chunk.start), privacy: .public) s: \(error.localizedDescription, privacy: .public)")
            }
            guard let self else { return }
            running = nil
            settle(LiveSpan(speaker: chunk.speaker, start: chunk.start, end: chunk.end, outcome: outcome))
            next()
        }
    }
}

/// One stem streamed into its own speech analyzer.
final class LiveStream: @unchecked Sendable {
    typealias Hear = @MainActor ([TranscriptSegment], Bool) -> Void

    /// Where in the recording this stream's audio starts; set on the main actor before any audio arrives.
    var offset: TimeInterval = 0
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let normalizer: PCMNormalizer
    private var results: Task<Void, Never>?

    static func make(language: MeetingLanguage, hear: @escaping Hear) async throws -> LiveStream {
        switch await SpeechModel.make(for: language, live: true) {
        case .speech(let module): return try await LiveStream(module, language: language, hear: hear)
        case .dictation(let module): return try await LiveStream(module, language: language, hear: hear)
        case nil: throw LiveTranscriptError.unsupported(language)
        }
    }

    private init<Module: SpeechModule>(_ module: Module, language: MeetingLanguage, hear: @escaping Hear) async throws
    where Module.Result: TextResult {
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw LiveTranscriptError.notInstalled(language)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw LiveTranscriptError.unsupported(language)
        }
        _ = try? await AssetInventory.reserve(locale: language.locale)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        analyzer = SpeechAnalyzer(modules: [module])
        normalizer = PCMNormalizer(format: format)
        self.input = input
        results = Task { @MainActor [weak self] in
            do {
                for try await result in module.results {
                    guard let self else { return }
                    let segments = result.isFinal ? result.sentences
                        : [TranscriptSegment(start: result.range.start.seconds,
                                             text: String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines))]
                    hear(LiveTranscriptLogic.shifted(segments, by: offset), result.isFinal)
                }
            } catch {}
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            input.finish()
            results?.cancel()
            throw error
        }
    }

    /// Called on the mixer's queue.
    func feed(_ samples: [Float]) {
        guard let buffer = PCMNormalizer.buffer(samples), let converted = normalizer.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Finishes what was heard so far into final results and lets the analyzer go.
    func finish() async {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        await results?.value
    }
}
