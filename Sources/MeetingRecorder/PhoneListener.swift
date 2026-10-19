import Foundation
import Network
import os

let phoneLog = Logger(subsystem: "com.niklasinde.MeetingRecorder", category: "phone")

/// One listening socket whose connections are encrypted with the keys it was started with. Changing the keys means
/// starting a new socket, since the handshake takes them from the listener's options.
final class PhoneListener: @unchecked Sendable {
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var port: UInt16 = 0
    private let onConnection: @Sendable (NWConnection) -> Void
    private let onFailure: @Sendable (Error) -> Void

    init(label: String, onConnection: @escaping @Sendable (NWConnection) -> Void, onFailure: @escaping @Sendable (Error) -> Void) {
        queue = DispatchQueue(label: "phone-listener-\(label)")
        self.onConnection = onConnection
        self.onFailure = onFailure
    }

    /// Starts listening and returns the port, which is the one asked for or, for 0, one the system picked.
    func start(port requested: UInt16, credentials: [PhoneCredential], advertise: Bool) async throws -> UInt16 {
        let listener = try NWListener(using: PhoneTransport.parameters(credentials),
                                      on: requested == 0 ? .any : NWEndpoint.Port(rawValue: requested)!)
        if advertise { listener.service = NWListener.Service(type: PhoneAPI.serviceType) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        nonisolated(unsafe) var resumed = false
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready where !resumed:
                    resumed = true
                    self?.listener = listener
                    continuation.resume(returning: listener.port?.rawValue ?? requested)
                case .failed(let error):
                    listener.cancel()
                    if resumed { self?.onFailure(error) } else {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        port = bound
        return bound
    }

    /// Starts again with other keys on the port it had.
    func restart(credentials: [PhoneCredential], advertise: Bool) async throws {
        await stop()
        _ = try await start(port: port, credentials: credentials, advertise: advertise)
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let listener = self.listener, listener.state != .cancelled else {
                    self.listener = nil
                    return continuation.resume()
                }
                self.listener = nil
                listener.stateUpdateHandler = { if case .cancelled = $0 { continuation.resume() } }
                listener.cancel()
            }
        }
    }

    func cancelConnections() {
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections = [:]
        }
    }

    func forget(_ connection: NWConnection) {
        queue.async { self.connections[ObjectIdentifier(connection)] = nil }
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        onConnection(connection)
    }
}
