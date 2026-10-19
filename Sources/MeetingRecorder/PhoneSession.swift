import Foundation
import Network

struct PhoneConnectionClosed: Error {}

/// One accepted connection read and written with async calls.
final class PhoneSession: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "phone-session")
    private var idle: DispatchWorkItem?

    init(_ connection: NWConnection) { self.connection = connection }

    /// The peer's address without the interface scope, for rate limiting and logs.
    var peer: String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "unknown" }
        return "\(host)".split(separator: "%").first.map(String.init) ?? "unknown"
    }

    /// Completes the handshake; fails with the TLS error when the peer does not hold a key the listener accepts.
    func start() async throws {
        nonisolated(unsafe) var finished = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    finished = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    finished = true
                    continuation.resume(throwing: PhoneConnectionClosed())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Reads more bytes, or nil when the peer closed. A connection that stays silent for `idle` seconds is closed.
    func receive(idle seconds: TimeInterval) async throws -> Data? {
        arm(seconds)
        defer { disarm() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) } else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) } else { continuation.resume(returning: Data()) }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func close() {
        disarm()
        connection.cancel()
    }

    private func arm(_ seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.connection.cancel() }
        queue.async {
            self.idle?.cancel()
            self.idle = item
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func disarm() {
        queue.async {
            self.idle?.cancel()
            self.idle = nil
        }
    }
}
