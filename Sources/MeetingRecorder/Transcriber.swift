import AVFoundation
import Speech

enum TranscriptionError: LocalizedError {
    case requiresMacOS26
    case unsupportedLanguage(MeetingLanguage)
    case noSpeech(String)

    var errorDescription: String? {
        switch self {
        case .requiresMacOS26: return "On-device transcription needs macOS 26 or later."
        case .unsupportedLanguage(let language): return "On-device transcription does not support \(language.englishName) on this Mac."
        case .noSpeech(let name): return "No speech was recognised in \(name)."
        }
    }
}

struct Transcript {
    let segments: [TranscriptSegment]
    let engine: String
}

enum Transcriber {
    static func transcribe(_ audio: URL, language: MeetingLanguage) async throws -> Transcript {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.requiresMacOS26 }
        return try await SpeechAnalyzerTranscriber.transcribe(audio, language: language)
    }
}

@available(macOS 26.0, *)
private protocol TextResult: SpeechModuleResult {
    var text: AttributedString { get }
}

@available(macOS 26.0, *)
extension SpeechTranscriber.Result: TextResult {}

@available(macOS 26.0, *)
extension DictationTranscriber.Result: TextResult {}

@available(macOS 26.0, *)
private enum SpeechAnalyzerTranscriber {
    static func transcribe(_ audio: URL, language: MeetingLanguage) async throws -> Transcript {
        let locale = language.locale
        if await supports(SpeechTranscriber.supportedLocales, locale) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                           attributeOptions: [.audioTimeRange])
            return Transcript(segments: try await run(module, audio), engine: "SpeechTranscriber")
        }
        if await supports(DictationTranscriber.supportedLocales, locale) {
            let module = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
            return Transcript(segments: try await run(module, audio), engine: "DictationTranscriber")
        }
        throw TranscriptionError.unsupportedLanguage(language)
    }

    private static func supports(_ locales: [Locale], _ locale: Locale) -> Bool {
        locales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    private static func run<Module: SpeechModule>(_ module: Module, _ audio: URL) async throws -> [TranscriptSegment]
    where Module.Result: TextResult {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in module.results where result.isFinal {
                let pieces = result.text.runs.map { run in
                    (text: String(result.text[run.range].characters),
                     start: run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]?.start.seconds)
                }
                segments += ProcessingLogic.sentences(pieces, from: result.range.start.seconds)
            }
            return segments
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let segments = try await collector.value
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech(audio.lastPathComponent) }
        return segments
    }
}
