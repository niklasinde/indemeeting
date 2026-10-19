import Foundation
import Network

/// A small HTTP/1.1 client over `NWConnection` with the TLS pre-shared key, because `URLSession` cannot do TLS-PSK.
/// Each request gets its own connection (`Connection: close`), so cancelling a request closes the socket, which also
/// cancels a chat generation on the Mac. Several addresses can be given; the next one is tried when one is unreachable.
final class PhoneHTTPClient: @unchecked Sendable {
    let credential: PhoneCredential
    private let endpoints: @Sendable () -> [NWEndpoint]
    private let connectTimeout: TimeInterval
    private let identifiesDevice: Bool

    /// `identifiesDevice` adds `X-Device-Id`; everything but the pairing request carries it.
    init(credential: PhoneCredential, identifiesDevice: Bool = true, connectTimeout: TimeInterval = 6,
         endpoints: @escaping @Sendable () -> [NWEndpoint]) {
        self.credential = credential
        self.identifiesDevice = identifiesDevice
        self.connectTimeout = connectTimeout
        self.endpoints = endpoints
    }

    /// The whole response, buffered. A GET is tried a second time when the connection fails before any answer.
    func send(_ request: PhoneRequest, idleTimeout: TimeInterval = 20) async throws -> PhoneResponse {
        var head: HTTPResponseHead?
        var body = Data()
        for try await event in stream(request, idleTimeout: idleTimeout) {
            switch event {
            case .head(let value): head = value
            case .body(let data): body.append(data)
            case .end: break
            }
        }
        try Task.checkCancellation()
        guard let head else { throw PhoneNetworkError.connectionLost }
        return PhoneResponse(head: head, body: body)
    }

    func json<T: Decodable>(_ request: PhoneRequest, idleTimeout: TimeInterval = 20) async throws -> T {
        try await send(request, idleTimeout: idleTimeout).decoded(T.self)
    }

    /// Head, body pieces and end as they arrive. Ending the iteration closes the connection.
    func stream(_ request: PhoneRequest, idleTimeout: TimeInterval = 20) -> AsyncThrowingStream<HTTPResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                var failure = PhoneNetworkError.unreachable
                for _ in 0..<(request.method == "GET" ? 2 : 1) {
                    for endpoint in endpoints() {
                        var answered = false
                        do {
                            for try await event in connect(to: endpoint, request, idleTimeout: idleTimeout) {
                                if case .head = event { answered = true }
                                continuation.yield(event)
                            }
                            continuation.finish()
                            return
                        } catch let error as PhoneNetworkError where error.isConnectionFailure && !answered {
                            failure = error
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    if failure == .unreachable || failure == .timeout { break }
                }
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func connect(to endpoint: NWEndpoint, _ request: PhoneRequest, idleTimeout: TimeInterval) -> AsyncThrowingStream<HTTPResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            let connection = NWConnection(to: endpoint, using: PhoneTransport.parameters([credential]))
            let run = ConnectionRun(connection: connection, continuation: continuation, connectTimeout: connectTimeout, idleTimeout: idleTimeout,
                                    payload: request.serialized(host: Self.hostHeader(endpoint), deviceId: identifiesDevice ? credential.id : nil))
            continuation.onTermination = { _ in run.cancel() }
            run.start()
        }
    }

    static func hostHeader(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _): return "\(host)".components(separatedBy: "%").first ?? "\(host)"
        default: return "mac.local"
        }
    }
}

/// One connection, one request. Everything runs on its own serial queue.
private final class ConnectionRun: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: AsyncThrowingStream<HTTPResponseEvent, Error>.Continuation
    private let queue = DispatchQueue(label: "phone.http.run")
    private let connectTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let payload: Data
    private var parser = HTTPResponseParser()
    private var timer: DispatchWorkItem?
    private var finished = false

    init(connection: NWConnection, continuation: AsyncThrowingStream<HTTPResponseEvent, Error>.Continuation, connectTimeout: TimeInterval,
         idleTimeout: TimeInterval, payload: Data) {
        self.connection = connection
        self.continuation = continuation
        self.connectTimeout = connectTimeout
        self.idleTimeout = idleTimeout
        self.payload = payload
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                arm(idleTimeout)
                connection.send(content: payload, completion: .contentProcessed { [self] error in
                    if let error { finish(PhoneNetworkError.classify(error)) } else { receive() }
                })
            case .waiting(let error), .failed(let error):
                finish(PhoneNetworkError.classify(error))
            case .cancelled:
                finish(nil)
            default: break
            }
        }
        arm(connectTimeout)
        connection.start(queue: queue)
    }

    func cancel() {
        queue.async { [self] in finish(nil) }
    }

    private func arm(_ seconds: TimeInterval) {
        timer?.cancel()
        let item = DispatchWorkItem { [self] in finish(.timeout) }
        timer = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            guard !finished else { return }
            if let data, !data.isEmpty {
                arm(idleTimeout)
                do {
                    for event in try parser.feed(data) { continuation.yield(event) }
                } catch {
                    return finish(.badResponse)
                }
                if parser.isComplete { return finish(nil) }
            }
            if let error { return finish(PhoneNetworkError.classify(error)) }
            if isComplete {
                do {
                    for event in try parser.connectionClosed() { continuation.yield(event) }
                    finish(nil)
                } catch {
                    finish(.connectionLost)
                }
            } else {
                receive()
            }
        }
    }

    private func finish(_ error: PhoneNetworkError?) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
