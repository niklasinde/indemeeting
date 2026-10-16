import AVFoundation
import Speech

enum TranscriptionError: LocalizedError {
    case unsupportedLanguage(MeetingLanguage)
    case noSpeech(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language): return "On-device transcription does not support \(language.englishName) on this Mac."
        case .noSpeech(let name): return "No speech was recognised in \(name)."
        }
    }
}

struct Transcript {
    let segments: [TranscriptSegment]
    let engine: String
}

typealias TranscriptionProgress = @Sendable (Double) -> Void

protocol SpeechEngine {
    func transcribe(_ audio: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript
}

enum Transcriber {
    static func engine(for language: MeetingLanguage) throws -> any SpeechEngine {
        switch TranscriptionEngine.current(for: language) {
        case .apple: return AppleSpeechEngine(language: language)
        case .whisper(let model): return try WhisperEngine(model: model, language: language)
        }
    }

    /// A meeting with stems is transcribed per stem, so every segment has a speaker; others from the mix.
    static func transcribeMeeting(_ audio: URL, language: MeetingLanguage,
                                  progress: @escaping TranscriptionProgress = { _ in }) async throws -> Transcript {
        let engine = try engine(for: language)
        guard let stems = RecordingLogic.stems(of: audio) else { return try await engine.transcribe(audio, progress: progress) }
        var transcripts: [Transcript?] = []
        for (index, stem) in stems.enumerated() {
            transcripts.append(try await transcribeSpeech(stem, engine) { progress((Double(index) + $0) / Double(stems.count)) })
        }
        let segments = ProcessingLogic.mergeSpeakers(you: transcripts[AudioSource.microphone.rawValue]?.segments ?? [],
                                                     others: transcripts[AudioSource.system.rawValue]?.segments ?? [])
        guard let engine = transcripts.lazy.compactMap({ $0?.engine }).first, !segments.isEmpty else {
            throw TranscriptionError.noSpeech(audio.lastPathComponent)
        }
        return Transcript(segments: segments, engine: engine)
    }

    private static func transcribeSpeech(_ audio: URL, _ engine: any SpeechEngine,
                                         progress: @escaping TranscriptionProgress) async throws -> Transcript? {
        do {
            return try await engine.transcribe(audio, progress: progress)
        } catch TranscriptionError.noSpeech {
            return nil
        }
    }
}

private protocol TextResult: SpeechModuleResult {
    var text: AttributedString { get }
}

extension SpeechTranscriber.Result: TextResult {}

extension DictationTranscriber.Result: TextResult {}

/// The on-device speech module for a language: SpeechTranscriber where it supports the locale, otherwise dictation.
enum SpeechModel {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    static func make(for language: MeetingLanguage) async -> SpeechModel? {
        let locale = language.locale
        if await supports(SpeechTranscriber.supportedLocales, locale) {
            return .speech(SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                             attributeOptions: [.audioTimeRange]))
        }
        if await supports(DictationTranscriber.supportedLocales, locale) {
            return .dictation(DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation))
        }
        return nil
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let module): return module
        case .dictation(let module): return module
        }
    }

    private static func supports(_ locales: [Locale], _ locale: Locale) -> Bool {
        locales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }
}

private struct AppleSpeechEngine: SpeechEngine {
    let language: MeetingLanguage

    func transcribe(_ audio: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        switch await SpeechModel.make(for: language) {
        case .speech(let module): return Transcript(segments: try await run(module, audio), engine: "SpeechTranscriber")
        case .dictation(let module): return Transcript(segments: try await run(module, audio), engine: "DictationTranscriber")
        case nil: throw TranscriptionError.unsupportedLanguage(language)
        }
    }

    private func run<Module: SpeechModule>(_ module: Module, _ audio: URL) async throws -> [TranscriptSegment]
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
