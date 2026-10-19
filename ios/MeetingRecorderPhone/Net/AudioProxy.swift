import Foundation
import Network

/// `AVPlayer` cannot speak TLS-PSK, so the app serves the Mac's recordings to it on `127.0.0.1`: a plain HTTP listener on a
/// random port that forwards every request, `Range` included, to the Mac through the PSK client. The first path part is a
/// random token so other apps on the phone cannot read the audio through the port.
final class AudioProxy: @unchecked Sendable {
    struct LocalRequest: Equatable {
        var method: String
        var path: String
        var range: String?
    }

    private let lock = NSLock()
    private var listener: NWListener?
    private var client: PhoneHTTPClient?
    private var port: UInt16?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let queue = DispatchQueue(label: "phone.audio.proxy")

    func use(client: PhoneHTTPClient?) { lock.withLock { self.client = client } }

    /// `http://127.0.0.1:<port>/<token>/meetings/<id>/audio.m4a`, starting the listener on first use.
    func url(forMeeting id: Int64, fileExtension: String = "m4a") async throws -> URL {
        let port = try await ensureStarted()
        return URL(string: "http://127.0.0.1:\(port)/\(token)/meetings/\(id)/audio.\(fileExtension)")!
    }

    private func ensureStarted() async throws -> UInt16 {
        if let port = lock.withLock({ port }) { return port }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [self] connection in handle(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock {
            self.listener = listener
            self.port = port
        }
        return port
    }

    func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
            port = nil
        }
    }

    // MARK: Requests

    /// The method, path and `Range` of the request in `data`, once the whole head has arrived.
    static func parseRequest(_ data: Data) -> LocalRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)), let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count == 3 else { return nil }
        let range = lines.compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "range" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }.first
        return LocalRequest(method: String(first[0]), path: String(first[1]), range: range)
    }

    /// The meeting id when `path` is `/<token>/meetings/<id>/audio...`.
    static func meetingID(inPath path: String, token: String) -> Int64? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == token, parts[1] == "meetings", parts[3].hasPrefix("audio"), let id = Int64(parts[2]) else { return nil }
        return id
    }

    private static let passedHeaders = ["content-type", "content-length", "content-range", "accept-ranges"]

    static func localHead(for head: HTTPResponseHead) -> Data {
        var headers = ["Connection": "close"]
        for name in passedHeaders { headers[name.capitalized] = head.header(name) }
        return PhoneHTTPHead.data(status: head.status, reason: head.reason, headers: headers.compactMapValues { $0 })
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { [self] in
            if let request = await Self.readRequest(connection) {
                let serving = Task { await serve(request, on: connection) }
                let watcher = Task {
                    _ = await Self.receive(connection)
                    serving.cancel()
                }
                await serving.value
                watcher.cancel()
            }
            connection.cancel()
        }
    }

    private static func readRequest(_ connection: NWConnection) async -> LocalRequest? {
        var received = Data()
        while received.count < 16 * 1024 {
            guard let more = await receive(connection) else { return nil }
            received.append(more)
            if let request = parseRequest(received) { return request }
        }
        return nil
    }

    private func serve(_ request: LocalRequest, on connection: NWConnection) async {
        let empty = { (status: Int, reason: String) in
            PhoneHTTPHead.data(status: status, reason: reason, headers: ["Content-Length": "0", "Connection": "close"])
        }
        guard let id = Self.meetingID(inPath: request.path, token: token), request.method == "GET" || request.method == "HEAD" else {
            try? await Self.write(connection, empty(404, "Not Found"))
            return
        }
        guard let client = lock.withLock({ client }) else {
            try? await Self.write(connection, empty(503, "Service Unavailable"))
            return
        }
        var upstream = PhoneRequest.get("/v1/meetings/\(id)/audio")
        if let range = request.range { upstream.headers["Range"] = range }
        do {
            for try await event in client.stream(upstream, idleTimeout: 30) {
                switch event {
                case .head(let head):
                    try await Self.write(connection, Self.localHead(for: head))
                    if request.method == "HEAD" { return }
                case .body(let data): try await Self.write(connection, data)
                case .end: return
                }
            }
        } catch {
            if !Task.isCancelled { try? await Self.write(connection, empty(502, "Bad Gateway")) }
        }
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                continuation.resume(returning: error == nil ? data : nil)
            }
        }
    }

    private static func write(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

enum PhoneHTTPHead {
    static func data(status: Int, reason: String, headers: [String: String]) -> Data {
        Data((["HTTP/1.1 \(status) \(reason)"] + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }).joined(separator: "\r\n").appending("\r\n\r\n").utf8)
    }
}
