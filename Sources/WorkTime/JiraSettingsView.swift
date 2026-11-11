import SwiftUI

struct JiraSettingsSection: View {
    @ObservedObject var model: JiraModel
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var result: (text: String, failed: Bool)?
    @State private var testing = false

    var body: some View {
        SettingsSection("Jira", footer: "Reads the open Jira Cloud tickets assigned to you, for the list in the top notch bar. The API token "
                        + "is stored in your Keychain only. Nothing is uploaded anywhere but your Jira site.") {
            SettingsRow("Show my Jira tickets", detail: model.error?.message) {
                Toggle("Show my Jira tickets", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                    .labelsHidden().toggleStyle(.switch).disabled(!model.configured)
            }
            Divider().padding(.leading, 14)
            field("Site") { TextField("Site", text: $site, prompt: Text("yourco.atlassian.net")) }
            field("Email") { TextField("Email", text: $email, prompt: Text("you@yourco.com")) }
            field("API token") {
                SecureField("API token", text: $token, prompt: Text(model.hasToken ? "Saved in your Keychain" : "Paste the token"))
            }
            HStack(spacing: 8) {
                Link("Create an API token\u{2026}", destination: JiraLogic.tokenPage).font(.callout)
                Spacer()
                if model.hasToken { Button("Remove Token") { model.removeToken() } }
                Button("Test Connection", action: test).disabled(testing || entered == nil)
                Button("Save", action: save).disabled(entered == nil || (token.isEmpty && !model.hasToken))
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
                .disabled(!model.enabled)
            }
        }
        .onAppear {
            site = model.site ?? JiraLogic.suggestedSite(GitHubModel.shared.directory.sites) ?? ""
            email = model.email ?? ""
        }
    }

    private var entered: (site: String, email: String)? {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard let host = JiraLogic.site(site), address.contains("@") else { return nil }
        return (host, address)
    }

    private func field<Field: View>(_ title: String, @ViewBuilder _ content: () -> Field) -> some View {
        SettingsRow(title) { content().textFieldStyle(.roundedBorder).frame(width: 260) }
    }

    private func save() {
        guard let entered else { return }
        do {
            try model.save(site: entered.site, email: entered.email, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            site = entered.site
            token = ""
            result = nil
        } catch {
            result = (error.localizedDescription, true)
        }
    }

    private func test() {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entered, let client = model.client(site: entered.site, email: entered.email, token: typed.isEmpty ? nil : typed) else {
            return result = ("Paste an API token first.", true)
        }
        testing = true
        result = ("Connecting to \(entered.site)\u{2026}", false)
        Task {
            do {
                result = ("Connected as \(try await client.displayName()).", false)
            } catch {
                result = (JiraError.from(error).message, true)
            }
            testing = false
        }
    }
}
