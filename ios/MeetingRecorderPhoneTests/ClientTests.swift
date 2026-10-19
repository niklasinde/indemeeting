import Foundation
import Network
import Testing
@testable import MeetingRecorderPhone

/// A TLS-PSK server on loopback that answers every request with canned bytes, so the client is tested over the real channel.
private final class TestServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "test.server")
    private(set) var requests: [String] = []
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    init(credential: PhoneCredential, respond: @escaping @Sendable (String) async -> [Data]) async throws {
        listener = try NWListener(using: PhoneTransport.parameters([credential]))
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                if !request.isEmpty { lock.withLock { requests.append(request) } }
                Task {
                    for piece in await respond(request) {
                        await withCheckedContinuation { continuation in connection.send(content: piece, completion: .contentProcessed { _ in continuation.resume() }) }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    connection.cancel()
                }
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { [listener] state in
                guard !done else { return }
                if case .ready = state { done = true; continuation.resume(returning: listener.port!.rawValue) }
                if case .failed(let error) = state { done = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
    }

    var received: [String] { lock.withLock { requests } }
    func stop() { listener.cancel() }
}

@Suite(.serialized) struct ClientTests {
    private let credential = PhoneCredential(id: "6edabb92", key: Data(repeating: 9, count: 32))

    private func client(port: UInt16, credential: PhoneCredential? = nil) -> PhoneHTTPClient {
        PhoneHTTPClient(credential: credential ?? self.credential, connectTimeout: 3) { [.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)] }
    }

    @Test func getsJSONOverPSK() async throws {
        let body = #"{"apiVersion":1,"appVersion":"0.2.0","features":{"activityEnabled":true,"chatAvailable":false,"githubEnabled":true},"schemaVersion":12,"serverName":"mac","serverTime":"2026-10-19T15:50:32Z"}"#
        let server = try await TestServer(credential: credential) { _ in
            [Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n".utf8), Data(body.utf8)]
        }
        defer { server.stop() }
        let status: PhoneStatus = try await client(port: server.port).json(.get("/v1/status"))
        #expect(status.serverName == "mac")
        #expect(!status.features.chatAvailable)
        let request = try #require(server.received.first)
        #expect(request.hasPrefix("GET /v1/status HTTP/1.1\r\n"))
        #expect(request.contains("X-Device-Id: 6edabb92"))
    }

    @Test func streamsChunkedBodiesAsTheyArrive() async throws {
        let server = try await TestServer(credential: credential) { _ in
            [Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/x-ndjson\r\n\r\n".utf8), PhoneHTTP.chunk(Data("{\"type\":\"token\",\"text\":\"Hi\"}\n".utf8)),
             PhoneHTTP.chunk(Data("{\"type\":\"done\",\"text\":\"Hi\"}\n".utf8)), PhoneHTTP.lastChunk]
        }
        defer { server.stop() }
        var lines = NDJSONLineBuffer()
        var events: [PhoneChatEvent] = []
        var pieces = 0
        let request = try PhoneRequest.post("/v1/chat", json: PhoneChatRequest(scope: PhoneChatScope(kind: "general"), messages: [PhoneChatMessage(role: "user", text: "hi")]))
        for try await event in client(port: server.port).stream(request) {
            if case .body(let data) = event {
                pieces += 1
                events += lines.feed(data).compactMap { try? PhoneAPI.decoder.decode(PhoneChatEvent.self, from: $0) }
            }
        }
        #expect(pieces == 2)
        #expect(events.map(\.type) == ["token", "done"])
    }

    @Test func rangeHeaderReachesTheServer() async throws {
        let server = try await TestServer(credential: credential) { _ in
            [Data("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 2-4/10\r\nContent-Length: 3\r\n\r\nabc".utf8)]
        }
        defer { server.stop() }
        var request = PhoneRequest.get("/v1/meetings/7/audio")
        request.headers["Range"] = "bytes=2-4"
        let response = try await client(port: server.port).send(request)
        #expect(response.status == 206)
        #expect(response.body == Data("abc".utf8))
        #expect(server.received.first?.contains("Range: bytes=2-4") == true)
    }

    @Test func wrongKeyIsRejectedInTheHandshake() async throws {
        let server = try await TestServer(credential: credential) { _ in [] }
        defer { server.stop() }
        let wrong = PhoneCredential(id: credential.id, key: Data(repeating: 1, count: 32))
        do {
            _ = try await client(port: server.port, credential: wrong).send(.get("/v1/status"))
            Issue.record("should have failed")
        } catch let error as PhoneNetworkError {
            #expect(error == .keyRejected)
        }
        #expect(server.received.isEmpty)
    }

    @Test func closedPortIsUnreachable() async throws {
        let server = try await TestServer(credential: credential) { _ in [] }
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await client(port: port).send(.get("/v1/status"))
            Issue.record("should have failed")
        } catch let error as PhoneNetworkError {
            #expect(error == .unreachable)
        }
    }

    @Test func idleServerTimesOut() async throws {
        let server = try await TestServer(credential: credential) { _ in
            try? await Task.sleep(for: .seconds(5))
            return []
        }
        defer { server.stop() }
        let started = Date()
        do {
            _ = try await client(port: server.port).send(.get("/v1/status"), idleTimeout: 0.6)
            Issue.record("should have failed")
        } catch let error as PhoneNetworkError {
            #expect(error == .timeout)
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func cancellingStopsTheRequest() async throws {
        let server = try await TestServer(credential: credential) { _ in
            try? await Task.sleep(for: .seconds(5))
            return []
        }
        defer { server.stop() }
        let client = client(port: server.port)
        let task = Task { try await client.send(.get("/v1/status"), idleTimeout: 30) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let started = Date()
        _ = await task.result
        #expect(Date().timeIntervalSince(started) < 2)
    }
}

private enum PhoneHTTP {
    static func chunk(_ data: Data) -> Data { Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8) }
    static let lastChunk = Data("0\r\n\r\n".utf8)
}
