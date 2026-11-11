import Foundation
#if canImport(ggml)

/// `--check-local-llm [--transcript <file>] [--language sv-SE] [--audio <file>]`: loads the downloaded Ministral, has
/// Auto classify a prompt and summarises a transcript, printing load time, tokens per second and peak memory. With
/// `--audio`, the installed Whisper model transcribes it before and after, in the same process. Use `--data-dir` to read
/// models from elsewhere.
enum LocalLLMCheck {
    static let flag = "--check-local-llm"
    static let routePrompt = "Refactor the notch layout across all panels and fix the misalignment bug"
    static let sampleTranscript = [
        "[00:00] Anna: Okay, let's go through the release. The build for Friday is ready apart from the login bug.",
        "[00:12] Johan: I can fix the login bug tomorrow, it is the token refresh that fails after an hour.",
        "[00:25] Anna: Good. Then Elin writes the release notes and we send them to support on Thursday.",
        "[00:38] Elin: Sure. Should we mention the new export to Excel?",
        "[00:44] Anna: Yes, that's the big one. And we move the database upgrade to next week, it's too risky now.",
        "[00:58] Johan: Agreed. I'll book a time with operations for Tuesday.",
    ]

    static func runFromCommandLine(_ arguments: [String]) -> Never {
        Task {
            do {
                try await run(arguments)
                LocalLLM.shared.unload(wait: true)
                exit(0)
            } catch {
                LocalLLM.shared.unload(wait: true)
                FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func run(_ arguments: [String]) async throws {
        guard let model = LocalLLMModel.installed() else { throw LocalLLMError.notInstalled }
        print("Model: \(model.name) at \(model.url().path)")
        let audio = PhoneCommandLine.value("--audio", in: arguments).map { URL(fileURLWithPath: $0) }
        if let audio { try await transcribe(audio, when: "before") }

        let started = Date()
        let route = try await LocalLLM.shared.generate(system: AgentLogic.routeSystem, prompt: AgentLogic.routeUser(
            prompt: routePrompt, signals: .init()), schema: AgentLogic.routeSchema, maxTokens: 32, temperature: 0, urgent: true)
        let load = Date().timeIntervalSince(started) - route.promptSeconds - route.generateSeconds
        print(String(format: "Load: %.1f s", load))
        print("Route: \(route.text) -> \(AgentLogic.routeTier(fromAnswer: route.text) ?? "none")")
        report(route)
        let warm = Date()
        let picked = await AgentLogic.route(prompt: routePrompt, signals: .init(), previous: nil, ask: AgentModel.classify)
        print(String(format: "Auto picks %@ in %.2f s, warm", picked, Date().timeIntervalSince(warm)))

        let language = PhoneCommandLine.value("--language", in: arguments).flatMap(MeetingLanguage.init) ?? .english
        let lines = try PhoneCommandLine.value("--transcript", in: arguments)
            .map { try String(contentsOfFile: $0, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty } }
            ?? sampleTranscript
        let summary = try await LocalLLMLogic.summarise(lines, language: language, progress: { _ in }) { system, prompt in
            let reply = try await LocalLLM.shared.generate(system: system, prompt: prompt, schema: ClaudeSummarizer.schema)
            report(reply)
            return reply.text
        }
        print(ProcessingLogic.summaryMarkdown(summary, audioName: nil, language: language))
        if let audio { try await transcribe(audio, when: "after") }
        print(String(format: "Peak memory: %.0f MB", ASRBenchmark.peakMegabytes() ?? 0))
    }

    private static func report(_ reply: LocalLLM.Reply) {
        print(String(format: "  %d prompt tokens in %.2f s (%.0f/s), %d generated in %.2f s (%.1f tokens/s)", reply.promptTokens,
                     reply.promptSeconds, Double(reply.promptTokens) / max(reply.promptSeconds, 0.001), reply.generatedTokens,
                     reply.generateSeconds, reply.tokensPerSecond))
    }

    private static func transcribe(_ audio: URL, when: String) async throws {
        guard let model = WhisperModel.installed().last else { throw WhisperModelError.notInstalled(WhisperModel.all[0]) }
        let engine = try WhisperEngine(model: model, options: WhisperOptions(languages: ["en"], fallback: "en", beamSearch: false))
        let transcript = try await engine.transcribe(audio) { _ in }
        print("Whisper \(model.name), \(when): " + transcript.segments.map(\.text).joined(separator: " "))
    }
}
#endif
