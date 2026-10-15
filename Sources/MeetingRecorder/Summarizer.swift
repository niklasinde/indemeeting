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
                .summarise(segments.map(\.line), progress: progress)
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
            var groups = ProcessingLogic.chunks(summaries.map(\.notes), maxCharacters: maxCharacters)
            if groups.count >= summaries.count { groups = [summaries.map(\.notes).joined(separator: "\n\n")] }
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
        """
        You summarise meeting transcripts. Write every field in \(language.englishName). \
        Use only information from the input; do not invent facts, names or owners. \
        title: a short descriptive meeting title. summary: two to four sentences. \
        keyPoints: the main topics and facts. decisions: decisions that were made, empty if none. \
        actionItems: concrete follow-ups; owner only when the input names who will do it.
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
        let root = DynamicGenerationSchema(name: "MeetingSummary", properties: [
            .init(name: "title", schema: text),
            .init(name: "summary", schema: text),
            .init(name: "keyPoints", schema: list),
            .init(name: "decisions", schema: list),
            .init(name: "actionItems", schema: DynamicGenerationSchema(arrayOf: actionItem)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }()
}
#endif
