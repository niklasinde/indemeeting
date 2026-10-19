import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The iPhone access server as the app and Settings see it. Off until turned on.
@MainActor
final class PhoneAccess: ObservableObject {
    static let shared = PhoneAccess()
    static let enabledKey = "phoneAccessEnabled"
    static let portKey = "phoneAccessPort"
    static let portRange = 1024...65535

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var status = PhoneServer.Status.stopped
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var pairing: PhonePairing?
    @Published private(set) var pairingExpires: Date?
    @Published private(set) var pairedName: String?
    @Published private(set) var pairingError: String?

    private var server: PhoneServer?
    private var devicesBeforePairing = 0

    var port: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        return Self.portRange.contains(stored) ? stored : PhoneAPI.defaultPort
    }

    var statusText: String {
        switch status {
        case .stopped: return "Off"
        case .starting: return "Starting\u{2026}"
        case .listening(let host, let port): return "Listening on \(host):\(port) \u{00B7} \(devices.count) device\(devices.count == 1 ? "" : "s") paired"
        case .failed(let message): return message
        }
    }

    var isListening: Bool {
        if case .listening = status { return true }
        return false
    }

    func configure(store: MeetingStore) {
        var endpoints = PhoneEndpoints(store: store, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
        let githubKey = GitHubModel.enabledKey
        endpoints.features = {
            PhoneFeatures(githubEnabled: UserDefaults.standard.bool(forKey: githubKey),
                          activityEnabled: UserDefaults.standard.bool(forKey: ActivitySettings.enabledKey), chatAvailable: PhoneEndpoints.chatAvailable)
        }
        endpoints.refreshGitHub = {
            await GitHubModel.shared.refresh()
            return await GitHubModel.shared.error?.message
        }
        let server = PhoneServer(store: store, secrets: KeychainSecretStore(), endpoints: endpoints)
        server.onChange = { [weak self] in Task { @MainActor in self?.sync() } }
        self.server = server
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        enabled = on
        if on { start() } else { Task { await server?.stop() } }
    }

    func setPort(_ port: Int) {
        guard Self.portRange.contains(port), port != self.port else { return }
        UserDefaults.standard.set(port, forKey: Self.portKey)
        guard enabled else { return }
        Task {
            await server?.stop()
            start()
        }
    }

    private func start() {
        Task { await server?.start(port: UInt16(port)) }
    }

    func sync() {
        guard let server else { return }
        status = server.status
        devices = server.pairedDevices
        let open = server.openPairing
        pairingExpires = open?.expires
        if pairing != nil, open == nil, pairedName == nil, devices.count > devicesBeforePairing {
            pairedName = devices.last?.name
        }
        if open == nil, pairedName == nil { pairing = nil }
    }

    func beginPairing() {
        pairedName = nil
        pairingError = nil
        pairing = nil
        devicesBeforePairing = devices.count
        Task {
            do {
                pairing = try await server?.beginPairing()
                sync()
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    func endPairing() {
        pairing = nil
        pairedName = nil
        pairingError = nil
        Task { await server?.cancelPairing() }
    }

    func revoke(_ device: PairedDevice) {
        Task { await server?.revoke(device.id) }
    }

    #if DEBUG
    func showSample(enabled: Bool, status: PhoneServer.Status, devices: [PairedDevice], pairing: PhonePairing? = nil, expires: Date? = nil,
                    pairedName: String? = nil) {
        self.enabled = enabled
        self.status = status
        self.devices = devices
        self.pairing = pairing
        self.pairingExpires = expires
        self.pairedName = pairedName
    }
    #endif
}

enum PhoneQR {
    static func image(for text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (side / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
