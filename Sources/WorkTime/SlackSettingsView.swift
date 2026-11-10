import SwiftUI

struct SlackSettingsSection: View {
    @ObservedObject var model: SlackModel
    @State private var token = ""
    @State private var result: (text: String, failed: Bool)?
    @State private var testing = false

    var body: some View {
        SettingsSection("Slack", footer: "Shows your mentions from the last week and your unread DMs in the notch bar. Create a Slack app, "
                        + "add the scopes above as User Token Scopes under OAuth & Permissions, install it to your workspace and paste its "
                        + "User OAuth Token. The token is kept in the app's private secrets file, like the Jira token, and only sent to Slack.") {
            SettingsRow("Scopes") {
                Text(SlackLogic.scopes.joined(separator: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(width: 300, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            Divider().padding(.leading, 14)
            SettingsRow("User token", detail: model.error?.message) {
                SecureField("User token", text: $token, prompt: Text(model.hasToken ? "Saved" : "xoxp-\u{2026}"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            HStack(spacing: 8) {
                Link("Your Slack apps\u{2026}", destination: SlackLogic.appsPage).font(.callout)
                Spacer()
                if model.hasToken { Button("Remove Token") { model.removeToken() } }
                Button("Test Connection", action: test).disabled(testing || (typed.isEmpty && !model.hasToken))
                Button("Save", action: save).disabled(typed.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            if let result {
                Text(result.text).font(.caption).foregroundStyle(result.failed ? .red : .secondary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Refresh every") {
                Picker("Refresh every", selection: Binding(get: { model.interval }, set: model.setInterval)) {
                    ForEach(GitHubModel.intervals, id: \.self) { Text($0 < 60 ? "\($0) min" : "1 hour").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var typed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard SlackLogic.isUserToken(typed) else { return result = ("A user token starts with xoxp-.", true) }
        do {
            try model.save(token: typed)
            token = ""
            result = nil
        } catch {
            result = (error.localizedDescription, true)
        }
    }

    private func test() {
        guard let candidate = typed.isEmpty ? model.tokens.token() : typed else { return }
        testing = true
        result = ("Connecting to Slack\u{2026}", false)
        Task {
            switch await model.test(token: candidate) {
            case .success(let identity): result = ("Connected as \(identity.user) in \(identity.team).", false)
            case .failure(let error): result = (error.message, true)
            }
            testing = false
        }
    }
}
