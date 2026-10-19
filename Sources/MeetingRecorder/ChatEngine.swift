import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ChatUnavailable: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

#if canImport(FoundationModels)
/// A conversation with the on-device model about one scope. Holds the session and its history; when the context window
/// is full the next session starts from a recap of the latest turns.
final class ChatEngine {
    let scope: ChatScope
    private let store: MeetingStore
    private let model = SystemLanguageModel.default
    private let now: () -> Date
    private var session: LanguageModelSession?
    private var history: [ChatMessage]
    private let toolReport = ToolReport()

    init(store: MeetingStore, scope: ChatScope, history: [ChatMessage] = [], now: @escaping () -> Date = Date.init) {
        self.store = store
        self.scope = scope
        self.history = history
        self.now = now
    }

    static var unavailable: SummaryNotice? { Summarizer.unavailableReason(for: .current).map(SummaryNotice.init) }

    private var budget: ChatBudget { ChatBudget(contextSize: model.contextSize) }

    /// Answers `prompt`, calling `onText` with the whole answer so far and `onTool` with a note of each lookup. If the context
    /// window overflows once, `onFreshContext` is called and the question is asked again in a fresh session.
    func ask(_ prompt: String, onText: @escaping @Sendable (String) -> Void, onTool: @escaping @Sendable (String) -> Void,
             onFreshContext: @Sendable () -> Void = {}) async throws -> String {
        if let reason = Self.unavailable { throw ChatUnavailable(reason.title) }
        toolReport.handler = onTool
        let modelPrompt = try prefetched(prompt, onTool: onTool)
        for attempt in 0...1 {
            do {
                let session = try session ?? makeSession()
                var answer = ""
                for try await snapshot in session.streamResponse(to: modelPrompt, options: GenerationOptions(temperature: 0.3)) {
                    answer = snapshot.content
                    onText(answer)
                }
                remember(prompt, answer)
                return answer
            } catch {
                let generation = ((error as? LanguageModelSession.ToolCallError)?.underlyingError ?? error) as? LanguageModelSession.GenerationError
                guard case .exceededContextWindowSize? = generation else { throw generation.map(Self.explained) ?? error }
                guard attempt == 0 else {
                    throw ChatUnavailable("That needed more than the model can hold at once. Ask about something narrower.")
                }
                session = nil
                onFreshContext()
            }
        }
        throw ChatUnavailable("No answer")
    }

    /// In a chat about one meeting the transcript lines that best match the question go along with it, so times and
    /// speakers in the answer come from the transcript even when the model does not search by itself.
    private func prefetched(_ question: String, onTool: @Sendable (String) -> Void) throws -> String {
        guard scope.kind == .meeting, !question.contains("scan_transcript"), let id = scope.id,
              let meeting = try store.meeting(id: id), let content = try store.content(of: meeting.audioFile),
              let found = ChatLogic.prefetch(question, content: content, maxCharacters: budget.toolOutput / 2) else { return question }
        onTool(found.note)
        return question + "\n\nTranscript lines that may help (time, speaker, text):\n" + found.lines.joined(separator: "\n")
    }

    /// The answer so far when the user stopped it.
    func remember(_ prompt: String, _ answer: String) {
        let stamp = now()
        history.append(ChatMessage(id: 0, role: .user, text: prompt, toolNote: nil, created: stamp))
        if !answer.isEmpty { history.append(ChatMessage(id: 0, role: .assistant, text: answer, toolNote: nil, created: stamp)) }
    }

    /// A short title for a chat that begins with `question`.
    static func title(for question: String) async -> String? {
        guard unavailable == nil else { return nil }
        let session = LanguageModelSession(model: .default, instructions: """
            Write a title of at most five words for a chat that starts with the user\u{2019}s message. \
            Use the language of the message. Reply with the title only.
            """)
        guard let response = try? await session.respond(to: question, options: GenerationOptions(temperature: 0.2)) else { return nil }
        return ChatLogic.cleanTitle(response.content)
    }

    private func makeSession() throws -> LanguageModelSession {
        let budget = budget
        let overview = try ChatToolbox.overview(for: scope, store: store, budget: budget, now: now())
        let recap = ChatLogic.recap(history, maxCharacters: budget.recap)
        let instructions = ChatLogic.instructions(scope: scope, overview: overview, recap: recap, now: now())
        var tools: [any Tool] = ChatToolbox.tools(for: scope, store: store, budget: budget, now: now).map { ModelTool(tool: $0, report: toolReport) }
        if let id = scope.meetingID, let meeting = try store.meeting(id: id), let content = try store.content(of: meeting.audioFile) {
            let language = meeting.language ?? .current
            tools.append(ScanTool(lines: content.segments.map { $0.line(language, names: content.names) }, budget: budget, report: toolReport))
        }
        let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        self.session = session
        return session
    }

    private static func explained(_ error: LanguageModelSession.GenerationError) -> Error {
        switch error {
        case .guardrailViolation: return ChatUnavailable("Apple Intelligence declined to answer that. Try rephrasing the question.")
        case .unsupportedLanguageOrLocale: return ChatUnavailable("Apple Intelligence does not support the language of that message.")
        case .rateLimited: return ChatUnavailable("Apple Intelligence is busy. Try again in a moment.")
        default: return error
        }
    }
}

final class ToolReport: @unchecked Sendable {
    var handler: (@Sendable (String) -> Void)?

    func callAsFunction(_ note: String) { handler?(note) }
}

/// An `MCPTool` offered to the model; its arguments come from the model as generated content.
private struct ModelTool: Tool, @unchecked Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let tool: MCPTool
    let report: ToolReport

    var name: String { tool.name }
    var description: String { tool.description }

    var parameters: GenerationSchema {
        let properties = tool.properties.sorted { $0.key < $1.key }.map { key, schema -> DynamicGenerationSchema.Property in
            let type = schema["type"] as? String
            let value: DynamicGenerationSchema = type == "integer" ? .init(type: Int.self) : type == "number" ? .init(type: Double.self) : .init(type: String.self)
            return .init(name: key, description: schema["description"] as? String, schema: value, isOptional: !tool.required.contains(key))
        }
        return try! GenerationSchema(root: DynamicGenerationSchema(name: tool.name + "Arguments", properties: properties), dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        var values: [String: Any] = [:]
        for (key, schema) in tool.properties {
            switch schema["type"] as? String {
            case "integer": values[key] = (try? arguments.value(Int?.self, forProperty: key)).flatMap { $0 }
            case "number": values[key] = (try? arguments.value(Double?.self, forProperty: key)).flatMap { $0 }
            default: values[key] = (try? arguments.value(String?.self, forProperty: key)).flatMap { $0 }
            }
        }
        let output: String
        do { output = try tool.run(values) } catch { output = "Error: \(error.localizedDescription)" }
        report(ChatLogic.note(tool: tool.name, arguments: values, output: output))
        return output
    }
}

/// Reads a whole transcript in parts that fit the context window and returns what each part holds about a focus, so broad
/// questions about a long meeting do not depend on one call seeing everything.
private struct ScanTool: Tool, @unchecked Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let lines: [String]
    let budget: ChatBudget
    let report: ToolReport

    var name: String { "scan_transcript" }
    var description: String {
        "Reads the whole transcript of this meeting part by part and returns what is relevant to the focus, with speaker and time. "
            + "Use it for broad questions such as decisions, action items, open questions or a follow-up."
    }

    var parameters: GenerationSchema {
        let focus = DynamicGenerationSchema.Property(name: "focus", description: "What to look for, in a few words.", schema: .init(type: String.self))
        return try! GenerationSchema(root: DynamicGenerationSchema(name: "ScanArguments", properties: [focus]), dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let focus = (try? arguments.value(String.self, forProperty: "focus")) ?? "the main points"
        let output = await scan(focus)
        report(ChatLogic.note(tool: name, arguments: ["focus": focus], output: output))
        return output
    }

    private func scan(_ focus: String) async -> String {
        guard !lines.isEmpty else { return "The meeting has no transcript.\n" }
        var found: [String] = []
        for part in ProcessingLogic.chunks(lines, maxCharacters: budget.chunk) {
            if let notes = await extract("Focus: \(focus)\n\nTranscript part:\n\(part)", instructions: Self.extractInstructions) { found.append(notes) }
        }
        guard !found.isEmpty else { return "Nothing in the transcript is about \u{201C}\(focus)\u{201D}.\n" }
        var combined = found.joined(separator: "\n")
        for _ in 0..<2 where combined.count > budget.toolOutput {
            var merged: [String] = []
            for group in ProcessingLogic.chunks(combined.components(separatedBy: "\n"), maxCharacters: budget.chunk) {
                merged.append(await extract(group, instructions: Self.mergeInstructions) ?? group)
            }
            combined = merged.joined(separator: "\n")
        }
        return combined + "\n"
    }

    private func extract(_ prompt: String, instructions: String) async -> String? {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        guard let text = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 600)).content else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("Nothing") ? nil : trimmed
    }

    private static let extractInstructions = """
        You read one part of a meeting transcript. Reply with a short bullet list of only what is relevant to the focus, \
        each bullet ending with the speaker and the time stamp of the line it comes from, copied from the text, in the form (speaker, time). Use only the text; do not invent. \
        Write in the language of the transcript. If nothing is relevant reply exactly: Nothing
        """

    private static let mergeInstructions = """
        You merge bullet lists taken from consecutive parts of one meeting. Reply with one bullet list without duplicates. \
        Keep every speaker and time in brackets. Do not add anything.
        """
}
#endif
