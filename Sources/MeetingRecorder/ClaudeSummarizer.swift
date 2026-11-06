import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summarises a meeting with Claude when Apple's on-device model declines to: through the API with the user's key, else
/// through the local `claude` CLI.
enum ClaudeSummarizer {
    enum Route: Equatable {
        case api(key: String)
        case cli(URL)
    }

    struct Failure: LocalizedError, Equatable {
        let message: String

        var errorDescription: String? { message }

        static let unavailable = Failure(message: "Apple Intelligence declined to summarise this meeting. Add an Anthropic API key "
                                         + "in Settings or install the Claude CLI to summarise it with Claude.")

        static func failed(_ reason: String) -> Failure {
            Failure(message: "Apple Intelligence declined to summarise this meeting, and Claude could not either: \(reason)")
        }
    }

    static let model = "claude-opus-5-5"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let maxTokens = 64000
    static let timeout: TimeInterval = 600

    /// Whether the on-device model refused the content, as opposed to being unavailable or failing for another reason.
    static func shouldFallBack(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return true
            default: return false
            }
        }
        #endif
        return false
    }

    static func route(key: String?, cli: URL?) -> Route? {
        if let key, !key.isEmpty { return .api(key: key) }
        return cli.map(Route.cli)
    }

    /// The instructions both Apple's model and Claude get.
    static func instructions(language: MeetingLanguage) -> String {
        let you = Speaker.you.name(in: language), others = Speaker.others.name(in: language)
        let speaker = Speaker.numbered(1).name(in: language)
        return """
        You write meeting notes from transcripts. Write every field in \(language.englishName). \
        Use only information from the input; do not invent facts, names or owners. \
        Transcript lines may name their speaker: "\(you)" is the user who recorded the meeting, \
        "\(others)" and numbered speakers such as "\(speaker)" are other participants, any other name is a participant \
        with that name. \
        title: a short natural phrase in \(language.englishName) of at most eight words naming the concrete thing decided or discussed, \
        e.g. "Procounter-integrationen går via Strawbay" or "Release moves to Friday after two bugs"; \
        not a "Topic \u{2013} A and B" list and no generic words such as "Integration", "Diskussion", "Meeting" or "Möte". \
        actionItems: concrete follow-ups, each task starting with a verb and keeping any deadline; \
        owner: the first name of the person who will do it, only when the input names them or they speak the line, \
        or "\(you)" when the user takes it on. The owner is the speaker who commits ("jag ska…", \
        "då säger jag det till X" belong to whoever says it); advice to someone else ("du kan ju fråga X") \
        belongs to the person advised; passing tips ("man kan kolla med Claude") are not action items. \
        topics: the two to five main subjects in the order discussed; each with a short title and two to five \
        brief points holding the facts, numbers and decisions.
        """
    }

    static func prompt(_ lines: [String]) -> String {
        "Meeting transcript:\n\n" + lines.joined(separator: "\n")
    }

    static let schema: [String: Any] = {
        let text: [String: Any] = ["type": "string"]
        let actionItem: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["task"],
                                         "properties": ["task": text, "owner": text]]
        let topic: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["title", "points"],
                                    "properties": ["title": text, "points": ["type": "array", "items": text]]]
        return ["type": "object", "additionalProperties": false, "required": ["title", "actionItems", "topics"],
                "properties": ["title": text, "actionItems": ["type": "array", "items": actionItem],
                               "topics": ["type": "array", "items": topic]]]
    }()

    /// The Messages API fields beyond the chat's: medium effort, the summary's JSON schema and the server-side fallback.
    static var requestFields: [String: Any] {
        ["output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]], "fallbacks": "default"]
    }

    static func cliArguments(system: String, prompt: String) -> [String] {
        let shape = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return ["-p", prompt, "--system-prompt", system + "\n\nAnswer with only a JSON object matching this JSON schema, and no other text: " + shape,
                "--output-format", "json", "--permission-mode", "dontAsk", "--no-session-persistence", "--setting-sources", "",
                "--max-budget-usd", GitHubClaude.budgetLimit, "--model", model]
    }

    /// The summary in a reply, which may wrap its JSON object in a code fence or a sentence.
    static func parse(_ text: String) throws -> MeetingSummary {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw Failure.failed("the reply held no summary")
        }
        return try MeetingSummary.decode(json: String(text[start...end]))
    }

    static func summarise(_ lines: [String], language: MeetingLanguage) async throws -> MeetingSummary {
        guard let route = route(key: ClaudeAPIKeyStore.live.key(), cli: ClaudePlugin.findCLI()) else { throw Failure.unavailable }
        let system = instructions(language: language), prompt = prompt(lines)
        switch route {
        case .api(let key):
            log("Summarising with \(model) through the Anthropic API")
            return try await viaAPI(key: key, system: system, prompt: prompt)
        case .cli(let cli):
            log("Summarising with \(model) through the Claude CLI")
            return try await viaCLI(cli, system: system, prompt: prompt)
        }
    }

    private static func viaAPI(key: String, system: String, prompt: String) async throws -> MeetingSummary {
        let options = ClaudeAPIClient.Options(maxTokens: maxTokens, extra: requestFields, betas: [fallbackBeta], timeout: timeout)
        var text = ""
        do {
            for try await event in ClaudeAPIClient().reply(key: key, model: model, system: system,
                                                           messages: [ClaudeAPIMessage(role: .user, text: prompt)], options: options) {
                if case .text(let piece) = event { text += piece }
            }
        } catch let error as ClaudeAPIError {
            throw Failure.failed(error.message)
        }
        return try parse(text)
    }

    private static func viaCLI(_ cli: URL, system: String, prompt: String) async throws -> MeetingSummary {
        let box = CLIResult()
        let outcome = await ClaudeProcess().run(cli: cli, arguments: cliArguments(system: system, prompt: prompt),
                                                directory: FileManager.default.temporaryDirectory,
                                                environment: ClaudePluginModel.environment(for: cli), timeout: timeout) { box.consume($0) }
        let stream = box.stream
        if outcome.timedOut { throw Failure.failed(GitHubClaude.Failure.timedOut.message) }
        guard let result = stream.result, !result.isError, !result.text.isEmpty else {
            throw Failure.failed(GitHubClaude.failure(stream.result?.text ?? outcome.stderr).message)
        }
        return try parse(result.text)
    }

    private static func log(_ message: String) {
        Logger(subsystem: "MeetingRecorder", category: "processing").notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private final class CLIResult: @unchecked Sendable {
    private let lock = NSLock()
    private var current = GitHubClaude.Stream()

    func consume(_ line: String) {
        lock.lock()
        current.consume(line)
        lock.unlock()
    }

    var stream: GitHubClaude.Stream {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}
