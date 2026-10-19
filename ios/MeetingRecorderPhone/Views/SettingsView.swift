import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingForget = false
    @State private var editingAddress = false
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                if let mac = model.mac {
                    Section("Mac") {
                        LabeledContent("Name", value: mac.serverName)
                        LabeledContent("Status") { statusText }
                        if let status = model.status {
                            LabeledContent("Mac app", value: status.appVersion)
                            LabeledContent("Features") {
                                Text(features(status.features)).multilineTextAlignment(.trailing)
                            }
                        }
                        Button { Task { await check() } } label: {
                            HStack { Text("Check connection"); if checking { Spacer(); ProgressView() } }
                        }
                    }
                    Section {
                        LabeledContent("Address", value: "\(mac.address.host):\(mac.address.port)")
                        Button("Change address\u{2026}") { editingAddress = true }
                        if !model.discovered.isEmpty {
                            LabeledContent("Found on network", value: model.discovered.map(\.name).joined(separator: ", "))
                        }
                    } header: {
                        Text("Server address")
                    } footer: {
                        Text("The phone finds the Mac through Bonjour and falls back to this address. Set one by hand if the Mac's name does not resolve on this network, for example a Tailscale name.")
                    }
                    Section {
                        Button("Forget this Mac", role: .destructive) { confirmingForget = true }
                    } footer: {
                        Text("Deletes this phone's key and everything saved from the Mac. To also remove the phone from the Mac's list, revoke it in the Mac app's iPhone settings.")
                    }
                }
                Section("Privacy") {
                    Text("This app has no analytics and no accounts. It talks only to your paired Mac, over an encrypted connection with a key that stays in this phone's Keychain. Links you tap open in Safari.")
                        .font(.footnote)
                }
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("API", value: "v\(PhoneAPI.version)")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget this Mac", role: .destructive) { model.forget() }
            } message: {
                Text("You will need to pair again to see your meetings.")
            }
            .sheet(isPresented: $editingAddress) { AddressEditor() }
        }
        .task { await model.refreshStatus() }
    }

    @ViewBuilder private var statusText: some View {
        switch model.reachability {
        case .online(let date): Label("Connected \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .offline(let error, _): Label(error.problemTitle, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
        case .unknown: Label("Not checked", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private func features(_ features: PhoneFeatures) -> String {
        [("Activity", features.activityEnabled), ("GitHub", features.githubEnabled), ("Chat", features.chatAvailable)]
            .map { "\($0.0) \($0.1 ? "on" : "off")" }.joined(separator: " \u{00B7} ")
    }

    private func check() async {
        checking = true
        defer { checking = false }
        await model.refreshStatus()
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

private struct AddressEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("macbook.local:47821", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Host name or IP address, with the port if it is not \(PhoneAPI.defaultPort). Leave empty to use the address from pairing.")
                }
            }
            .navigationTitle("Server address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let target = PhoneFormat.hostAndPort(text)
                        model.setAddressOverride(target.map { PairedMac.HostPort(host: $0.host, port: $0.port) })
                        dismiss()
                        Task { await model.refreshStatus() }
                    }
                    .disabled(!text.isEmpty && PhoneFormat.hostAndPort(text) == nil)
                }
            }
            .onAppear { text = model.mac?.override.map { "\($0.host):\($0.port)" } ?? "" }
        }
        .presentationDetents([.medium])
    }
}
