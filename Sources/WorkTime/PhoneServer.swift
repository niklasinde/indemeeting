import Foundation
import Network

/// The iPhone access server: a main listener for paired devices and, while a pairing is open, a second one that
/// accepts only `POST /v1/pair`. Everything a request may read comes from `PhoneEndpoints`.
final class PhoneServer: @unchecked Sendable {
    enum Status: Equatable {
        case stopped
        case starting
        case listening(host: String, port: UInt16)
        case failed(String)
    }

    private struct Device {
        var device: PairedDevice
        let key: Data
    }

    static let maxConnections = 24
    static let idleSeconds: TimeInterval = 60
    static let touchInterval: TimeInterval = 60

    let store: MeetingStore
    private let secrets: PhoneSecretStore
    private let hostName: String
    private let now: @Sendable () -> Date
    private var endpoints: PhoneEndpoints
    private let lock = NSLock()
    private var devices: [String: Device] = [:]
    private var pairings = PhonePairings()
    private var limiter = FailureLimiter()
    private var activeConnections = 0
    private var expiry: Task<Void, Never>?
    private var restarting: Task<Void, Never>?
    private var desiredPort: UInt16 = 0
    private var _status = Status.stopped
    private lazy var main = PhoneListener(label: "main", onConnection: { [weak self] in self?.accept($0, pairing: false) },
                                          onFailure: { [weak self] in self?.listenerFailed($0) })
    private lazy var pairing = PhoneListener(label: "pairing", onConnection: { [weak self] in self?.accept($0, pairing: true) },
                                             onFailure: { _ in })

    /// Called when the status, the paired devices or the open pairing change.
    var onChange: (@Sendable () -> Void)?

    init(store: MeetingStore, secrets: PhoneSecretStore, endpoints: PhoneEndpoints, hostName: String = PhoneServer.localHostName(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.secrets = secrets
        self.endpoints = endpoints
        self.hostName = hostName
        self.now = now
    }

    static func localHostName() -> String {
        let name = ProcessInfo.processInfo.hostName
        return (name.split(separator: ".").first.map(String.init) ?? name) + ".local"
    }

    var status: Status { lock.withLock { _status } }
    var pairedDevices: [PairedDevice] { lock.withLock { devices.values.map(\.device).sorted { $0.created < $1.created } } }
    var openPairing: PendingPairing? { lock.withLock { pairings.pending } }

    private func set(_ status: Status) {
        lock.withLock { _status = status }
        onChange?()
    }

    // MARK: Running

    func start(port: UInt16) async {
        guard status == .stopped || { if case .failed = status { return true } else { return false } }() else { return }
        set(.starting)
        lock.withLock { desiredPort = port }
        loadDevices()
        do {
            let bound = try await main.start(port: port, credentials: credentials(), advertise: true)
            set(.listening(host: hostName, port: bound))
            phoneLog.notice("listening on port \(bound)")
        } catch {
            set(.failed(Self.explain(error, port: port)))
            phoneLog.error("could not listen on port \(port): \(error.localizedDescription)")
        }
    }

    func stop() async {
        lock.withLock {
            expiry?.cancel()
            restarting?.cancel()
            pairings.cancel()
        }
        await pairing.stop()
        await main.stop()
        main.cancelConnections()
        pairing.cancelConnections()
        set(.stopped)
    }

    private func listenerFailed(_ error: Error) {
        phoneLog.error("listener failed: \(error.localizedDescription)")
        let port = lock.withLock { desiredPort }
        lock.withLock {
            restarting?.cancel()
            restarting = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.set(.stopped)
                await self.start(port: port)
            }
        }
        set(.failed(Self.explain(error, port: port)))
    }

    static func explain(_ error: Error, port: UInt16) -> String {
        if let error = error as? NWError, case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is in use. Choose another port."
        }
        return error.localizedDescription
    }

    private func loadDevices() {
        let stored = (try? store.pairedDevices()) ?? []
        var loaded: [String: Device] = [:]
        for device in stored {
            if let key = secrets.key(for: device.id) { loaded[device.id] = Device(device: device, key: key) } else { try? store.deletePairedDevice(device.id) }
        }
        lock.withLock { devices = loaded }
    }

    private func credentials() -> [PhoneCredential] {
        lock.withLock { devices.map { PhoneCredential(id: $0.key, key: $0.value.key) } }
    }

    // MARK: Pairing

    /// Opens a pairing: the listener it needs, and a key that is good for the next five minutes and one device.
    func beginPairing(lifetime: TimeInterval = PhoneAPI.pairingLifetime) async throws -> PhonePairing {
        guard case .listening = status else { throw PhoneRequestError(status: 409, code: "not_listening", message: "iPhone access is off.") }
        await pairing.stop()
        let pending = lock.withLock { pairings.begin(now: now(), lifetime: lifetime) }
        let port = try await pairing.start(port: 0, credentials: [PhoneCredential(id: pending.id, key: pending.key)], advertise: false)
        lock.withLock {
            expiry?.cancel()
            expiry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(lifetime, 0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.expirePairing()
            }
        }
        onChange?()
        phoneLog.notice("pairing opened")
        return PhonePairing(host: hostName, port: Int(port), id: pending.id, key: pending.key)
    }

    func cancelPairing() async {
        lock.withLock {
            expiry?.cancel()
            pairings.cancel()
        }
        await pairing.stop()
        pairing.cancelConnections()
        onChange?()
    }

    private func expirePairing() async {
        guard lock.withLock({ pairings.expire(now: now()) }) else { return }
        await pairing.stop()
        pairing.cancelConnections()
        onChange?()
        phoneLog.notice("pairing expired")
    }

    private func completePairing(_ request: HTTPRequest) async -> PhoneResponse {
        guard let body = try? PhoneAPI.decoder.decode(PhonePairRequest.self, from: request.body) else {
            return .error(400, "bad_request", "The body is not a pairing request.")
        }
        let name = String(body.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return .error(400, "bad_request", "deviceName is required.") }
        let outcome = lock.withLock { pairings.consume(now: now()) }
        guard case .success = outcome else {
            phoneLog.notice("pairing refused: \(outcome == .failure(.expired) ? "expired" : "not open")")
            return .error(403, "pairing_closed", "This pairing code has expired or was already used.")
        }
        let id = Self.unusedID(devices: lock.withLock { Set(devices.keys) })
        let key = PhoneSecrets.newKey()
        let device = PairedDevice(id: id, name: name, created: now(), lastSeen: now())
        do {
            try secrets.save(key, for: id)
            try store.addPairedDevice(device)
        } catch {
            secrets.delete(id)
            phoneLog.error("could not store the new device: \(error.localizedDescription)")
            return .error(500, "internal", "The Mac could not save the pairing.")
        }
        lock.withLock {
            devices[id] = Device(device: device, key: key)
            expiry?.cancel()
        }
        do { try await main.restart(credentials: credentials(), advertise: true) } catch {
            phoneLog.error("could not restart the listener: \(error.localizedDescription)")
        }
        Task { await pairing.stop() }
        onChange?()
        phoneLog.notice("device paired")
        guard case .listening(_, let port) = status else { return .error(503, "unavailable", "iPhone access stopped.") }
        return .json(PhonePairResult(deviceId: id, key: key.base64EncodedString(), serverName: endpoints.serverName, host: hostName,
                                     port: Int(port), apiVersion: PhoneAPI.version))
    }

    private static func unusedID(devices: Set<String>) -> String {
        var id = PhoneSecrets.newID()
        while devices.contains(id) { id = PhoneSecrets.newID() }
        return id
    }

    /// Forgets a device: its key is deleted, so it can no longer complete a handshake, and open connections are dropped.
    func revoke(_ id: String) async {
        secrets.delete(id)
        try? store.deletePairedDevice(id)
        lock.withLock { devices[id] = nil }
        if case .listening = status {
            do { try await main.restart(credentials: credentials(), advertise: true) } catch {
                set(.failed(Self.explain(error, port: lock.withLock { desiredPort })))
            }
        }
        main.cancelConnections()
        onChange?()
        phoneLog.notice("device revoked")
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, pairing isPairing: Bool) {
        let session = PhoneSession(connection)
        let admitted = lock.withLock { () -> Bool in
            guard !limiter.isBlocked(session.peer, now: now()), activeConnections < Self.maxConnections else { return false }
            activeConnections += 1
            return true
        }
        guard admitted else {
            phoneLog.notice("refused a connection: blocked or too many")
            connection.cancel()
            return
        }
        Task {
            await serve(session, pairing: isPairing)
            lock.withLock { activeConnections -= 1 }
            (isPairing ? pairing : main).forget(connection)
            session.close()
        }
    }

    private func failed(_ session: PhoneSession, _ reason: String) {
        lock.withLock { limiter.record(session.peer, now: now()) }
        phoneLog.notice("authentication failed: \(reason)")
    }

    private func serve(_ session: PhoneSession, pairing isPairing: Bool) async {
        do { try await session.start() } catch {
            failed(session, "handshake \((error as NSError).code)")
            return
        }
        var buffer = Data()
        while true {
            let request: HTTPRequest
            do {
                guard let next = try await readRequest(session, &buffer) else { return }
                request = next
            } catch {
                return
            }
            let keepOpen = await respond(to: request, on: session, pairing: isPairing)
            if !keepOpen { return }
        }
    }

    private func readRequest(_ session: PhoneSession, _ buffer: inout Data) async throws -> HTTPRequest? {
        while true {
            switch PhoneHTTP.parse(buffer) {
            case .request(let request, let consumed):
                buffer.removeFirst(consumed)
                return request
            case .failure(let status):
                try await write(.error(status, "bad_request", "The request could not be understood."), to: session, keepAlive: false)
                return nil
            case .incomplete:
                guard let more = try await session.receive(idle: Self.idleSeconds) else { return nil }
                buffer += more
            }
        }
    }

    /// Answers one request; false when the connection should be closed afterwards.
    private func respond(to request: HTTPRequest, on session: PhoneSession, pairing isPairing: Bool) async -> Bool {
        do {
            if isPairing {
                guard request.method == "POST", request.path == "/v1/pair" else {
                    try await write(.error(404, "not_found", "Only POST /v1/pair is served here."), to: session, keepAlive: false)
                    return false
                }
                try await write(await completePairing(request), to: session, keepAlive: false)
                return false
            }
            let paired = lock.withLock { Set(devices.keys) }
            switch PhoneAuth.decide(claimed: request.header(PhoneAPI.deviceHeader), paired: paired) {
            case .denied(let reason):
                failed(session, reason.rawValue)
                try await write(.error(401, reason.rawValue, "This device is not paired with this Mac."), to: session, keepAlive: false)
                return false
            case .allowed(let id):
                touch(id)
            }
            switch await endpoints.handle(request) {
            case .response(let response):
                try await write(response, to: session, keepAlive: request.header("connection")?.lowercased() != "close")
                return request.header("connection")?.lowercased() != "close"
            case .chat(let job):
                try await stream(job, to: session)
                return false
            }
        } catch {
            return false
        }
    }

    private func touch(_ id: String) {
        let stamp = now()
        let due = lock.withLock { () -> Bool in
            guard var entry = devices[id], entry.device.lastSeen.map({ stamp.timeIntervalSince($0) >= Self.touchInterval }) ?? true else { return false }
            entry.device.lastSeen = stamp
            devices[id] = entry
            return true
        }
        guard due else { return }
        try? store.touchPairedDevice(id, at: stamp)
    }

    // MARK: Writing

    private func write(_ response: PhoneResponse, to session: PhoneSession, keepAlive: Bool) async throws {
        var headers = response.headers
        headers["Content-Type"] = response.contentType
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        switch response.body {
        case .data(let data):
            headers["Content-Length"] = String(data.count)
            try await session.send(PhoneHTTP.head(status: response.status, headers: headers) + data)
        case .file(let url, let offset, let length):
            headers["Content-Length"] = String(length)
            try await session.send(PhoneHTTP.head(status: response.status, headers: headers))
            guard let file = try? FileHandle(forReadingFrom: url) else { throw PhoneConnectionClosed() }
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(offset))
            var remaining = length
            while remaining > 0 {
                guard let chunk = try file.read(upToCount: Int(min(remaining, 256 * 1024))), !chunk.isEmpty else { throw PhoneConnectionClosed() }
                try await session.send(chunk)
                remaining -= Int64(chunk.count)
            }
        }
    }

    private func stream(_ job: PhoneChatJob, to session: PhoneSession) async throws {
        #if canImport(FoundationModels)
        if let reason = ChatEngine.unavailable {
            return try await write(.error(503, "chat_unavailable", reason.title), to: session, keepAlive: false)
        }
        guard PhoneChatGate.shared.acquire() else {
            return try await write(.error(429, "chat_busy", "The Mac is answering another question. Try again in a moment.",
                                          headers: ["Retry-After": "3"]), to: session, keepAlive: false)
        }
        let head = ["Content-Type": "application/x-ndjson", "Transfer-Encoding": "chunked", "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff", "Connection": "close"]
        do { try await session.send(PhoneHTTP.head(status: 200, headers: head)) } catch {
            PhoneChatGate.shared.release()
            throw error
        }
        let events = job.events(store: store)
        let consumer = Task {
            for await event in events { try await session.send(PhoneHTTP.chunk(try PhoneAPI.encoder.encode(event) + Data("\n".utf8))) }
            try await session.send(PhoneHTTP.lastChunk)
        }
        let watcher = Task {
            _ = try? await session.receive(idle: nil)
            consumer.cancel()
        }
        defer { watcher.cancel() }
        try await consumer.value
        #else
        try await write(.error(503, "chat_unavailable", "This Mac cannot run the on-device model."), to: session, keepAlive: false)
        #endif
    }
}
