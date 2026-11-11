import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let localLLMTests: [(name: String, run: () throws -> Void)] = [
    ("the chosen summary engine goes first, then the others; Ollama only when chosen", {
        check(SummaryEngine.order(chosen: .ministral) == [.ministral, .claude, .apple], "Ministral")
        check(SummaryEngine.order(chosen: .claude) == [.claude, .ministral, .apple], "Claude")
        check(SummaryEngine.order(chosen: .apple) == [.apple, .ministral, .claude], "Apple")
        check(SummaryEngine.order(chosen: .ollama) == [.ollama, .ministral, .claude, .apple], "Ollama for testing")
        check(SummaryEngine.offered(developer: false) == [.ministral, .claude, .apple], "no Ollama in a normal install")
        check(SummaryEngine.offered(developer: true).contains(.ollama), "Ollama in developer mode")
    }),

    ("the stored summary engine defaults to Ministral and reads Ollama only in developer mode", {
        let defaults = UserDefaults(suiteName: "summary-engine-\(UUID())")!
        check(SummaryEngine.stored(defaults, environment: [:]) == .ministral, "Ministral by default")
        defaults.set("claude", forKey: SummaryEngine.storageKey)
        check(SummaryEngine.stored(defaults, environment: [:]) == .claude, "stored choice")
        defaults.set("ollama", forKey: SummaryEngine.storageKey)
        check(SummaryEngine.stored(defaults, environment: [:]) == .ministral, "Ollama's Ministral becomes the built-in one")
        defaults.set("gone", forKey: SummaryEngine.storageKey)
        check(SummaryEngine.stored(defaults, environment: [:]) == .ministral, "unknown value")
        defaults.set(SummaryEngine.ollama.rawValue, forKey: SummaryEngine.storageKey)
        check(SummaryEngine.stored(defaults, environment: [:]) == .ministral, "Ollama needs developer mode")
        defaults.set(true, forKey: AudioRetention.developerModeKey)
        check(SummaryEngine.stored(defaults, environment: [:]) == .ollama, "Ollama in developer mode")
        defaults.removeObject(forKey: AudioRetention.developerModeKey)
        defaults.set("claude", forKey: SummaryEngine.storageKey)
        check(SummaryEngine.stored(defaults, environment: ["WORKTIME_LLM": "ollama"]) == .ollama, "forced by the environment")
        check(!OllamaSummarizer.isAllowed(defaults, environment: [:]), "not allowed in a normal install")
        check(OllamaSummarizer.isAllowed(defaults, environment: ["WORKTIME_LLM": "ollama"]), "allowed by the environment")
    }),

    ("a summary names the model that wrote it", {
        check(LibraryLogic.summaryInfo(engine: SummaryEngine.ministral.model) == "Summarised by Ministral 3 8B", "Ministral")
        check(LibraryLogic.summaryInfo(engine: "ministral-3:8b") == "Summarised by Ministral 3 8B", "Ministral through Ollama")
        check(LibraryLogic.summaryInfo(engine: SummaryEngine.claude.model) == "Summarised by Claude", "Claude")
        check(LibraryLogic.summaryInfo(engine: SummaryEngine.apple.model) == "Summarised by Apple Intelligence", "Apple")
        check(LibraryLogic.summaryInfo(engine: nil) == nil, "unknown")
    }),

    ("the store keeps which engine summarised a meeting, also in an earlier version", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("summary-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let name = "Meeting-2026-11-06-0900.m4a"
        let engine = SummaryEngine.ministral.model
        let summary = ParsedSummary(MeetingSummary(title: "Standup", actionItems: [], topics: [.init(title: "Release", points: ["Fredag."])]),
                                    engine: engine)
        try store.saveTranscript(name, segments: [TranscriptSegment(start: 1, text: "Hej.", speaker: .you)], language: .swedish,
                                 engine: "ggml-large-v3-turbo")
        try store.saveSummary(name, summary)
        check(try store.content(of: name)?.meeting.summaryEngine == engine, "saved")
        check(try store.content(of: name)?.summary.engine == engine, "read back with the summary")

        let snapshot = TranscriptSnapshot(segments: [], summary: summary)
        let decoded = try TranscriptVersionLogic.decode(try TranscriptVersionLogic.encode(snapshot), language: nil,
                                                        languageDetected: false, engine: nil, transcribedAt: nil)
        check(decoded.summary.engine == engine, "kept in a version")

        try store.saveSummary(name, ParsedSummary(unavailable: "Apple Intelligence is off"))
        check(try store.content(of: name)?.meeting.summaryEngine == nil, "cleared without a summary")
    }),

    ("the local model is a catalogue entry downloaded next to the Whisper models", {
        let model = LocalLLMModel.all[0]
        check(model.fileName == "ministral-3-8b-instruct-2512-q4_k_m.gguf", model.fileName)
        check(model.remoteURL.absoluteString.hasSuffix("Ministral-3-8B-Instruct-2512-GGUF/resolve/main/Ministral-3-8B-Instruct-2512-Q4_K_M.gguf"),
              model.remoteURL.absoluteString)
        check(WhisperModel.all[0].fileName == "ggml-large-v3.bin", "Whisper files keep their names")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("llm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        check(LocalLLMModel.installed(in: folder) == nil, "nothing downloaded")
        try Data("partial".utf8).write(to: model.url(in: folder))
        check(LocalLLMModel.installed(in: folder) == nil, "a partial file is not the model")
        check(WhisperModel.leftovers(in: folder).isEmpty, "not a Whisper leftover")
    }),

    ("a JSON schema becomes a grammar the model cannot leave", {
        check(LocalLLMLogic.grammar(schema: AgentLogic.routeSchema).hasPrefix(
            #"root ::= "{" ws "\"model\"" ws ":" ws root-model "}" ws"# + "\n" + #"root-model ::= ("\"haiku\"" | "\"sonnet\"" | "\"opus\"") ws"#),
              LocalLLMLogic.grammar(schema: AgentLogic.routeSchema))
        let summary = LocalLLMLogic.grammar(schema: ClaudeSummarizer.schema)
        let rules = Dictionary(summary.split(separator: "\n").map { line -> (String, String) in
            let parts = line.components(separatedBy: " ::= ")
            return (parts[0], parts.dropFirst().joined(separator: " ::= "))
        }, uniquingKeysWith: { a, _ in a })
        check(rules["root"] == #""{" ws "\"title\"" ws ":" ws string "," ws "\"actionItems\"" ws ":" ws root-actionItems "," ws "\"topics\"" ws ":" ws root-topics "}" ws"#,
              rules["root"] ?? "")
        check(rules["root-actionItems-item"] == #""{" ws "\"task\"" ws ":" ws string ("," ws "\"owner\"" ws ":" ws string)? "}" ws"#,
              "the owner is optional: \(rules["root-actionItems-item"] ?? "")")
        check(rules["root-topics"] == #""[" ws (root-topics-item ("," ws root-topics-item)*)? "]" ws"#, "arrays")
        check(rules["string"] != nil && rules["ws"] != nil, "shared rules")
    }),

    ("a local model summarises with the shared instructions, in parts that fit its context", {
        try blocking {
            var prompts: [(system: String, prompt: String)] = []
            let summary = try await LocalLLMLogic.summarise(["[00:01] Du: hej"], language: .swedish, progress: { _ in }) { system, prompt in
                prompts.append((system, prompt))
                return #"Here: {"title":"Hej","actionItems":[{"task":"Skicka fixen","owner":"Anna"}],"topics":[]}"#
            }
            check(summary.title == "Hej" && summary.actionItems.first?.owner == "Anna", "\(summary)")
            check(prompts.count == 1 && prompts[0].system == ClaudeSummarizer.instructions(language: .swedish), "shared instructions")
            check(prompts[0].prompt == "Meeting transcript:\n\n[00:01] Du: hej", prompts[0].prompt)
            do {
                _ = try await LocalLLMLogic.summarise([], language: .english, progress: { _ in }) { _, _ in "" }
                check(false, "an empty transcript has no summary")
            } catch {
                check(error as? LocalLLMError == .emptyTranscript, "\(error)")
            }
        }
        check(LocalLLMLogic.maxCharacters == ProcessingLogic.chunkCharacters(contextSize: 16384), "chunks fit the context")
    }),

    ("the Ollama request asks for the schema without streaming, cool and briefly loaded", {
        let body = OllamaSummarizer.requestBody(system: "S", prompt: ClaudeSummarizer.prompt(["[00:01] Du: hej"]), schema: ClaudeSummarizer.schema)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        check(json["model"] as? String == "ministral-3:8b", "model")
        check(json["stream"] as? Bool == false, "no streaming")
        check(json["keep_alive"] as? String == "1m", "unloads soon")
        let options = json["options"] as? [String: Any] ?? [:]
        check(options["num_ctx"] as? Int == 16384 && (options["temperature"] as? Double ?? 1) <= 0.3, "\(options)")
        let format = json["format"] as? [String: Any] ?? [:]
        check((format["required"] as? [String]) == ["title", "actionItems", "topics"], "schema")
        let messages = json["messages"] as? [[String: String]] ?? []
        check(messages.map { $0["role"] } == ["system", "user"], "roles")
        check(messages.last?["content"] == "Meeting transcript:\n\n[00:01] Du: hej", "the shared prompt")
    }),

    ("the model counts as present only when Ollama lists it", {
        let tags = Data(#"{"models":[{"name":"ministral-3:8b","size":1},{"name":"llama3:latest"}]}"#.utf8)
        check(OllamaSummarizer.hasModel(tags: tags), "listed")
        check(OllamaSummarizer.hasModel(tags: tags, model: "llama3"), "bare name is latest")
        check(!OllamaSummarizer.hasModel(tags: tags, model: "ministral-3:14b"), "other size")
        check(!OllamaSummarizer.hasModel(tags: Data(#"{"models":[]}"#.utf8)), "nothing pulled")
        check(!OllamaSummarizer.hasModel(tags: Data("<html>".utf8)), "not Ollama")
    }),

    ("the answer is read out of Ollama's reply envelope", {
        let content = #"{"title":"Releasen flyttas till fredag","actionItems":[],"topics":[]}"#
        let envelope = try JSONSerialization.data(withJSONObject: [
            "model": "ministral-3:8b", "done": true, "done_reason": "stop",
            "message": ["role": "assistant", "content": content]])
        check(try OllamaSummarizer.content(fromReply: envelope) == content, "content")
        check(try ClaudeSummarizer.parse(try OllamaSummarizer.content(fromReply: envelope)).title == "Releasen flyttas till fredag", "parsed")

        func failure(_ json: String) -> String? {
            do {
                _ = try OllamaSummarizer.content(fromReply: Data(json.utf8))
                return nil
            } catch {
                return (error as? OllamaSummarizer.Failure)?.message
            }
        }
        check(failure(#"{"error":"model 'ministral-3:8b' not found"}"#)?.contains("not found") == true, "Ollama's error")
        check(failure(#"{"message":{"content":"{\"title\":"},"done_reason":"length"}"#)?.contains("context") == true, "cut off")
        check(failure(#"{"done_reason":"stop"}"#) == "the reply held no answer", "no message")
        check(failure("not json") != nil, "not an envelope")
    }),
]
