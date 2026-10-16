import AVFoundation
#if canImport(whisper)
import whisper

/// Transcribes Swedish with a downloaded KB-Whisper model through whisper.cpp, on the GPU with Metal.
final class WhisperEngine: SpeechEngine, @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private let model: WhisperModel
    private let context: OpaquePointer
    private let queue = DispatchQueue(label: "whisper", qos: .userInitiated)

    init(model: WhisperModel) throws {
        guard model.isInstalled() else { throw WhisperModelError.notInstalled(model) }
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text, case let message = String(cString: text), !message.contains("Core ML")
            else { return }
            FileHandle.standardError.write(Data(message.utf8))
        }, nil)
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(model.url().path, params) else {
            throw WhisperModelError.couldNotLoad(model)
        }
        self.model = model
        self.context = context
    }

    deinit { whisper_free(context) }

    func transcribe(_ audio: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        let samples = try Self.samples(of: audio)
        let segments = try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.run(samples, progress: progress) }) }
        }
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech(audio.lastPathComponent) }
        return Transcript(segments: segments, engine: model.engineName)
    }

    private final class ProgressBox {
        let report: TranscriptionProgress
        init(_ report: @escaping TranscriptionProgress) { self.report = report }
    }

    private func run(_ samples: [Float], progress: @escaping TranscriptionProgress) throws -> [TranscriptSegment] {
        guard samples.count >= Int(Self.sampleRate / 2) else { return [] }
        let box = ProgressBox(progress)
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.translate = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_nst = true
        params.progress_callback = { _, _, percent, box in
            box.map { Unmanaged<ProgressBox>.fromOpaque($0).takeUnretainedValue().report(Double(percent) / 100) }
        }
        params.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        let status = withExtendedLifetime(box) {
            "sv".withCString { language in
                params.language = language
                return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard status == 0 else { throw NSError(domain: "whisper", code: Int(status)) }
        let pieces = (0..<whisper_full_n_segments(context)).map { index in
            (text: String(cString: whisper_full_get_segment_text(context, index)), start: whisper_full_get_segment_t0(context, index))
        }
        return ProcessingLogic.whisperSentences(pieces)
    }

    /// The audio as 16 kHz mono floats, the input whisper.cpp expects.
    static func samples(of audio: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: audio)
        let normalizer = PCMNormalizer(format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                             channels: 1, interleaved: false)!)
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
    init(model: WhisperModel) throws { throw WhisperModelError.unavailable }

    func transcribe(_ audio: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        throw WhisperModelError.unavailable
    }
}
#endif
