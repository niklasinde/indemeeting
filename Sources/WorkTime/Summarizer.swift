import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

enum Summarizer {
    /// Tries the engine chosen in Settings, then the others, skipping any that is not available. With none left, the
    /// first failure is thrown, or why Apple Intelligence is unavailable when nothing ran.
    static func summarise(_ segments: [TranscriptSegment], names: SpeakerNames = [:], language: MeetingLanguage,
                          progress: @escaping @MainActor (ProcessingStage) -> Void) async throws
        -> (summary: MeetingSummary, engine: SummaryEngine) {
        let lines = segments.map { $0.line(language, names: names) }
        var failure: Error?
        for engine in SummaryEngine.order(chosen: .stored()) {
            do {
                if let summary = try await summarise(lines, with: engine, language: language, progress: progress) {
                    return (summary, engine)
                }
            } catch {
                log("Summarising with \(engine.displayName) failed: \(ProcessingLogic.errorDetails(error))")
                failure = failure ?? error
            }
        }
        throw failure ?? unavailableReason(for: language) ?? ClaudeSummarizer.Failure.unavailable
    }

    /// The engine's summary, or nil when it is not available.
    private static func summarise(_ lines: [String], with engine: SummaryEngine, language: MeetingLanguage,
                                  progress: @MainActor (ProcessingStage) -> Void) async throws -> MeetingSummary? {
        switch engine {
        case .ministral:
            guard LocalLLM.isAvailable else { return nil }
            return try await LocalLLM.summarise(lines, language: language, progress: progress)
        case .ollama:
            guard OllamaSummarizer.isAllowed(), await OllamaSummarizer.isAvailable() else { return nil }
            return try await OllamaSummarizer.summarise(lines, language: language, progress: progress)
        case .claude:
            guard ClaudeSummarizer.isAvailable else { return nil }
            await progress(.summarisingWithClaude)
            return try await ClaudeSummarizer.summarise(lines, language: language)
        case .apple:
            #if canImport(FoundationModels)
            guard unavailableReason(for: language) == nil else { return nil }
            do {
                return try await OnDeviceSummarizer(language: language).summarise(lines, progress: progress)
            } catch where ClaudeSummarizer.shouldFallBack(error) {
                throw ClaudeSummarizer.Failure.unavailable
            }
            #else
            return nil
            #endif
        }
    }

    private static func log(_ message: String) {
        Logger(subsystem: "MeetingRecorder", category: "processing").notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func unavailableReason(for language: MeetingLanguage) -> SummaryUnavailable? {
        #if canImport(FoundationModels)
        return OnDeviceSummarizer.unavailableReason(SystemLanguageModel.default, language: language)
        #else
        return .requiresMacOS26
        #endif
    }

    /// Whether Apple Intelligence is off or still downloading, so meetings can be summarised once it is ready.
    static var isWaitingForModel: Bool {
        switch unavailableReason(for: .current) {
        case .modelNotReady, .appleIntelligenceOff, .languageMismatch: return true
        default: return false
        }
    }

    static var siriLanguage: String? {
        UserDefaults(suiteName: "com.apple.assistant.backedup")?.string(forKey: "Session Language")
    }

    /// Returns once Apple Intelligence is available, watching the model and checking every minute in case no change
    /// is reported.
    static func waitUntilAvailable() async {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await available in Observations({ model.isAvailable }) where available { return } }
            group.addTask { while !model.isAvailable, !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) } }
            await group.next()
            group.cancelAll()
        }
        #endif
    }
}

#if canImport(FoundationModels)
private struct OnDeviceSummarizer {
    let language: MeetingLanguage
    private let model = SystemLanguageModel.default

    init(language: MeetingLanguage) throws {
        self.language = language
        if let reason = Self.unavailableReason(model, language: language) { throw reason }
    }

    static func unavailableReason(_ model: SystemLanguageModel, language: MeetingLanguage) -> SummaryUnavailable? {
        switch model.availability {
        case .available: return model.supportsLocale(language.locale) ? nil : .unsupportedLanguage(language)
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable:
            return .notReady(macLanguage: Locale.preferredLanguages.first, siriLanguage: Summarizer.siriLanguage)
        }
    }

    private var maxCharacters: Int { ProcessingLogic.chunkCharacters(contextSize: model.contextSize) }

    func summarise(_ lines: [String], progress: @MainActor (ProcessingStage) -> Void) async throws -> MeetingSummary {
        let summary = try await ProcessingLogic.summariseInParts(lines, maxCharacters: maxCharacters, language: language,
                                                                 progress: progress, respond: respond)
        guard let summary else { throw TranscriptionError.noSpeech("the transcript") }
        return summary
    }

    private var instructions: String { ClaudeSummarizer.instructions(language: language) }

    private func respond(_ prompt: String) async throws -> MeetingSummary {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: prompt, schema: Self.schema,
                                                 options: GenerationOptions(temperature: 0.2))
        return try MeetingSummary.decode(json: response.content.jsonString)
    }

    private static let schema: GenerationSchema = {
        let text = DynamicGenerationSchema(type: String.self)
        let list = DynamicGenerationSchema(arrayOf: text)
        let actionItem = DynamicGenerationSchema(name: "ActionItem", properties: [
            .init(name: "task", schema: text),
            .init(name: "owner", description: "Person responsible, only if named", schema: text, isOptional: true),
        ])
        let topic = DynamicGenerationSchema(name: "Topic", properties: [
            .init(name: "title", schema: text),
            .init(name: "points", schema: list),
        ])
        let root = DynamicGenerationSchema(name: "MeetingSummary", properties: [
            .init(name: "title", schema: text),
            .init(name: "actionItems", schema: DynamicGenerationSchema(arrayOf: actionItem)),
            .init(name: "topics", schema: DynamicGenerationSchema(arrayOf: topic)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }()
}
#endif
