import Foundation

/// A speech recogniser setup the ASR benchmark compares.
enum ASRBenchmarkConfig: String, CaseIterable {
    case apple
    case kbMedium = "kb-medium"
    case turbo
    case largeV3 = "large-v3"
    case parakeet
    case hybrid
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
    static let frameLength: TimeInterval = 0.1
    static let minimumPause: TimeInterval = 0.5
    static let minimumChunk: TimeInterval = 8
    static let maximumChunk: TimeInterval = 28

    /// Where to cut a clip into chunks Whisper can detect the language of one by one: at the middle of a pause once a
    /// chunk is long enough, or at its quietest frame when it reaches the maximum. `levels` is the RMS of each frame.
    static func chunks(levels: [Double], threshold: Double = LevelMeter.soundThreshold) -> [Range<Int>] {
        let minimum = Int(minimumChunk / frameLength), maximum = Int(maximumChunk / frameLength)
        let pause = Int(minimumPause / frameLength)
        var ranges: [Range<Int>] = []
        var start = 0
        var quiet = 0
        var index = 0
        while index < levels.count {
            quiet = levels[index] < threshold ? quiet + 1 : 0
            let length = index + 1 - start
            if length >= minimum, quiet >= pause {
                let cut = index + 1 - quiet / 2
                ranges.append(start..<cut)
                start = cut
                quiet = 0
            } else if length >= maximum {
                let window = (start + minimum)...index
                let cut = window.min { levels[$0] < levels[$1] }.map { $0 + 1 } ?? index + 1
                ranges.append(start..<cut)
                start = cut
                quiet = 0
                index = cut - 1
            }
            index += 1
        }
        if start < levels.count { ranges.append(start..<levels.count) }
        return ranges
    }

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
