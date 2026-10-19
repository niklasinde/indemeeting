import Foundation
import Network
import Observation
import UIKit

enum Reachability: Equatable {
    case unknown
    case online(Date)
    case offline(PhoneNetworkError, since: Date)
}

/// Everything the screens share: the paired Mac, the connection to it, the cache and the audio player.
@Observable @MainActor
final class AppModel {
    private(set) var mac: PairedMac?
    private(set) var reachability = Reachability.unknown
    private(set) var status: PhoneStatus?
    /// The Mac refused the key: the phone has to be paired again.
    private(set) var needsRepair = false
    /// A pairing that arrived as a `meetingrecorder://` link, waiting for the user to confirm.
    var incomingPairing: PhonePairing?
    private(set) var discovered: [DiscoveredMac] = []

    let player: AudioPlayer
    let cache: PhoneCache?

    private let keys: DeviceKeyStore
    private let macStore: PairedMacStore
    private let locator = MacLocator()
    private let proxy = AudioProxy()
    private var discovery: MacDiscovery?
    private(set) var client: PhoneHTTPClient?

    init(keys: DeviceKeyStore = KeychainKeyStore(), macStore: PairedMacStore = DefaultsPairedMacStore(), cache: PhoneCache? = nil) {
        self.keys = keys
        self.macStore = macStore
        self.cache = cache ?? (try? PhoneCache(path: PhoneCache.defaultURL().path))
        player = AudioPlayer(proxy: proxy)
        discovery = MacDiscovery { [weak self, locator] found in
            locator.update(discovered: found)
            Task { @MainActor in self?.discovered = found }
        }
        if let saved = macStore.load(), keys.key(for: saved.deviceId) != nil { activate(saved) }
        else if macStore.load() != nil { macStore.save(nil) }
    }

    var isPaired: Bool { mac != nil }

    func startDiscovery() { discovery?.start() }
    func stopDiscovery() { discovery?.stop() }

    private func activate(_ paired: PairedMac) {
        mac = paired
        locator.update(mac: paired)
        needsRepair = false
        guard let key = keys.key(for: paired.deviceId) else { return }
        let locator = locator
        let client = PhoneHTTPClient(credential: PhoneCredential(id: paired.deviceId, key: key)) { locator.endpoints() }
        self.client = client
        proxy.use(client: client)
        discovery?.start()
    }

    // MARK: Pairing

    func pair(_ pairing: PhonePairing, keepAddress: Bool = false) async throws {
        let paired = try await PairingService.pair(pairing, deviceName: UIDevice.current.name, keys: keys, keepAddress: keepAddress)
        if let old = mac, old.deviceId != paired.deviceId { keys.delete(old.deviceId) }
        cache?.clear()
        macStore.save(paired)
        status = nil
        reachability = .online(Date())
        activate(paired)
    }

    /// Deletes the key and everything cached from the Mac. The Mac keeps listing this phone until it is revoked there.
    func forget() {
        player.stop()
        if let mac { keys.delete(mac.deviceId) }
        macStore.save(nil)
        cache?.clear()
        mac = nil
        client = nil
        status = nil
        needsRepair = false
        reachability = .unknown
        locator.update(mac: nil)
        proxy.use(client: nil)
    }

    func setAddressOverride(_ address: PairedMac.HostPort?) {
        guard var mac else { return }
        mac.override = address
        macStore.save(mac)
        self.mac = mac
        locator.update(mac: mac)
    }

    func dismissRepair() { needsRepair = false }

    func handle(url: URL) {
        guard let pairing = PhonePairing(url: url) else { return }
        incomingPairing = pairing
    }

    // MARK: Requests

    func report(_ error: Error) {
        guard let error = error as? PhoneNetworkError else { return }
        if error.isRejection {
            needsRepair = true
        } else if error.isConnectionFailure || error == .blocked {
            reachability = .offline(error, since: reachability.offlineSince ?? Date())
        }
    }

    func reportSuccess() {
        reachability = .online(Date())
        needsRepair = false
    }

    func request<T: Decodable & Sendable>(_ request: PhoneRequest, idleTimeout: TimeInterval = 20) async throws -> T {
        guard let client else { throw PhoneNetworkError.notPaired }
        do {
            let value: T = try await client.json(request, idleTimeout: idleTimeout)
            reportSuccess()
            return value
        } catch let error as PhoneNetworkError {
            if case .http = error, !error.isRejection { reportSuccess() }
            report(error)
            throw error
        }
    }

    func refreshStatus() async {
        guard let value: PhoneStatus = try? await request(.get("/v1/status")) else { return }
        status = value
        cache?.put(value, for: "status")
    }

    func loadCachedStatus() {
        if status == nil { status = cache?.get(PhoneStatus.self, for: "status")?.value }
    }

    // MARK: Chat

    func chatStream(_ request: PhoneChatRequest) throws -> AsyncThrowingStream<HTTPResponseEvent, Error> {
        guard let client else { throw PhoneNetworkError.notPaired }
        return client.stream(try .post("/v1/chat", json: request), idleTimeout: 120)
    }
}

extension Reachability {
    var offlineSince: Date? {
        if case .offline(_, let since) = self { return since }
        return nil
    }

    var isOffline: Bool { offlineSince != nil }
}
