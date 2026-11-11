import Foundation

/// A local Ollama server, for trying models while developing: used only in developer mode or with `WORKTIME_LLM=ollama`,
/// never as a fallback in a normal install. Same instructions, schema and parsing as the other engines.
enum OllamaSummarizer {
    struct Failure: LocalizedError, Equatable {
        let message: String

        var errorDescription: String? { "Ollama could not answer: \(message)" }
    }

    static let baseURL = URL(string: "http://localhost:11434")!
    static let model = "ministral-3:8b"
    static let contextTokens = 16384
    static let keepAlive = "1m"
    static let timeout: TimeInterval = 900
    static let probeTimeout: TimeInterval = 3
    static let environmentKey = "WORKTIME_LLM"

    /// `WORKTIME_LLM=ollama`: Ollama goes first, for comparing it with the built-in model.
    static func isForced(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "ollama"
    }

    static func isAllowed(_ defaults: UserDefaults = .standard,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isForced(environment) || AudioRetention.developerMode(defaults: defaults)
    }

    static func requestBody(system: String, prompt: String, schema: [String: Any], temperature: Double = 0.2,
                            keepAlive: String = keepAlive) -> [String: Any] {
        ["model": model, "stream": false, "keep_alive": keepAlive, "format": schema,
         "options": ["temperature": temperature, "num_ctx": contextTokens],
         "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
    }

    /// Whether `/api/tags` lists the model, taking a bare name as its `latest` tag.
    static func hasModel(tags: Data, model: String = model) -> Bool {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let wanted = model.contains(":") ? model : model + ":latest"
        return (try? JSONDecoder().decode(Tags.self, from: tags))?.models.contains { $0.name == wanted } ?? false
    }

    /// The answer in an `/api/chat` reply envelope.
    static func content(fromReply data: Data) throws -> String {
        struct Reply: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message?
            let error: String?
            let done_reason: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure(message: "the reply was not JSON") }
        if let error = reply.error { throw Failure(message: error) }
        if reply.done_reason == "length" { throw Failure(message: "the answer did not fit in the context window") }
        guard let content = reply.message?.content else { throw Failure(message: "the reply held no answer") }
        return content
    }

    static func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = probeTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return hasModel(tags: data)
    }

    static func summarise(_ lines: [String], language: MeetingLanguage,
                          progress: @MainActor (ProcessingStage) -> Void) async throws -> MeetingSummary {
        try await LocalLLMLogic.summarise(lines, language: language, maxCharacters: ProcessingLogic.chunkCharacters(contextSize: contextTokens),
                                          progress: progress) { system, prompt in
            try await chat(system: system, prompt: prompt, schema: ClaudeSummarizer.schema)
        }
    }

    static func chat(system: String, prompt: String, schema: [String: Any], temperature: Double = 0.2,
                     keepAlive: String = keepAlive, timeout: TimeInterval = timeout) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(system: system, prompt: prompt, schema: schema,
                                                                                  temperature: temperature, keepAlive: keepAlive))
        return try content(fromReply: try await URLSession.shared.data(for: request).0)
    }
}
