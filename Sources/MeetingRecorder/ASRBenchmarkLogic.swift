import Foundation

/// A speech recogniser setup the ASR benchmark compares.
enum ASRBenchmarkConfig: String, CaseIterable {
    case apple
    case turbo
    case largeV3 = "large-v3"
    case parakeet

    /// The catalogue model a Whisper setup transcribes with, through the same path as meetings.
    var model: WhisperModel? {
        switch self {
        case .turbo: return WhisperModel.with(id: "ggml-large-v3-turbo-q5_0")
        case .largeV3: return WhisperModel.with(id: "ggml-large-v3-q5_0")
        case .apple, .parakeet: return nil
        }
    }
}

/// One stretch of a clip, transcribed in one language by one engine.
struct ASRBenchmarkChunk: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let language: String
    let engine: String
    let text: String
}

struct ASRBenchmarkResult: Codable {
    let config: String
    let clip: String
    let duration: TimeInterval
    let seconds: TimeInterval
    let peakMegabytes: Double?
    let chunks: [ASRBenchmarkChunk]
    var error: String? = nil
}

enum ASRBenchmarkLogic {
    /// `--benchmark-asr <output folder> --config <name> <clip>...`.
    static func arguments(_ arguments: [String]) -> (output: URL, config: ASRBenchmarkConfig, clips: [URL])? {
        guard let index = arguments.firstIndex(of: "--benchmark-asr"), index + 1 < arguments.count,
              let flag = arguments.firstIndex(of: "--config"), flag + 1 < arguments.count,
              let config = ASRBenchmarkConfig(rawValue: arguments[flag + 1]) else { return nil }
        let flags: Set = [index, index + 1, flag, flag + 1]
        let clips = arguments.indices.dropFirst().filter { !flags.contains($0) }.map { URL(fileURLWithPath: arguments[$0]) }
        return (URL(fileURLWithPath: arguments[index + 1]), config, clips)
    }
}
