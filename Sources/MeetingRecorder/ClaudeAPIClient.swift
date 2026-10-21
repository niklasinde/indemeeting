import Foundation

enum ClaudeAPIEvent: Equatable {
    case text(String)
    case finished(ClaudeAPIUsage?)
}

struct ClaudeTransportResponse {
    let status: Int
    let retryAfter: Int?
    let lines: AsyncThrowingStream<String, Error>
}

/// Sends one request and returns its status and the lines of its body. Tests replace it with a fake.
typealias ClaudeTransport = @Sendable (URLRequest) async throws -> ClaudeTransportResponse

/// Streams one Messages API reply. Errors come out classified, and never contain the key.
struct ClaudeAPIClient {
    var endpoint = ClaudeAPIRequest.endpoint
    var transport: ClaudeTransport = ClaudeAPIClient.urlSession

    func reply(key: String, model: String, system: String?, messages: [ClaudeAPIMessage]) -> AsyncThrowingStream<ClaudeAPIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(key: key, model: model, system: system, messages: messages, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if Task.isCancelled { return continuation.finish() }
                    let classified = (error as? ClaudeAPIError) ?? .network(error.localizedDescription)
                    continuation.finish(throwing: classified.redacting(key))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(key: String, model: String, system: String?, messages: [ClaudeAPIMessage],
                        into continuation: AsyncThrowingStream<ClaudeAPIEvent, Error>.Continuation) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: ClaudeAPIRequest.timeout)
        request.httpMethod = "POST"
        request.httpBody = try ClaudeAPIRequest.body(model: model, system: system, messages: messages)
        for (name, value) in ClaudeAPIRequest.headers(key: key) { request.setValue(value, forHTTPHeaderField: name) }

        let response = try await transport(request)
        guard (200..<300).contains(response.status) else {
            var body = ""
            for try await line in response.lines { body += line + "\n" }
            throw ClaudeAPIError.from(status: response.status, body: body, retryAfter: response.retryAfter)
        }

        var reader = ClaudeStreamReader()
        for try await line in response.lines {
            let text = try reader.consume(line + "\n")
            if !text.isEmpty { continuation.yield(.text(text)) }
        }
        guard reader.finished else { throw ClaudeAPIError.incomplete }
        continuation.yield(.finished(reader.usage))
    }

    static let urlSession: ClaudeTransport = { request in
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let retryAfter = http?.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) }
        return ClaudeTransportResponse(status: http?.statusCode ?? 0, retryAfter: retryAfter, lines: lines(of: bytes))
    }

    /// The lines of a byte stream, with the blank lines that end SSE events kept. `AsyncBytes.lines` drops them.
    static func lines<Bytes: AsyncSequence>(of bytes: Bytes) -> AsyncThrowingStream<String, Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        guard byte == UInt8(ascii: "\n") else {
                            line.append(byte)
                            continue
                        }
                        if line.last == UInt8(ascii: "\r") { line.removeLast() }
                        continuation.yield(String(decoding: line, as: UTF8.self))
                        line.removeAll(keepingCapacity: true)
                    }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `MeetingRecorder --claude-api-check http://127.0.0.1:<port>/v1/messages`: runs the client against a local stub with a fake
/// key. Refuses any host but the loopback, so the real API is never called from here.
enum ClaudeAPICheck {
    static func endpoint(_ arguments: [String]) -> URL? {
        arguments.firstIndex(of: "--claude-api-check").flatMap { $0 + 1 < arguments.count ? URL(string: arguments[$0 + 1]) : nil }
    }

    static func runFromCommandLine(_ endpoint: URL) -> Never {
        guard ["127.0.0.1", "localhost"].contains(endpoint.host ?? "") else {
            print("refused: the check only talks to a loopback stub")
            exit(2)
        }
        let key = "sk-ant-api03-FAKE-CHECK-KEY-0000wxyz"
        let client = ClaudeAPIClient(endpoint: endpoint)
        let message = [ClaudeAPIMessage(role: .user, text: "Say hello")]
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            for attempt in [key, key.replacingOccurrences(of: "api03", with: "bad03")] {
                do {
                    var text = ""
                    for try await event in client.reply(key: attempt, model: ClaudeAPIModel.defaultModel.rawValue, system: nil, messages: message) {
                        switch event {
                        case .text(let piece): text += piece
                        case .finished(let usage): print("finished usage=\(usage.map { "\($0.inputTokens)/\($0.outputTokens)" } ?? "none")")
                        }
                    }
                    print("text=\(text)")
                } catch {
                    print("error: \((error as? ClaudeAPIError)?.message ?? error.localizedDescription)")
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
