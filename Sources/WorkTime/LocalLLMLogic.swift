import Foundation

/// A language model WorkTime runs itself with llama.cpp, downloaded from Hugging Face as GGUF. Add one to `all` to offer
/// it in Settings; the first one downloaded is used.
struct LocalLLMModel: DownloadableModel {
    let id: String
    let name: String
    let repo: String
    let file: String
    let bytes: Int64
    let sha256: String
    var hint: String? = nil

    static let all = [
        LocalLLMModel(id: "ministral-3-8b-instruct-2512-q4_k_m", name: "Ministral 3 8B", repo: "mistralai/Ministral-3-8B-Instruct-2512-GGUF",
                      file: "Ministral-3-8B-Instruct-2512-Q4_K_M.gguf", bytes: 5_198_911_904,
                      sha256: "33e7a72cf5e6e2cfc2f2847075acc013d68bba023e35310cef86b5cf8fdca761", hint: "4-bit, about 6 GB of memory while loaded"),
    ]

    static func with(id: String) -> LocalLLMModel? { all.first { $0.id == id } }

    static func installed(in folder: URL = AppPaths.models) -> LocalLLMModel? { all.first { $0.isInstalled(in: folder) } }
}

enum LocalLLMError: LocalizedError, Equatable {
    case unavailable
    case notInstalled
    case couldNotLoad(String)
    case tooLong(tokens: Int)
    case cutOff
    case badGrammar
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This build of WorkTime does not include llama.cpp."
        case .notInstalled: return "Ministral is not downloaded. Download it in Settings."
        case .couldNotLoad(let name): return "\(name) could not be loaded. Remove it and download it again in Settings."
        case .tooLong(let tokens): return "the prompt is \(tokens) tokens, more than fits in the context window"
        case .cutOff: return "the answer did not fit in the context window"
        case .badGrammar: return "the output grammar could not be parsed"
        case .emptyTranscript: return "the transcript is empty"
        }
    }
}

enum LocalLLMLogic {
    static let contextTokens = 16384
    static let idleUnload: TimeInterval = 180
    static let temperature: Float = 0.2

    static var maxCharacters: Int { ProcessingLogic.chunkCharacters(contextSize: contextTokens) }

    /// A meeting summary from a local model: `answer` takes the system prompt and the user prompt and returns JSON text.
    static func summarise(_ lines: [String], language: MeetingLanguage, maxCharacters: Int = maxCharacters,
                          progress: @MainActor (ProcessingStage) -> Void,
                          answer: (_ system: String, _ prompt: String) async throws -> String) async throws -> MeetingSummary {
        let system = ClaudeSummarizer.instructions(language: language)
        let summary = try await ProcessingLogic.summariseInParts(lines, maxCharacters: maxCharacters, language: language,
                                                                 progress: progress) { prompt in
            try ClaudeSummarizer.parse(try await answer(system, prompt))
        }
        guard let summary else { throw LocalLLMError.emptyTranscript }
        return summary
    }

    /// A GBNF grammar that only lets the model write JSON matching `schema`: objects (required properties in order, then
    /// optional ones), arrays, strings, string enums, numbers and booleans.
    static func grammar(schema: [String: Any]) -> String {
        var rules: [(name: String, body: String)] = []

        func expression(_ schema: [String: Any], name: String) -> String {
            if let values = schema["enum"] as? [String] {
                return "(" + values.map { literal(json($0)) }.joined(separator: " | ") + ") ws"
            }
            switch schema["type"] as? String {
            case "object":
                let properties = schema["properties"] as? [String: Any] ?? [:]
                let required = (schema["required"] as? [String] ?? []).filter { properties[$0] != nil }
                let optional = properties.keys.filter { !required.contains($0) }.sorted()
                let pair = { (key: String) in
                    literal(json(key)) + " ws \":\" ws " + rule(properties[key] as? [String: Any] ?? [:], name: name + "-" + key)
                }
                let first = (required.isEmpty ? optional.prefix(1) : required.prefix(1)).map(pair)
                let rest = (required.isEmpty ? optional.dropFirst() : required.dropFirst()).map { "\",\" ws " + pair($0) }
                    + (required.isEmpty ? [] : optional.map { "(\",\" ws " + pair($0) + ")?" })
                return (["\"{\" ws"] + first + rest + ["\"}\" ws"]).joined(separator: " ")
            case "array":
                let item = rule(schema["items"] as? [String: Any] ?? [:], name: name + "-item")
                return "\"[\" ws (\(item) (\",\" ws \(item))*)? \"]\" ws"
            case "integer": return "\"-\"? [0-9]+ ws"
            case "number": return "\"-\"? [0-9]+ (\".\" [0-9]+)? ([eE] [-+]? [0-9]+)? ws"
            case "boolean": return "(\"true\" | \"false\") ws"
            default: return "string"
            }
        }

        func rule(_ schema: [String: Any], name: String) -> String {
            let body = expression(schema, name: name)
            guard body != "string" else { return body }
            let name = String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            rules.append((name, body))
            return name
        }

        let root = expression(schema, name: "root")
        return (["root ::= " + root] + rules.map { "\($0.name) ::= \($0.body)" } + [
            #"string ::= "\"" ([^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\"" ws"#,
            #"ws ::= | " " | "\n" [ \t]{0,20}"#,
        ]).joined(separator: "\n") + "\n"
    }

    /// `value` as a JSON string literal.
    private static func json(_ value: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) ?? Data(), as: UTF8.self)
    }

    /// `text` as a GBNF literal.
    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
