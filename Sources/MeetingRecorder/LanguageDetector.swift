import AVFoundation
import NaturalLanguage

/// Works out which of the listened-for languages a recording is in: a sample of its speech is transcribed in each
/// candidate language, and each transcript is scored on how sure the recogniser was and how much it reads as that
/// language.
enum LanguageDetector {
    static func detect(_ audio: URL, among candidates: [MeetingLanguage]) async throws -> LanguageDecision {
        guard candidates.count > 1 else { return LanguageDecision(only: candidates.first ?? .current) }
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("language-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: sample) }
        guard try SpeechSample.write(from: audio, to: sample) > 0 else { return LanguageDecision(scores: [], among: candidates) }
        var scores: [LanguageScore] = []
        for language in candidates {
            scores.append(score(try? await AppleSpeechEngine(language: language).transcribe(sample) { _ in }, as: language,
                                among: candidates))
        }
        return LanguageDecision(scores: scores, among: candidates)
    }

    private static func score(_ transcript: Transcript?, as language: MeetingLanguage,
                              among candidates: [MeetingLanguage]) -> LanguageScore {
        let text = transcript?.text ?? ""
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map(\.naturalLanguage)
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: candidates.count)
        return LanguageScore(language: language, words: text.split(whereSeparator: \.isWhitespace).count,
                             confidence: transcript?.confidence, reads: hypotheses[language.naturalLanguage] ?? 0)
    }
}

extension MeetingLanguage {
    var naturalLanguage: NLLanguage { NLLanguage(rawValue: code) }
}

/// Up to `LanguageLogic.sampleLength` of a recording's speech, from windows spread across it so a long meeting is not judged
/// by its first minute alone; silence is left out.
enum SpeechSample {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private static let chunk: TimeInterval = 0.5

    /// Writes the sample to `url` and returns its length in seconds.
    @discardableResult
    static func write(from audio: URL, to url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: audio)
        let rate = file.processingFormat.sampleRate
        let windows = LanguageLogic.sampleWindows(duration: Double(file.length) / rate)
        let normalizer = PCMNormalizer(format: format)
        let chunkFrames = AVAudioFrameCount(chunk * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { return 0 }
        var samples: [Float] = []
        for window in windows {
            file.framePosition = AVAudioFramePosition(window.start * rate)
            let end = AVAudioFramePosition(window.end * rate)
            var kept = 0.0
            while kept < window.length, file.framePosition < min(end, file.length) {
                try file.read(into: buffer, frameCount: chunkFrames)
                let chunk = normalizer.samples(from: buffer)
                var level = LevelMeter()
                level.add(chunk)
                guard level.rms >= LevelMeter.soundThreshold else { continue }
                samples += chunk
                kept += Double(chunk.count) / format.sampleRate
            }
        }
        guard !samples.isEmpty, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return 0 }
        output.frameLength = output.frameCapacity
        samples.withUnsafeBufferPointer { output.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: output)
        return Double(samples.count) / format.sampleRate
    }
}

extension LanguageDetector {
    /// `--detect-language <file>`: prints the decision and every candidate's score, then exits.
    static func runFromCommandLine(_ audio: URL, among candidates: [MeetingLanguage]) -> Never {
        Task {
            do {
                let started = Date()
                let decision = try await detect(audio, among: candidates)
                for score in decision.scores {
                    print(String(format: "%@: %d words, confidence %@, reads as %.3f, score %.3f", score.language.displayName,
                                 score.words, score.confidence.map { String(format: "%.3f", $0) } ?? "-", score.reads, score.value))
                }
                print("Language: \(decision.summary) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
