import SwiftUI

/// The Anthropic API key the meeting summariser uses before falling back to the Claude CLI.
struct ClaudeAPISettingsSection: View {
    @State private var stored: String?
    @State private var entry = ""
    @State private var problem: String?

    var keys = ClaudeAPIKeyStore.live

    var body: some View {
        SettingsSection("Claude API", footer: "Used to summarise meetings with Claude. Stored in your Keychain; "
                        + "requests are sent to Anthropic and billed to your account.") {
            SettingsRow("API key", detail: stored.map(ClaudeAPIKey.masked) ?? "No key saved") {
                if stored != nil {
                    Button("Remove") { remove() }
                }
            }
            HStack(spacing: 8) {
                SecureField("API key", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(save)
                Button("Save", action: save).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).padding(.horizontal, 14)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: ClaudeAPIKeyStore.didChange)) { _ in reload() }
    }

    private func reload() {
        stored = keys.key()
    }

    private func save() {
        do {
            try keys.save(entry)
            entry = ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        reload()
    }

    private func remove() {
        keys.remove()
        reload()
    }
}
