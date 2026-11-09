import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(WorkTime)
@testable import WorkTime
#endif

let claudeSummarizerTests: [(name: String, run: () throws -> Void)] = [
    ("only a refusal by Apple's model falls back to Claude", {
        #if canImport(FoundationModels)
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "Detected content likely to be unsafe")
        check(ClaudeSummarizer.shouldFallBack(LanguageModelSession.GenerationError.guardrailViolation(context)), "guardrail")
        check(!ClaudeSummarizer.shouldFallBack(LanguageModelSession.GenerationError.exceededContextWindowSize(context)), "context window")
        #endif
        check(!ClaudeSummarizer.shouldFallBack(SummaryUnavailable.appleIntelligenceOff), "Apple Intelligence off")
        check(!ClaudeSummarizer.shouldFallBack(CocoaError(.fileNoSuchFile)), "other errors")
    }),

    ("the API key wins over the CLI, and nothing is a clear failure", {
        let cli = URL(fileURLWithPath: "/usr/local/bin/claude")
        check(ClaudeSummarizer.route(key: "sk-ant-x", cli: cli) == .api(key: "sk-ant-x"), "key and CLI")
        check(ClaudeSummarizer.route(key: "", cli: cli) == .cli(cli), "empty key")
        check(ClaudeSummarizer.route(key: nil, cli: cli) == .cli(cli), "CLI only")
        check(ClaudeSummarizer.route(key: nil, cli: nil) == nil, "neither")
        check(ClaudeSummarizer.Failure.unavailable.message.contains("API key"), "names the way out")
    }),

    ("a structured reply parses into the summary the app stores", {
        let reply = """
        ```json
        {"title":"Standup \\u2013 release","actionItems":[{"task":"Ship the fix","owner":"Anna"},{"task":"Write notes"}],\
        "topics":[{"title":"Release","points":["Friday","Two bugs left"]}]}
        ```
        """
        let summary = try ClaudeSummarizer.parse(reply)
        check(summary.title == "Standup \u{2013} release", "title \(summary.title)")
        check(summary.actionItems.map(\.owner) == ["Anna", nil], "owners")
        check(summary.topics.first?.points == ["Friday", "Two bugs left"], "points")
        check((try? ClaudeSummarizer.parse("I can't help with that.")) == nil, "no JSON")
    }),

    ("the prompt carries the whole transcript and the CLI runs without tools or settings", {
        let lines = (0..<500).map { "[00:\($0)] Talare 1: rad \($0)" }
        let prompt = ClaudeSummarizer.prompt(lines)
        check(prompt.hasSuffix("rad 499") && prompt.contains("rad 0\n"), "nothing truncated")
        let instructions = ClaudeSummarizer.instructions(language: .swedish)
        check(instructions.contains("Swedish"), "the meeting's language")
        check(instructions.contains("concrete thing decided") && instructions.contains("person advised"), "title and owner guidance")
        let arguments = ClaudeSummarizer.cliArguments(system: "S", prompt: "P")
        check(arguments.starts(with: ["-p", "P"]) && arguments.contains("dontAsk") && arguments.contains(ClaudeSummarizer.model), "\(arguments)")
        check(arguments.contains { $0.contains("\"actionItems\"") }, "schema in the system prompt")
    }),
]
