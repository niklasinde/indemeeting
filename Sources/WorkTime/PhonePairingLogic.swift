import Foundation

struct PendingPairing: Equatable {
    let id: String
    let key: Data
    let created: Date
    let lifetime: TimeInterval

    var expires: Date { created.addingTimeInterval(lifetime) }
}

enum PairingFailure: Error, Equatable {
    case unknown
    case expired
}

/// The one pairing that may be open: valid for a few minutes and spent by the first device that completes it.
struct PhonePairings {
    private(set) var pending: PendingPairing?

    mutating func begin(now: Date, lifetime: TimeInterval = PhoneAPI.pairingLifetime) -> PendingPairing {
        let pairing = PendingPairing(id: PhoneSecrets.newID(), key: PhoneSecrets.newKey(PhonePairing.keyLength), created: now, lifetime: lifetime)
        pending = pairing
        return pairing
    }

    mutating func cancel() { pending = nil }

    /// Drops the pairing once it has expired and says whether it did.
    mutating func expire(now: Date) -> Bool {
        guard let pending, now >= pending.expires else { return false }
        self.pending = nil
        return true
    }

    /// Spends the open pairing when it has not expired; it cannot be used again. The listener it belongs to accepts
    /// only its key, so whoever gets here holds that key.
    mutating func consume(now: Date) -> Result<PendingPairing, PairingFailure> {
        guard let pairing = pending else { return .failure(.unknown) }
        pending = nil
        return now < pairing.expires ? .success(pairing) : .failure(.expired)
    }
}

enum PhoneSecrets {
    /// Random bytes from the system generator, which is cryptographically secure.
    static func newKey(_ length: Int = 32) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func newID() -> String {
        newKey(PhonePairing.idLength).map { String(format: "%02x", $0) }.joined()
    }
}

enum PhoneAuth {
    enum Denied: String, Equatable {
        case missingDevice = "missing_device"
        case unknownDevice = "unknown_device"
    }

    enum Decision: Equatable {
        case allowed(deviceID: String)
        case denied(Denied)
    }

    /// Every request on the main port is made over a connection whose handshake proved a device key. The device id
    /// names which device it is, and must be one that is still paired.
    static func decide(claimed: String?, paired: Set<String>) -> Decision {
        guard let claimed, !claimed.isEmpty else { return .denied(.missingDevice) }
        return paired.contains(claimed.lowercased()) ? .allowed(deviceID: claimed.lowercased()) : .denied(.unknownDevice)
    }
}

/// Refuses a peer that failed to authenticate too often in a short time.
struct FailureLimiter {
    var maxFailures = 8
    var window: TimeInterval = 60
    var lockout: TimeInterval = 120
    private var failures: [String: [Date]] = [:]
    private var blocked: [String: Date] = [:]

    mutating func record(_ peer: String, now: Date) {
        let recent = (failures[peer] ?? []).filter { now.timeIntervalSince($0) < window } + [now]
        failures[peer] = recent
        if recent.count >= maxFailures { blocked[peer] = now.addingTimeInterval(lockout) }
    }

    mutating func isBlocked(_ peer: String, now: Date) -> Bool {
        guard let until = blocked[peer] else { return false }
        if now >= until {
            blocked[peer] = nil
            failures[peer] = nil
            return false
        }
        return true
    }
}

struct PairedDevice: Equatable, Identifiable {
    let id: String
    var name: String
    let created: Date
    var lastSeen: Date?
}

/// Where the keys of the paired devices are kept.
protocol PhoneSecretStore: Sendable {
    func key(for id: String) -> Data?
    func save(_ key: Data, for id: String) throws
    func delete(_ id: String)
}

/// Keys in memory only, for the tests.
final class MemorySecretStore: PhoneSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    func key(for id: String) -> Data? { lock.withLock { keys[id] } }
    func save(_ key: Data, for id: String) throws { lock.withLock { keys[id] = key } }
    func delete(_ id: String) { lock.withLock { keys[id] = nil } }
}

extension MeetingStore {
    static let phoneDevicesDidChange = Notification.Name("PhoneDevicesDidChange")

    func pairedDevices() throws -> [PairedDevice] {
        try read {
            try db.query("SELECT id, name, created, last_seen FROM paired_devices ORDER BY created") {
                PairedDevice(id: $0.string(0), name: $0.string(1), created: Date(timeIntervalSince1970: $0.double(2)),
                             lastSeen: $0.optionalDouble(3).map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    func addPairedDevice(_ device: PairedDevice) throws {
        try write(notify: Self.phoneDevicesDidChange) {
            try db.run("INSERT INTO paired_devices (id, name, created) VALUES (?, ?, ?)",
                       [device.id, device.name, device.created.timeIntervalSince1970])
        }
    }

    func touchPairedDevice(_ id: String, at date: Date) throws {
        try write(notify: Self.phoneDevicesDidChange) {
            try db.run("UPDATE paired_devices SET last_seen = ? WHERE id = ?", [date.timeIntervalSince1970, id])
        }
    }

    func deletePairedDevice(_ id: String) throws {
        try write(notify: Self.phoneDevicesDidChange) { try db.run("DELETE FROM paired_devices WHERE id = ?", [id]) }
    }
}
