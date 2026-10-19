#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `MeetingRecorder --render-phone <folder>` saves PNGs of the iPhone section of Settings (off, on with two
/// paired devices) and of the pairing sheet, with made-up devices.
enum PhonePreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-phone", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = PhoneAccess.shared
        let now = Date()
        let devices = [PairedDevice(id: "6edabb92", name: "Niklas\u{2019}s iPhone", created: now.addingTimeInterval(-9 * 86400), lastSeen: now.addingTimeInterval(-240)),
                       PairedDevice(id: "dd57d179", name: "iPad Air", created: now.addingTimeInterval(-86400), lastSeen: nil)]
        let host = "Niklass-MacBook-Pro.local"
        let pairing = PhonePairing(host: host, port: 52114, id: "82ae99e6", key: PhoneSecrets.newKey(PhonePairing.keyLength))
        Task { @MainActor in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                func shot(_ name: String, width: CGFloat, _ view: some View) async {
                    await render(view.padding(24).frame(width: width).background(Color(nsColor: .windowBackgroundColor)), appearance: appearance,
                                 to: output.appendingPathComponent("\(name)-\(suffix).png"))
                }
                model.showSample(enabled: false, status: .stopped, devices: [])
                await shot("settings-off", width: 520, PhoneSettingsSection(model: model))
                model.showSample(enabled: true, status: .listening(host: host, port: 47821), devices: devices)
                await shot("settings-on", width: 520, PhoneSettingsSection(model: model))
                model.showSample(enabled: true, status: .failed("Port 47821 is in use. Choose another port."), devices: [])
                await shot("settings-port-in-use", width: 520, PhoneSettingsSection(model: model))
                model.showSample(enabled: true, status: .listening(host: host, port: 47821), devices: devices, pairing: pairing, expires: now.addingTimeInterval(281))
                await shot("pairing-sheet", width: 340, PairingSheet(model: model) {}.padding(-24))
                model.showSample(enabled: true, status: .listening(host: host, port: 47821), devices: devices, pairedName: "Niklas\u{2019}s iPhone")
                await shot("pairing-done", width: 340, PairingSheet(model: model) {}.padding(-24))
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    @MainActor
    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) async {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }
}
#endif
