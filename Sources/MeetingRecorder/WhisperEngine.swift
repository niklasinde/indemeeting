import AVFoundation
import IOKit.ps

/// How Whisper transcribes: the languages each stretch may be in (Whisper codes; empty for any), the one to use when
/// detection has nothing to go on, a prompt with the words to expect, and beam search instead of greedy decoding.
struct WhisperOptions {
    var languages: [String] = []
    var fallback = "auto"
    var prompt: String? = nil
    var beamSearch = true
}

/// A stretch of audio Whisper transcribed in one language.
struct WhisperChunk {
    let start: TimeInterval
    let end: TimeInterval
    let language: String
    let segments: [TranscriptSegment]
}

#if canImport(whisper)
import whisper

/// Transcribes with a downloaded Whisper model through whisper.cpp, on the GPU with Metal.
final class WhisperEngine: SpeechEngine, @unchecked Sendable {
    static let sampleRate = WhisperLogic.sampleRate

    let id: String
    private let options: WhisperOptions
    private let context: OpaquePointer
    private let threads: Int32
    private let queue: DispatchQueue
    private let cancelLock = NSLock()
    private var cancelled = false
    private var vadFile = WhisperModel.vadFile()?.path

    convenience init(model: WhisperModel, options: WhisperOptions) throws {
        guard model.isInstalled() else { throw WhisperModelError.notInstalled(model) }
        guard let engine = Self.context(file: model.url()) else { throw WhisperModelError.couldNotLoad(model) }
        self.init(context: engine, id: model.id, options: options)
    }

    private init(context: OpaquePointer, id: String, options: WhisperOptions) {
        self.context = context
        self.id = id
        self.options = options
        let pace = WhisperLogic.pace(quiet: TranscriptionEngine.quiet(), onAC: Self.onACPower,
                                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                     cores: ProcessInfo.processInfo.activeProcessorCount)
        threads = pace.threads
        queue = DispatchQueue(label: "whisper", qos: pace.qos)
    }

    private static var onACPower: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPMACPowerKey
    }

    private static func context(file: URL) -> OpaquePointer? {
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text, case let message = String(cString: text), !message.contains("Core ML")
            else { return }
            FileHandle.standardError.write(Data(message.utf8))
        }, nil)
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        return whisper_init_from_file_with_params(file.path, params)
    }

    deinit { whisper_free(context) }

    func transcribe(_ audio: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        let segments = try await transcribe(samples: try Self.samples(of: audio), progress: progress)
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech(audio.lastPathComponent) }
        return Transcript(segments: segments, engine: id)
    }

    /// 16 kHz samples, after whatever was queued before them on the engine's one queue.
    func transcribe(samples: [Float], progress: @escaping TranscriptionProgress = { _ in }) async throws -> [TranscriptSegment] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.chunks(of: samples, progress: progress).flatMap(\.segments) }) }
        }
    }

    /// Stops the transcription running now and every later one, for an engine about to be let go.
    func cancel() {
        cancelLock.withLock { cancelled = true }
    }

    private var isCancelled: Bool { cancelLock.withLock { cancelled } }

    /// The samples cut at pauses, each stretch transcribed in the language detected for it.
    func transcribeChunks(_ samples: [Float]) throws -> [WhisperChunk] {
        try queue.sync { try chunks(of: samples) { _ in } }
    }

    private func chunks(of samples: [Float], progress: @escaping TranscriptionProgress) throws -> [WhisperChunk] {
        let ranges = SpeechChunks.ranges(of: samples, sampleRate: Self.sampleRate)
        return try ranges.enumerated().map { index, range in
            let piece = Array(samples[range])
            let language = options.languages.count == 1 ? options.languages[0]
                : WhisperLogic.language(probabilities(of: piece), allowed: options.languages, fallback: options.fallback)
            let start = Double(range.lowerBound) / Self.sampleRate
            let segments = try run(piece, language: language) { progress((Double(index) + $0) / Double(ranges.count)) }
            return WhisperChunk(start: start, end: Double(range.upperBound) / Self.sampleRate, language: language,
                                segments: segments.map { TranscriptSegment(start: $0.start + start, text: $0.text) })
        }
    }

    /// How likely each language is in the first 30 seconds of `samples`.
    private func probabilities(of samples: [Float]) -> [String: Double] {
        guard samples.withUnsafeBufferPointer({ whisper_pcm_to_mel(context, $0.baseAddress, Int32($0.count), threads) }) == 0
        else { return [:] }
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard whisper_lang_auto_detect(context, 0, threads, &probabilities) >= 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: probabilities.indices.map { (String(cString: whisper_lang_str(Int32($0))), Double(probabilities[$0])) })
    }

    private final class ProgressBox {
        let report: TranscriptionProgress
        init(_ report: @escaping TranscriptionProgress) { self.report = report }
    }

    private func run(_ samples: [Float], language: String, progress: @escaping TranscriptionProgress) throws -> [TranscriptSegment] {
        guard samples.count >= Int(Self.sampleRate / 2) else { return [] }
        let box = ProgressBox(progress)
        var params = whisper_full_default_params(options.beamSearch ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        if options.beamSearch { params.beam_search.beam_size = 5 }
        params.n_threads = threads
        params.translate = false
        params.no_context = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_nst = true
        params.progress_callback = { _, _, percent, box in
            box.map { Unmanaged<ProgressBox>.fromOpaque($0).takeUnretainedValue().report(Double(percent) / 100) }
        }
        params.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        params.abort_callback = { engine in
            engine.map { Unmanaged<WhisperEngine>.fromOpaque($0).takeUnretainedValue().isCancelled } ?? false
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(self).toOpaque()
        let status = withExtendedLifetime(box) {
            language.withCString { language in
                (options.prompt ?? "").withCString { prompt in
                    (vadFile ?? "").withCString { vadPath in
                        params.language = language
                        if options.prompt?.isEmpty == false { params.initial_prompt = prompt }
                        if vadFile != nil {
                            params.vad = true
                            params.vad_model_path = vadPath
                            params.vad_params = Self.vadParams
                        }
                        return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
                    }
                }
            }
        }
        guard !isCancelled else { throw CancellationError() }
        if status != 0, vadFile != nil {
            vadFile = nil
            return try run(samples, language: language, progress: progress)
        }
        guard status == 0 else { throw NSError(domain: "whisper", code: Int(status)) }
        let pieces = (0..<whisper_full_n_segments(context))
            .filter { Double(whisper_full_get_segment_no_speech_prob(context, $0)) <= ProcessingLogic.noSpeechLimit }
            .map { index in
                (text: String(cString: whisper_full_get_segment_text(context, index)), start: whisper_full_get_segment_t0(context, index))
            }
        return ProcessingLogic.whisperSentences(pieces)
    }

    private static var vadParams: whisper_vad_params {
        var params = whisper_vad_default_params()
        let vad = WhisperVAD.meetings
        params.threshold = vad.threshold
        params.min_speech_duration_ms = vad.minSpeechMs
        params.min_silence_duration_ms = vad.minSilenceMs
        params.speech_pad_ms = vad.speechPadMs
        return params
    }

    /// The audio as 16 kHz mono floats, the input whisper.cpp expects.
    static func samples(of audio: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: audio)
        let normalizer = PCMNormalizer(format: PCMNormalizer.whisperFormat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / file.processingFormat.sampleRate))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            samples += normalizer.samples(from: buffer)
        }
        return samples
    }
}
#else
final class WhisperEngine: SpeechEngine {
    init(model: WhisperModel, options: WhisperOptions) throws { throw WhisperModelError.unavailable }

    func transcribe(_ audio: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        throw WhisperModelError.unavailable
    }

    func transcribe(samples: [Float], progress: @escaping TranscriptionProgress = { _ in }) async throws -> [TranscriptSegment] {
        throw WhisperModelError.unavailable
    }

    func cancel() {}
}
#endif
