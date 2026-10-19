import Foundation

/// The paired Mac: where it listens and which device identity the phone uses. The key itself is in the Keychain.
struct PairedMac: Codable, Equatable {
    var deviceId: String
    var serverName: String
    var host: String
    var port: Int
    /// A host and port the user typed in Settings, tried before the paired one.
    var override: HostPort?
    var pairedAt: Date

    struct HostPort: Codable, Equatable {
        var host: String
        var port: Int
    }

    var address: HostPort { override ?? HostPort(host: host, port: port) }
}

protocol PairedMacStore: Sendable {
    func load() -> PairedMac?
    func save(_ mac: PairedMac?)
}

struct DefaultsPairedMacStore: PairedMacStore, @unchecked Sendable {
    var defaults = UserDefaults.standard
    var key = "pairedMac"

    func load() -> PairedMac? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
    }

    func save(_ mac: PairedMac?) {
        defaults.set(mac.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

final class MemoryPairedMacStore: PairedMacStore, @unchecked Sendable {
    private let lock = NSLock()
    private var mac: PairedMac?

    func load() -> PairedMac? { lock.withLock { mac } }
    func save(_ mac: PairedMac?) { lock.withLock { self.mac = mac } }
}
