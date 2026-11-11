import SwiftUI

struct SlackSettingsSection: View {
    @ObservedObject var model: SlackModel
    @State private var token = ""
    @State private var result: (text: String, failed: Bool)?
    @State private var testing = false
    @State private var useToken = false

    var body: some View {
        SettingsSection("Slack", footer: "Shows your mentions from the last week and your unread DMs in the top notch bar. To set it up, create a Slack "
                        + "app, add the scopes above as User Token Scopes under OAuth & Permissions, turn on PKCE there, add "
                        + "\(SlackLogic.redirect) as a Redirect URL, then copy the Client ID from Basic Information into the field above. "
                        + "No client secret is needed. The tokens are kept in the app's private secrets file and only sent to Slack.") {
            SettingsRow("Scopes") {
                Text(SlackLogic.scopes.joined(separator: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(width: 300, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            Divider().padding(.leading, 14)
            if model.hasToken { account } else { signIn }
            Divider().padding(.leading, 14)
            SettingsRow("Refresh every") {
                Picker("Refresh every", selection: Binding(get: { model.interval }, set: model.setInterval)) {
                    ForEach(GitHubModel.intervals, id: \.self) { Text($0 < 60 ? "\($0) min" : "1 hour").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .task { await model.loadAccount() }
    }

    private var account: some View {
        SettingsRow(model.account.map { "Signed in as \($0)" } ?? "Signed in", detail: accountDetail) {
            HStack(spacing: 8) {
                if model.error == .signInAgain {
                    Button("Sign In Again", action: model.signIn).disabled(model.clientID.isEmpty)
                }
                Button("Sign Out", action: model.signOut)
            }
        }
    }

    private var accountDetail: String? {
        model.error == .signInAgain ? "Slack ended the sign-in. Sign in again to keep fetching." : model.error?.message
    }

    @ViewBuilder private var signIn: some View {
        SettingsRow("Client ID", detail: model.signInError?.message) {
            TextField("Client ID", text: Binding(get: { model.clientID }, set: model.setClientID), prompt: Text("1234567890.1234567890"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        HStack(spacing: 8) {
            Link("Your Slack apps\u{2026}", destination: SlackLogic.appsPage).font(.callout)
            Spacer()
            Button("Sign in with Slack", action: model.signIn)
                .buttonStyle(.borderedProminent)
                .disabled(model.clientID.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        DisclosureGroup("Use a token instead", isExpanded: $useToken) {
            VStack(alignment: .trailing, spacing: 8) {
                SecureField("User token", text: $token, prompt: Text("xoxp-\u{2026}"))
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    if let result {
                        Text(result.text).font(.caption).foregroundStyle(result.failed ? .red : .secondary)
                    }
                    Spacer()
                    Button("Test Connection", action: test).disabled(testing || typed.isEmpty)
                    Button("Save", action: save).disabled(typed.isEmpty)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
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
        testing = true
        result = ("Connecting to Slack\u{2026}", false)
        Task {
            switch await model.test(token: typed) {
            case .success(let identity): result = ("Connected as \(identity.user) in \(identity.team).", false)
            case .failure(let error): result = (error.message, true)
            }
            testing = false
        }
    }
}
