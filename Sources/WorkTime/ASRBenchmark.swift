import Foundation
#if canImport(ggml)
import FluidAudio

/// `--benchmark-asr`: transcribes clips with one recogniser setup and writes `<config>.json` with the text per chunk,
/// the time it took and the process's peak memory, for comparing setups side by side. Run each setup in its own
/// process so the peak belongs to it.
enum ASRBenchmark {
    static func runFromCommandLine(output: URL, config: ASRBenchmarkConfig, clips: [URL]) -> Never {
        Task {
            do {
                let results = try await run(config, clips: clips)
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

    /// The runner, and with it the model, is freed before the process exits, which Metal requires.
    private static func run(_ config: ASRBenchmarkConfig, clips: [URL]) async throws -> [ASRBenchmarkResult] {
        var results: [ASRBenchmarkResult] = []
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
        return results
    }

    static func peakMegabytes() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : nil
    }

    private final class Runner {
        let config: ASRBenchmarkConfig
        var whisper: WhisperEngine?
        var parakeet: AsrManager?

        init(_ config: ASRBenchmarkConfig) async throws {
            self.config = config
            if let model = config.model {
                let languages = MeetingLanguage.allCases.map(\.code)
                whisper = try WhisperEngine(model: model, options: WhisperOptions(
                    languages: languages, fallback: MeetingLanguage.current.code,
                    prompt: try? MeetingStore.openReadOnly().vocabularyPrompt(), beamSearch: TranscriptionEngine.beamSearch()))
            } else if config == .parakeet {
                let manager = AsrManager(config: .default)
                try await manager.loadModels(try await AsrModels.downloadAndLoad(version: .v3))
                parakeet = manager
            }
        }

        func transcribe(_ clip: URL, samples: [Float]) async throws -> [ASRBenchmarkChunk] {
            let duration = Double(samples.count) / WhisperEngine.sampleRate
            switch config {
            case .apple:
                let decision = try await LanguageDetector.detect(clip, among: [.swedish, .english])
                let transcript = try await AppleSpeechEngine(language: decision.language).transcribe(clip) { _ in }
                return [ASRBenchmarkChunk(start: 0, end: duration, language: decision.language.code, engine: transcript.engine,
                                          text: transcript.text)]
            case .parakeet:
                var state = TdtDecoderState.make()
                let result = try await parakeet!.transcribe(samples, decoderState: &state)
                return [ASRBenchmarkChunk(start: 0, end: duration, language: "auto", engine: "parakeet-tdt-0.6b-v3", text: result.text)]
            case .turbo, .largeV3:
                guard let whisper else { throw WhisperModelError.unavailable }
                return try whisper.transcribeChunks(samples).map {
                    ASRBenchmarkChunk(start: $0.start, end: $0.end, language: $0.language, engine: whisper.id,
                                      text: $0.segments.map(\.text).joined(separator: " "))
                }
            }
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
