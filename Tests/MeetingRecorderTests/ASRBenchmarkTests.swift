import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private let loud = 0.05, quiet = 0.0

let asrBenchmarkTests: [(name: String, run: () throws -> Void)] = [
    ("speech chunks are cut in the middle of a pause once they are long enough", {
        let levels = Array(repeating: loud, count: 100) + Array(repeating: quiet, count: 6) + Array(repeating: loud, count: 50)
        let chunks = SpeechChunks.chunks(levels: levels)
        check(chunks == [0..<103, 103..<156], "chunks \(chunks)")
    }),
    ("a short pause before the minimum length does not cut", {
        let levels = Array(repeating: loud, count: 30) + Array(repeating: quiet, count: 6) + Array(repeating: loud, count: 30)
        check(SpeechChunks.chunks(levels: levels) == [0..<66], "one chunk")
    }),
    ("speech without pauses is cut at its quietest frame by the maximum length", {
        var levels = Array(repeating: loud, count: 400)
        levels[200] = 0.01
        let chunks = SpeechChunks.chunks(levels: levels)
        check(chunks.first == 0..<201, "first \(chunks)")
        check(chunks.allSatisfy { $0.count <= 280 } && chunks.last?.upperBound == 400, "all within the maximum \(chunks)")
    }),
    ("--benchmark-asr reads the output folder, setup and clips", {
        let job = ASRBenchmarkLogic.arguments(["app", "--benchmark-asr", "/out", "--config", "turbo", "/a.caf", "/b.caf"])
        check(job?.config == .turbo && job?.output.path == "/out" && job?.clips.map(\.path) == ["/a.caf", "/b.caf"], "\(String(describing: job))")
        check(ASRBenchmarkLogic.arguments(["app", "--benchmark-asr", "/out", "--config", "nope"]) == nil, "unknown setup")
        check(ASRBenchmarkConfig.turbo.model?.id == "ggml-large-v3-turbo-q5_0" && ASRBenchmarkConfig.apple.model == nil, "catalogue models")
    }),
]
