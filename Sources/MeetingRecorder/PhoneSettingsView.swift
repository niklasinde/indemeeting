import Combine
import SwiftUI

struct PhoneSettingsSection: View {
    @ObservedObject var model: PhoneAccess
    @State private var portText = ""
    @State private var showPairing = false
    @State private var revoking: PairedDevice?
    private let poll = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("iPhone", footer: "Your iPhone reads meetings, activity and GitHub from this Mac over your local network. "
                            + "Nothing goes through a server.") {
                SettingsRow("Allow iPhone access", detail: model.statusText) {
                    Toggle("Allow iPhone access", isOn: Binding(get: { model.enabled }, set: model.setEnabled)).labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                SettingsRow("Port", detail: "Between \(PhoneAccess.portRange.lowerBound) and \(PhoneAccess.portRange.upperBound).") {
                    TextField("Port", text: $portText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit(commitPort)
                }
                Divider().padding(.leading, 14)
                SettingsRow("Pair a device") {
                    Button("Pair a device\u{2026}") {
                        model.beginPairing()
                        showPairing = true
                    }
                    .disabled(!model.isListening)
                }
            }
            SettingsSection("Paired devices", footer: model.devices.isEmpty ? nil : "A revoked device is disconnected at once and has to be paired again.") {
                if model.devices.isEmpty {
                    SettingsRow("No devices paired", detail: "Turn on iPhone access, then pair your iPhone.") {}
                }
                ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Divider().padding(.leading, 14) }
                    SettingsRow(device.name, detail: Self.detail(device)) {
                        Button("Revoke\u{2026}") { revoking = device }
                    }
                }
            }
        }
        .onAppear {
            portText = String(model.port)
            model.sync()
        }
        .onReceive(poll) { _ in model.sync() }
        .sheet(isPresented: $showPairing, onDismiss: model.endPairing) {
            PairingSheet(model: model) { showPairing = false }
        }
        .alert("Revoke \(revoking?.name ?? "this device")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke", role: .destructive) {
                if let revoking { model.revoke(revoking) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It can no longer read from this Mac until it is paired again.")
        }
    }

    private func commitPort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), PhoneAccess.portRange.contains(port) else {
            portText = String(model.port)
            return
        }
        model.setPort(port)
    }

    static func detail(_ device: PairedDevice) -> String {
        "Paired \(device.created.formatted(date: .abbreviated, time: .omitted))" + " \u{00B7} "
            + (device.lastSeen.map { "last seen \($0.formatted(.relative(presentation: .named)))" } ?? "never connected")
    }
}

struct PairingSheet: View {
    @ObservedObject var model: PhoneAccess
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a device").font(.title3.weight(.semibold))
            if let name = model.pairedName {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text("Paired with \(name)")
                }
                .frame(height: 260)
            } else if let pairing = model.pairing {
                VStack(spacing: 14) {
                    if let image = PhoneQR.image(for: pairing.url.absoluteString, side: 220) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 220, height: 220)
                            .padding(10)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("Scan this with the Meeting Recorder app on your iPhone.").font(.callout).foregroundStyle(.secondary)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            detail("Host", pairing.host)
                            detail("Port", String(pairing.port))
                            detail("Code", pairing.manualCode)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Or type it in").font(.caption).foregroundStyle(.secondary)
                    }
                    if let expires = model.pairingExpires {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, Int(expires.timeIntervalSince(context.date)))
                            Text(left == 0 ? "Expired. Close this and start again." : "Valid for \(left / 60):\(String(format: "%02d", left % 60)), one device")
                                .font(.caption).foregroundStyle(left == 0 ? Color.red : Color.secondary).monospacedDigit()
                        }
                    }
                }
            } else if let error = model.pairingError {
                Text(error).foregroundStyle(.red).frame(height: 260)
            } else {
                ProgressView().frame(height: 260)
            }
            Button(model.pairedName == nil ? "Cancel" : "Done", action: close).keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 340)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
        }
    }
}
