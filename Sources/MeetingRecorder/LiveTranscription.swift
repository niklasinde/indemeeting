import AVFoundation
import Combine
import Speech

/// A preview of what is being said while recording, from Apple's streaming speech model fed with the recorder's two
/// stems. The meeting's transcript is made from the recording after it stops; this one is kept as an earlier version.
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
        transcript = LiveTranscript()
        note = nil
        paused = false
        recording += 1
        language = LiveTranscriptLogic.language(among: languages(meeting))
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

    /// The finished lines once the streams have turned what they heard into final results, or after `timeout`.
    func finalLines(timeout: TimeInterval = 5) async -> [LiveLine] {
        let deadline = Date().addingTimeInterval(timeout)
        while finishing > 0, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
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
            let start = mixer.listen { source, samples in started[source.rawValue].feed(samples) }
            started.forEach { $0.offset = Double(start) / PCMNormalizer.format.sampleRate }
        }
    }

    private func endStreams() {
        generation += 1
        mixer?.listen(nil)
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
