import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum Summarizer {
    static func summarise(_ segments: [TranscriptSegment], language: MeetingLanguage,
                          progress: @escaping @MainActor (ProcessingStage) -> Void) async throws -> MeetingSummary {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await OnDeviceSummarizer(language: language)
                .summarise(segments.map { $0.line(language) }, progress: progress)
        }
        #endif
        throw SummaryUnavailable.requiresMacOS26
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private struct OnDeviceSummarizer {
    private static let reservedTokens = 2200
    private static let charactersPerToken = 3

    let language: MeetingLanguage
    private let model = SystemLanguageModel.default

    init(language: MeetingLanguage) throws {
        self.language = language
        switch model.availability {
        case .available: break
        case .unavailable(.appleIntelligenceNotEnabled): throw SummaryUnavailable.appleIntelligenceOff
        case .unavailable(.deviceNotEligible): throw SummaryUnavailable.deviceNotEligible
        case .unavailable: throw SummaryUnavailable.modelNotReady
        }
        guard model.supportsLocale(language.locale) else { throw SummaryUnavailable.unsupportedLanguage(language) }
    }

    private var maxCharacters: Int {
        max(1500, (model.contextSize - Self.reservedTokens) * Self.charactersPerToken)
    }

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
        return """
        You write meeting notes from transcripts. Write every field in \(language.englishName). \
        Use only information from the input; do not invent facts, names or owners. \
        Transcript lines may name their speaker: "\(you)" is the user who recorded the meeting, \
        "\(others)" are the other participants. \
        title: a short title of at most eight words naming the kind of meeting and its main subjects, \
        e.g. "Daily standup \u{2013} bug fixes, validation and release". \
        actionItems: concrete follow-ups, each task starting with a verb and keeping any deadline; \
        owner: the first name of the person who will do it, only when the input names them, \
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
