import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let fakeKey = "sk-ant-api03-FAKE-TEST-KEY-0123456789"

private func json(_ object: [String: Any]) -> String {
    "data: " + String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

/// The lines of a reply as the API streams them: one line per field, a blank line after each event.
private func replyLines(_ pieces: [String], output: Int = 7) -> [String] {
    var lines = ["event: message_start",
                 json(["type": "message_start", "message": ["usage": ["input_tokens": 25, "output_tokens": 1]]]), ""]
    lines += ["event: content_block_start", json(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]), ""]
    for piece in pieces {
        lines += ["event: content_block_delta", json(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": piece]]), ""]
    }
    lines += ["event: message_delta", json(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": output]]), "",
              "event: message_stop", json(["type": "message_stop"]), ""]
    return lines
}

private final class Seen: @unchecked Sendable {
    var requests: [URLRequest] = []
}

/// A transport that answers with a fixed status, lines or error and records the requests it was given.
private func fake(status: Int = 200, lines: [String] = [], retryAfter: Int? = nil, failure: Error? = nil, seen: Seen = Seen()) -> ClaudeTransport {
    { request in
        seen.requests.append(request)
        if let failure { throw failure }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return ClaudeTransportResponse(status: status, retryAfter: retryAfter, lines: stream)
    }
}

private struct Outcome {
    var text = ""
    var usage: ClaudeAPIUsage?
    var error: ClaudeAPIError?
}

/// Runs the client to the end and returns what it produced, on a background thread so the test can wait for it.
private func replyOutcome(_ client: ClaudeAPIClient, key: String = fakeKey, messages: [ClaudeAPIMessage] = [ClaudeAPIMessage(role: .user, text: "Hi")]) -> Outcome {
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    Task {
        var outcome = Outcome()
        do {
            for try await event in client.reply(key: key, model: "claude-sonnet-5-5", system: "Be brief.", messages: messages) {
                switch event {
                case .text(let piece): outcome.text += piece
                case .finished(let usage): outcome.usage = usage
                }
            }
        } catch {
            outcome.error = (error as? ClaudeAPIError) ?? .network("\(error)")
        }
        box.outcome = outcome
        done.signal()
    }
    done.wait()
    return box.outcome
}

private final class Box: @unchecked Sendable {
    var outcome = Outcome()
    var lines: [String] = []
}

private func parsed(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

private let sourceFolder: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources", isDirectory: true)

private func sourceFiles() throws -> [URL] {
    try ["WorkTime", "Shared"].flatMap { folder in
        try FileManager.default.contentsOfDirectory(at: sourceFolder.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }
}

let claudeAPITests: [(name: String, run: () throws -> Void)] = [
    ("the request body has the model, max_tokens, stream and the turns in order, and never a tools field", {
        let body = try ClaudeAPIRequest.body(model: "claude-sonnet-5-5", system: "Be brief.", messages: [
            ClaudeAPIMessage(role: .user, text: "First"), ClaudeAPIMessage(role: .assistant, text: "Answer"), ClaudeAPIMessage(role: .user, text: "Second"),
        ])
        let object = (try JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        check(object["model"] as? String == "claude-sonnet-5-5", "model")
        check(object["max_tokens"] as? Int == 4096, "max_tokens")
        check(object["stream"] as? Bool == true, "stream")
        check(object["system"] as? String == "Be brief.", "system")
        let turns = (object["messages"] as? [[String: String]]) ?? []
        check(turns == [["role": "user", "content": "First"], ["role": "assistant", "content": "Answer"], ["role": "user", "content": "Second"]], "turn order: \(turns)")
        check(object["tools"] == nil, "no tools in the request body")
        check(Set(object.keys) == ["model", "max_tokens", "stream", "system", "messages"], "only the expected fields: \(Set(object.keys))")
        check(!String(decoding: body, as: UTF8.self).contains("tools"), "the word tools does not appear in the body")
    }),

    ("turns with the same role are joined, leading assistant turns dropped and only the newest turns kept", {
        let merged = ClaudeAPIRequest.turns([ClaudeAPIMessage(role: .assistant, text: "Lost"), ClaudeAPIMessage(role: .user, text: "A"),
                                             ClaudeAPIMessage(role: .user, text: "B"), ClaudeAPIMessage(role: .assistant, text: "C"), ClaudeAPIMessage(role: .user, text: "")])
        check(merged == [ClaudeAPIMessage(role: .user, text: "A\n\nB"), ClaudeAPIMessage(role: .assistant, text: "C")], "joined: \(merged)")
        let many = (0..<100).map { ClaudeAPIMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "\($0)") }
        let kept = ClaudeAPIRequest.turns(many)
        check(kept.count == ClaudeAPIRequest.historyLimit, "history capped at \(ClaudeAPIRequest.historyLimit), got \(kept.count)")
        check(kept.last?.text == "99", "the newest turn is kept")
    }),

    ("headers carry the key, the API version and the content type, and the key is not in the body", {
        let headers = ClaudeAPIRequest.headers(key: fakeKey)
        check(headers["x-api-key"] == fakeKey, "x-api-key")
        check(headers["anthropic-version"] == "2023-06-01", "anthropic-version")
        check(headers["content-type"] == "application/json", "content-type")
        let body = try ClaudeAPIRequest.body(model: "claude-sonnet-5-5", system: nil, messages: [ClaudeAPIMessage(role: .user, text: "Hi")])
        check(!String(decoding: body, as: UTF8.self).contains(fakeKey), "the key never reaches the body")
        check(ClaudeAPIRequest.endpoint.absoluteString == "https://api.anthropic.com/v1/messages", "endpoint")
    }),

    ("SSE: events split across chunks, several events in one chunk, and CRLF line endings all parse the same", {
        let text = "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}\r\n\r\n"
            + "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}\n\n"
            + ": a comment\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        var whole = SSEParser()
        let wholeEvents = whole.feed(text)
        check(wholeEvents.count == 3, "three events in one feed: \(wholeEvents.count)")
        var piecewise = SSEParser()
        var pieces: [ServerSentEvent] = []
        for character in text { pieces += piecewise.feed(String(character)) }
        check(pieces == wholeEvents, "one character at a time gives the same events")
        var halves = SSEParser()
        let cut = text.index(text.startIndex, offsetBy: 40)
        check(halves.feed(String(text[..<cut])).isEmpty, "no event before its blank line")
        check(halves.feed(String(text[cut...])).count == 3, "the rest completes all three events")
        check(wholeEvents.first?.event == "content_block_delta", "event name kept")
    }),

    ("the byte stream keeps the blank lines that end events, with CRLF and a last line without a newline", {
        let bytes = Array("event: a\r\ndata: 1\r\n\r\nevent: b\ndata: 2\n\ntail".utf8)
        let source = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            var lines: [String] = []
            for try await line in ClaudeAPIClient.lines(of: source) { lines.append(line) }
            box.lines = lines
            done.signal()
        }
        done.wait()
        check(box.lines == ["event: a", "data: 1", "", "event: b", "data: 2", "", "tail"], "lines: \(box.lines)")
    }),

    ("the stream reader collects the text, the usage and the finish, and ignores thinking and ping events", {
        var reader = ClaudeStreamReader()
        var collected = ""
        let lines = replyLines(["Hello", ", world"], output: 9) + ["event: ping", json(["type": "ping"]), ""]
            + ["event: content_block_delta", json(["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "hidden"]]), ""]
        for line in lines { collected += try reader.consume(line + "\n") }
        check(collected == "Hello, world", "text: \(collected)")
        check(reader.finished, "message_stop finishes the reply")
        check(reader.usage == ClaudeAPIUsage(inputTokens: 25, outputTokens: 9), "usage from message_start and message_delta: \(String(describing: reader.usage))")
    }),

    ("an error event in the stream throws its classified error", {
        var reader = ClaudeStreamReader()
        let overloaded = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
        do {
            _ = try reader.consume(overloaded)
            check(false, "the error event should throw")
        } catch {
            check((error as? ClaudeAPIError) == .overloaded, "overloaded_error maps to overloaded: \(error)")
        }
        check(ClaudeStreamEvent.decode(ServerSentEvent(event: "error", data: "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}")) == .error(.rateLimited(retryAfter: nil)), "rate limit event")
        check(ClaudeStreamEvent.decode(ServerSentEvent(event: "error", data: "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"x\"}}")) == .error(.invalidKey), "auth event")
        check(ClaudeStreamEvent.decode(ServerSentEvent(event: nil, data: "not json")) == .ignored, "unreadable data is ignored")
    }),

    ("HTTP errors map to their classes: 401 invalid key, 429 with retry-after, 529 overloaded, 402 and credit balance billing", {
        check(ClaudeAPIError.from(status: 401, body: "", retryAfter: nil) == .invalidKey, "401")
        check(ClaudeAPIError.from(status: 429, body: "", retryAfter: 12) == .rateLimited(retryAfter: 12), "429 keeps retry-after")
        check(ClaudeAPIError.from(status: 529, body: "", retryAfter: nil) == .overloaded, "529")
        check(ClaudeAPIError.from(status: 402, body: "", retryAfter: nil) == .billing, "402")
        check(ClaudeAPIError.from(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"#, retryAfter: nil) == .billing, "credit balance on 400")
        check(ClaudeAPIError.from(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens too large"}}"#, retryAfter: nil)
              == .badRequest("max_tokens too large"), "400 keeps the message")
        check(ClaudeAPIError.from(status: 500, body: #"{"type":"error","error":{"type":"api_error","message":"Internal"}}"#, retryAfter: nil) == .server("Internal"), "500 uses the server message")
        check(ClaudeAPIError.from(status: 418, body: "", retryAfter: nil) == .server("Anthropic returned HTTP 418."), "unknown status has a plain message")
        check(ClaudeAPIError.rateLimited(retryAfter: 30).message.contains("30 seconds"), "rate limit message names the wait")
    }),

    ("the client sends a POST with the headers and the body, and streams the reply", {
        let seen = Seen()
        let client = ClaudeAPIClient(transport: fake(lines: replyLines(["Hi ", "there"], output: 4), seen: seen))
        let outcome = replyOutcome(client)
        check(outcome.error == nil, "no error: \(String(describing: outcome.error))")
        check(outcome.text == "Hi there", "streamed text: \(outcome.text)")
        check(outcome.usage == ClaudeAPIUsage(inputTokens: 25, outputTokens: 4), "usage: \(String(describing: outcome.usage))")
        let request = seen.requests.first
        check(request?.httpMethod == "POST", "POST")
        check(request?.url == ClaudeAPIRequest.endpoint, "endpoint")
        check(request?.value(forHTTPHeaderField: "x-api-key") == fakeKey, "key header")
        check(request?.timeoutInterval == ClaudeAPIRequest.timeout, "timeout set")
        check(parsed(request ?? URLRequest(url: ClaudeAPIRequest.endpoint))["stream"] as? Bool == true, "stream true in the body")
        check(parsed(request ?? URLRequest(url: ClaudeAPIRequest.endpoint))["tools"] == nil, "no tools sent")
    }),

    ("the client classifies HTTP and network failures and never returns the key in a message", {
        check(replyOutcome(ClaudeAPIClient(transport: fake(status: 401, lines: [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#]))).error == .invalidKey, "401 from the stream")
        let limited = replyOutcome(ClaudeAPIClient(transport: fake(status: 429, lines: [], retryAfter: 7)))
        check(limited.error == .rateLimited(retryAfter: 7), "429 with retry-after: \(String(describing: limited.error))")
        let network = replyOutcome(ClaudeAPIClient(transport: fake(failure: URLError(.notConnectedToInternet))))
        if case .network = network.error {} else { check(false, "network failure: \(String(describing: network.error))") }
        let incomplete = replyOutcome(ClaudeAPIClient(transport: fake(lines: ["event: message_start", json(["type": "message_start"]), ""])))
        check(incomplete.error == .incomplete, "a reply without message_stop is incomplete")
        let echoed = replyOutcome(ClaudeAPIClient(transport: fake(status: 400, lines: [#"{"type":"error","error":{"type":"invalid_request_error","message":"bad \#(fakeKey) here"}}"#])))
        check(echoed.error?.message.contains(fakeKey) == false, "the key is redacted from a server message")
        check(echoed.error?.message.contains("sk-ant-\u{2026}") == true, "the redacted key is replaced by the marker")
        let refusal = replyLines(["partial"]).map { $0.replacingOccurrences(of: "end_turn", with: "refusal") }
        check(replyOutcome(ClaudeAPIClient(transport: fake(lines: refusal))).error == .refused, "a refusal stop reason is an error")
    }),

    ("extra fields, beta headers and the timeout reach the request", {
        let seen = Seen()
        let client = ClaudeAPIClient(transport: fake(lines: replyLines(["{}"]), seen: seen))
        let options = ClaudeAPIClient.Options(maxTokens: 64000, extra: ClaudeSummarizer.requestFields,
                                              betas: [ClaudeSummarizer.fallbackBeta], timeout: 600)
        let done = DispatchSemaphore(value: 0)
        Task {
            let replies = client.reply(key: fakeKey, model: ClaudeSummarizer.model, system: "S",
                                       messages: [ClaudeAPIMessage(role: .user, text: "T")], options: options)
            do { for try await _ in replies {} } catch {}
            done.signal()
        }
        done.wait()
        let request = seen.requests.first ?? URLRequest(url: ClaudeAPIRequest.endpoint)
        let body = parsed(request)
        let config = body["output_config"] as? [String: Any]
        check(body["model"] as? String == "claude-opus-5-5" && body["max_tokens"] as? Int == 64000, "model and max tokens")
        check(config?["effort"] as? String == "medium", "medium effort")
        check((config?["format"] as? [String: Any])?["type"] as? String == "json_schema", "json schema output")
        check(body["fallbacks"] as? String == "default" && body["thinking"] == nil, "server fallback, adaptive thinking by default")
        check(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01", "beta header")
        check(request.timeoutInterval == 600, "longer timeout")
        check(ClaudeAPIRequest.headers(key: fakeKey)["anthropic-beta"] == nil, "the chat sends no beta header")
    }),

    ("API key shape: a valid key passes, and wrong prefix, spaces, empty and short keys are refused", {
        check(ClaudeAPIKey.problem(fakeKey) == nil, "valid key")
        check(ClaudeAPIKey.problem("") != nil, "empty")
        check(ClaudeAPIKey.problem("sk-openai-0123456789abcdefghij") != nil, "other provider prefix")
        check(ClaudeAPIKey.problem("sk-ant-api03 with space-0123456789") != nil, "space")
        check(ClaudeAPIKey.problem("sk-ant-api03-0123\n456789abcdef") != nil, "line break")
        check(ClaudeAPIKey.problem("sk-ant-x") != nil, "too short")
    }),

    ("API key masking shows the prefix and last four characters only", {
        let masked = ClaudeAPIKey.masked("sk-ant-api03-SECRETMIDDLEPART-abcd")
        check(masked == "sk-ant-\u{2026}abcd", "masked: \(masked)")
        check(!masked.contains("SECRET"), "the middle is hidden")
    }),

    ("redaction removes the key and any key-shaped text", {
        let text = SecretRedaction.redact("auth failed for sk-ant-api03-OTHER-VALUE and \(fakeKey)", key: fakeKey)
        check(!text.contains("OTHER-VALUE") && !text.contains("0123456789"), "key-shaped text removed: \(text)")
        check(text.contains("sk-ant-\u{2026}"), "marker kept")
    }),

    ("the key store saves a valid key, refuses a bad one and removes it, with an in-memory store", {
        let secrets = MemorySecretStore()
        let keys = ClaudeAPIKeyStore(secrets: secrets)
        check(keys.key() == nil, "nothing saved yet")
        do {
            try keys.save("not a key")
            check(false, "a bad key is refused")
        } catch {
            check(keys.key() == nil, "a refused key is not stored")
        }
        try keys.save("  \(fakeKey)\n")
        check(keys.key() == fakeKey, "trimmed key stored")
        check(secrets.key(for: ClaudeAPIKeyStore.account) == Data(fakeKey.utf8), "stored under the api-key account")
        keys.remove()
        check(keys.key() == nil, "removed")
    }),

    ("the live key store uses the service for Anthropic, and no test touches it", {
        let live = ClaudeAPIKeyStore.live.secrets as? AppSecretStore
        check(live?.keychain.service == "com.niklasinde.MeetingRecorder.anthropic", "service name: \(String(describing: live?.keychain.service))")
    }),

    ("only Settings, the summariser and the command-line check use the Claude API: the MCP server and the phone API never mention it", {
        let allowed: Set<String> = ["SettingsWindow.swift", "WorkTimeApp.swift", "ClaudeSummarizer.swift"]
        for file in try sourceFiles() {
            let name = file.lastPathComponent
            guard !name.hasPrefix("ClaudeAPI") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("ClaudeAPI") || text.contains("api.anthropic.com") || text.contains("AnthropicClient") {
                check(allowed.contains(name) || name == "ClaudeAPI.swift", "\(name) must not reach the Claude API")
            }
            if name.hasPrefix("MCP") || name.hasPrefix("Phone") || name.hasPrefix("ChatToolbox") || name == "PhoneAPI.swift" || name == "PhoneFormat.swift" || name == "PhoneTransport.swift" {
                check(!text.contains("ClaudeAPI") && !text.contains("api.anthropic.com"), "\(name) must not reach the Claude API")
            }
        }
    }),

    ("only the Claude API client file names the Anthropic endpoint, and the request logic has no tools array", {
        for file in try sourceFiles() where file.lastPathComponent.hasPrefix("ClaudeAPI") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent != "ClaudeAPILogic.swift" {
                check(!text.contains("api.anthropic.com"), "\(file.lastPathComponent) names the endpoint")
            }
            if file.lastPathComponent == "ClaudeAPILogic.swift" || file.lastPathComponent == "ClaudeAPIClient.swift" {
                check(!text.contains("\"tools\""), "\(file.lastPathComponent) mentions a tools field")
            }
        }
    }),
]
