import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum Summarizer {
    static func summarise(_ segments: [TranscriptSegment], names: SpeakerNames = [:], language: MeetingLanguage,
                          progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> MeetingSummary {
        #if canImport(FoundationModels)
        return try await OnDeviceSummarizer(language: language)
            .summarise(segments.map { $0.line(language, names: names) }, progress: progress)
        #else
        throw SummaryUnavailable.requiresMacOS26
        #endif
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
        let parts = ProcessingLogic.chunks(lines, maxCharacters: maxCharacters)
        var summaries: [MeetingSummary] = []
        for (index, part) in parts.enumerated() {
            await progress(.summarising(part: index + 1, of: parts.count))
            let intro = parts.count > 1 ? "Part \(index + 1) of \(parts.count) of a meeting transcript" : "Meeting transcript"
            summaries.append(try await respond("\(intro):\n\n\(part)"))
        }
        while summaries.count > 1 {
            await progress(.combining)
            let notes = summaries.map { ProcessingLogic.summaryMarkdown($0, audioName: nil, language: language) }
            var groups = ProcessingLogic.chunks(notes, maxCharacters: maxCharacters)
            if groups.count >= summaries.count { groups = [notes.joined(separator: "\n\n")] }
            var combined: [MeetingSummary] = []
            for group in groups {
                combined.append(try await respond("Summaries of consecutive parts of one meeting. Combine them into one summary of the whole meeting:\n\n\(group)"))
            }
            summaries = combined
        }
        guard let summary = summaries.first else { throw TranscriptionError.noSpeech("the transcript") }
        return summary
    }

    private var instructions: String {
        let you = Speaker.you.name(in: language), others = Speaker.others.name(in: language)
        let speaker = Speaker.numbered(1).name(in: language)
        return """
        You write meeting notes from transcripts. Write every field in \(language.englishName). \
        Use only information from the input; do not invent facts, names or owners. \
        Transcript lines may name their speaker: "\(you)" is the user who recorded the meeting, \
        "\(others)" and numbered speakers such as "\(speaker)" are other participants, any other name is a participant \
        with that name. \
        title: a short title of at most eight words naming the kind of meeting and its main subjects, \
        e.g. "Daily standup \u{2013} bug fixes, validation and release". \
        actionItems: concrete follow-ups, each task starting with a verb and keeping any deadline; \
        owner: the first name of the person who will do it, only when the input names them or they speak the line, \
        or "\(you)" when the user takes it on. \
        topics: the two to five main subjects in the order discussed; each with a short title and two to five \
        brief points holding the facts, numbers and decisions.
        """
    }

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
