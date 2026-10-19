import Foundation
import Network

struct DiscoveredMac: Equatable {
    var name: String
    var endpoint: NWEndpoint
}

/// Decides which addresses to try for the paired Mac: a host the user typed, then the Mac found by Bonjour, then the
/// host and port stored from pairing.
final class MacLocator: @unchecked Sendable {
    private let lock = NSLock()
    private var mac: PairedMac?
    private var discovered: [DiscoveredMac] = []

    func update(mac: PairedMac?) { lock.withLock { self.mac = mac } }
    func update(discovered: [DiscoveredMac]) { lock.withLock { self.discovered = discovered } }

    func endpoints() -> [NWEndpoint] {
        let (mac, discovered) = lock.withLock { (self.mac, self.discovered) }
        guard let mac else { return [] }
        return Self.order(mac: mac, discovered: discovered)
    }

    static func hostPort(_ address: PairedMac.HostPort) -> NWEndpoint? {
        NWEndpoint.Port(rawValue: UInt16(clamping: address.port)).map { .hostPort(host: NWEndpoint.Host(address.host), port: $0) }
    }

    static func order(mac: PairedMac, discovered: [DiscoveredMac]) -> [NWEndpoint] {
        let named = discovered.filter { mac.serverName.lowercased().hasPrefix($0.name.lowercased()) }
        let bonjour = (named.isEmpty ? discovered : named).map(\.endpoint)
        let typed = mac.override.flatMap(hostPort).map { [$0] } ?? []
        let paired = hostPort(PairedMac.HostPort(host: mac.host, port: mac.port)).map { [$0] } ?? []
        return typed + bonjour + paired
    }
}

/// Browses the network for the Mac's `_meetingrecorder._tcp` service.
final class MacDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "phone.discovery")
    private let onChange: @Sendable ([DiscoveredMac]) -> Void

    init(onChange: @escaping @Sendable ([DiscoveredMac]) -> Void) { self.onChange = onChange }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: PhoneAPI.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [onChange] results, _ in
            onChange(results.compactMap { result in
                if case .service(let name, _, _, _) = result.endpoint { return DiscoveredMac(name: name, endpoint: result.endpoint) }
                return nil
            })
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
