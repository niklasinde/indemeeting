import Foundation
#if canImport(whisper)
import FluidAudio

/// `--benchmark-asr`: transcribes clips with one recogniser setup and writes `<config>.json` with the text per chunk,
/// the time it took and the process's peak memory, for comparing setups side by side. Run each setup in its own
/// process so the peak belongs to it.
enum ASRBenchmark {
    static func runFromCommandLine(output: URL, config: ASRBenchmarkConfig, clips: [URL]) -> Never {
        Task {
            var results: [ASRBenchmarkResult] = []
            do {
                let runner = try await Runner(config)
                for clip in clips {
                    let samples = try WhisperEngine.samples(of: clip)
                    let duration = Double(samples.count) / WhisperEngine.sampleRate
                    let started = Date()
                    do {
                        let chunks = try await runner.transcribe(clip, samples: samples)
                        results.append(ASRBenchmarkResult(config: config.rawValue, clip: clip.lastPathComponent, duration: duration,
                                                          seconds: Date().timeIntervalSince(started), peakMegabytes: peakMegabytes(),
                                                          chunks: chunks))
                    } catch {
                        results.append(ASRBenchmarkResult(config: config.rawValue, clip: clip.lastPathComponent, duration: duration,
                                                          seconds: 0, peakMegabytes: nil, chunks: [],
                                                          error: error.localizedDescription))
                    }
                    print("\(config.rawValue) \(clip.lastPathComponent): \(results.last?.error ?? "done")")
                }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(results).write(to: output.appendingPathComponent("\(config.rawValue).json"))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func peakMegabytes() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : nil
    }

    private static func modelFile(_ name: String) -> URL { AppPaths.models.appendingPathComponent(name) }

    private final class Runner {
        let config: ASRBenchmarkConfig
        var whisper: WhisperEngine?
        var swedish: WhisperEngine?
        var parakeet: AsrManager?

        init(_ config: ASRBenchmarkConfig) async throws {
            self.config = config
            switch config {
            case .apple: break
            case .kbMedium:
                guard let model = WhisperModel.with(id: "kb-whisper-medium-q5_0") else { throw WhisperModelError.unavailable }
                whisper = try WhisperEngine(model: model, language: .swedish)
            case .turbo, .hybrid:
                whisper = WhisperEngine(file: modelFile("ggml-large-v3-turbo-q5_0.bin"), id: "large-v3-turbo")
                if config == .hybrid, let model = WhisperModel.with(id: "kb-whisper-medium-q5_0") {
                    swedish = try WhisperEngine(model: model, language: .swedish)
                }
            case .largeV3:
                whisper = WhisperEngine(file: modelFile("ggml-large-v3-q5_0.bin"), id: "large-v3")
            case .parakeet:
                let manager = AsrManager(config: .default)
                try await manager.loadModels(try await AsrModels.downloadAndLoad(version: .v3))
                parakeet = manager
            }
            if [.kbMedium, .turbo, .largeV3, .hybrid].contains(config), whisper == nil { throw WhisperModelError.unavailable }
        }

        func transcribe(_ clip: URL, samples: [Float]) async throws -> [ASRBenchmarkChunk] {
            let duration = Double(samples.count) / WhisperEngine.sampleRate
            switch config {
            case .apple:
                let decision = try await LanguageDetector.detect(clip, among: [.swedish, .english])
                let transcript = try await AppleSpeechEngine(language: decision.language).transcribe(clip) { _ in }
                return [ASRBenchmarkChunk(start: 0, end: duration, language: decision.language.code, engine: transcript.engine,
                                          text: transcript.text)]
            case .kbMedium:
                let result = try whisper!.transcribe(samples, offset: 0)
                return [chunk(0, duration, result, engine: whisper!.id)]
            case .parakeet:
                var state = TdtDecoderState.make()
                let result = try await parakeet!.transcribe(samples, decoderState: &state)
                return [ASRBenchmarkChunk(start: 0, end: duration, language: "auto", engine: "parakeet-tdt-0.6b-v3", text: result.text)]
            case .turbo, .largeV3, .hybrid:
                return try perChunk(samples)
            }
        }

        private func perChunk(_ samples: [Float]) throws -> [ASRBenchmarkChunk] {
            let frame = Int(ASRBenchmarkLogic.frameLength * WhisperEngine.sampleRate)
            let levels = stride(from: 0, to: samples.count, by: frame).map { start in
                var meter = LevelMeter()
                meter.add(Array(samples[start..<min(samples.count, start + frame)]))
                return meter.rms
            }
            return try ASRBenchmarkLogic.chunks(levels: levels).compactMap { range in
                let start = range.lowerBound * frame, end = min(samples.count, range.upperBound * frame)
                let piece = Array(samples[start..<end])
                let offset = Double(start) / WhisperEngine.sampleRate, until = Double(end) / WhisperEngine.sampleRate
                guard let whisper else { return nil }
                if config == .hybrid, let swedish, let detected = whisper.detectLanguage(piece) {
                    let engine = detected.code == "sv" ? swedish : whisper
                    return chunk(offset, until, try engine.transcribe(piece, offset: offset, language: detected.code), engine: engine.id)
                }
                return chunk(offset, until, try whisper.transcribe(piece, offset: offset), engine: whisper.id)
            }
        }

        private func chunk(_ start: TimeInterval, _ end: TimeInterval, _ result: (segments: [TranscriptSegment], language: String),
                           engine: String) -> ASRBenchmarkChunk {
            ASRBenchmarkChunk(start: start, end: end, language: result.language, engine: engine,
                              text: result.segments.map(\.text).joined(separator: " "))
        }
    }
}
#else
enum ASRBenchmark {
    static func runFromCommandLine(output: URL, config: ASRBenchmarkConfig, clips: [URL]) -> Never {
        FileHandle.standardError.write(Data("Failed: \(WhisperModelError.unavailable.localizedDescription)\n".utf8))
        exit(1)
    }
}
#endif
