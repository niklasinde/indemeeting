import Foundation

/// Summarises a meeting with a local model served by Ollama, with the same instructions, schema and parsing as Claude.
enum OllamaSummarizer {
    struct Failure: LocalizedError, Equatable {
        let message: String

        var errorDescription: String? { "Ministral could not summarise this meeting: \(message)" }
    }

    static let baseURL = URL(string: "http://localhost:11434")!
    static let model = "ministral-3:8b"
    static let contextTokens = 16384
    static let keepAlive = "1m"
    static let temperature = 0.2
    static let timeout: TimeInterval = 900
    static let probeTimeout: TimeInterval = 3

    static var maxCharacters: Int { ProcessingLogic.chunkCharacters(contextSize: contextTokens) }

    static func requestBody(system: String, prompt: String) -> [String: Any] {
        ["model": model, "stream": false, "keep_alive": keepAlive, "format": ClaudeSummarizer.schema,
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

    /// The summary in an `/api/chat` reply envelope.
    static func summary(fromReply data: Data) throws -> MeetingSummary {
        struct Reply: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message?
            let error: String?
            let done_reason: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure(message: "the reply was not JSON") }
        if let error = reply.error { throw Failure(message: error) }
        if reply.done_reason == "length" { throw Failure(message: "the summary did not fit in the context window") }
        guard let content = reply.message?.content, let summary = try? ClaudeSummarizer.parse(content) else {
            throw Failure(message: "the reply held no summary")
        }
        return summary
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
        let system = ClaudeSummarizer.instructions(language: language)
        let summary = try await ProcessingLogic.summariseInParts(lines, maxCharacters: maxCharacters, language: language,
                                                                 progress: progress) { prompt in
            try await respond(system: system, prompt: prompt)
        }
        guard let summary else { throw Failure(message: "the transcript is empty") }
        return summary
    }

    private static func respond(system: String, prompt: String) async throws -> MeetingSummary {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(system: system, prompt: prompt))
        let (data, _) = try await URLSession.shared.data(for: request)
        return try summary(fromReply: data)
    }
}
