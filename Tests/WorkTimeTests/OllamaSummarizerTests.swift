import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let ollamaSummarizerTests: [(name: String, run: () throws -> Void)] = [
    ("the chosen summary engine goes first, then the others in their usual order", {
        check(SummaryEngine.order(chosen: .ollama) == [.ollama, .claude, .apple], "Ministral")
        check(SummaryEngine.order(chosen: .claude) == [.claude, .ollama, .apple], "Claude")
        check(SummaryEngine.order(chosen: .apple) == [.apple, .ollama, .claude], "Apple")
        let defaults = UserDefaults(suiteName: "ollama-tests-\(UUID())")!
        check(SummaryEngine.stored(defaults) == .ollama, "Ministral by default")
        defaults.set("claude", forKey: SummaryEngine.storageKey)
        check(SummaryEngine.stored(defaults) == .claude, "stored choice")
        defaults.set("gone", forKey: SummaryEngine.storageKey)
        check(SummaryEngine.stored(defaults) == .ollama, "unknown value")
    }),

    ("a summary names the model that wrote it", {
        check(LibraryLogic.summaryInfo(engine: SummaryEngine.ollama.model) == "Summarised by Ministral 3 8B", "Ministral")
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
        let summary = ParsedSummary(MeetingSummary(title: "Standup", actionItems: [], topics: [.init(title: "Release", points: ["Fredag."])]),
                                    engine: SummaryEngine.ollama.model)
        try store.saveTranscript(name, segments: [TranscriptSegment(start: 1, text: "Hej.", speaker: .you)], language: .swedish,
                                 engine: "ggml-large-v3-turbo")
        try store.saveSummary(name, summary)
        check(try store.content(of: name)?.meeting.summaryEngine == "ministral-3:8b", "saved")
        check(try store.content(of: name)?.summary.engine == "ministral-3:8b", "read back with the summary")

        let snapshot = TranscriptSnapshot(segments: [], summary: summary)
        let decoded = try TranscriptVersionLogic.decode(try TranscriptVersionLogic.encode(snapshot), language: nil,
                                                        languageDetected: false, engine: nil, transcribedAt: nil)
        check(decoded.summary.engine == "ministral-3:8b", "kept in a version")

        try store.saveSummary(name, ParsedSummary(unavailable: "Apple Intelligence is off"))
        check(try store.content(of: name)?.meeting.summaryEngine == nil, "cleared without a summary")
    }),

    ("the chat request asks for the summary schema without streaming, cool and briefly loaded", {
        let body = OllamaSummarizer.requestBody(system: "S", prompt: ClaudeSummarizer.prompt(["[00:01] Du: hej"]))
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
        check(OllamaSummarizer.maxCharacters == ProcessingLogic.chunkCharacters(contextSize: 16384), "chunks fit the context")
    }),

    ("the model counts as present only when Ollama lists it", {
        let tags = Data(#"{"models":[{"name":"ministral-3:8b","size":1},{"name":"llama3:latest"}]}"#.utf8)
        check(OllamaSummarizer.hasModel(tags: tags), "listed")
        check(OllamaSummarizer.hasModel(tags: tags, model: "llama3"), "bare name is latest")
        check(!OllamaSummarizer.hasModel(tags: tags, model: "ministral-3:14b"), "other size")
        check(!OllamaSummarizer.hasModel(tags: Data(#"{"models":[]}"#.utf8)), "nothing pulled")
        check(!OllamaSummarizer.hasModel(tags: Data("<html>".utf8)), "not Ollama")
    }),

    ("the summary is read out of Ollama's reply envelope", {
        let content = #"{"title":"Releasen flyttas till fredag","actionItems":[{"task":"Skicka fixen","owner":"Anna"}],"topics":[{"title":"Release","points":["Två buggar kvar"]}]}"#
        let envelope = try JSONSerialization.data(withJSONObject: [
            "model": "ministral-3:8b", "done": true, "done_reason": "stop",
            "message": ["role": "assistant", "content": content]])
        let summary = try OllamaSummarizer.summary(fromReply: envelope)
        check(summary.title == "Releasen flyttas till fredag", summary.title)
        check(summary.actionItems.first?.owner == "Anna", "owner")
        check(summary.topics.first?.points == ["Två buggar kvar"], "points")

        func failure(_ json: String) -> String? {
            do {
                _ = try OllamaSummarizer.summary(fromReply: Data(json.utf8))
                return nil
            } catch {
                return (error as? OllamaSummarizer.Failure)?.message
            }
        }
        check(failure(#"{"error":"model 'ministral-3:8b' not found"}"#)?.contains("not found") == true, "Ollama's error")
        check(failure(#"{"message":{"content":"{\"title\":"},"done_reason":"length"}"#)?.contains("context") == true, "cut off")
        check(failure(#"{"message":{"content":"Sorry"},"done_reason":"stop"}"#) == "the reply held no summary", "no JSON")
        check(failure("not json") != nil, "not an envelope")
    }),
]
