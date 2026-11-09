import Foundation

/// The open Jira tickets assigned to the user, fetched periodically while Jira is set up and turned on.
@MainActor
final class JiraModel: ObservableObject {
    static let shared = JiraModel()

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: JiraLogic.enabledKey)
    @Published private(set) var site = UserDefaults.standard.string(forKey: JiraLogic.siteKey)
    @Published private(set) var email = UserDefaults.standard.string(forKey: JiraLogic.emailKey)
    @Published private(set) var hasToken = false
    @Published private(set) var tickets: [JiraTicket] = []
    @Published private(set) var total: Int?
    @Published private(set) var error: JiraError?
    @Published private(set) var fetched: Date?

    let tokens = JiraTokenStore.live
    private var loop: Task<Void, Never>?
    private var refreshing = false

    var configured: Bool { site != nil && email != nil && hasToken }
    var ready: Bool { enabled && configured }
    var interval: Int { GitHubModel.storedInterval(JiraLogic.intervalKey) }

    func start() {
        hasToken = tokens.token() != nil
        loop?.cancel()
        loop = nil
        guard ready else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(self.interval) * 60 * 1_000_000_000)
            }
        }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: JiraLogic.enabledKey)
        enabled = on
        if !on { clear() }
        start()
    }

    func setInterval(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: JiraLogic.intervalKey)
        start()
    }

    /// Saves the site and email, and the token when one is typed; an empty token keeps the saved one.
    func save(site: String, email: String, token: String) throws {
        UserDefaults.standard.set(site, forKey: JiraLogic.siteKey)
        UserDefaults.standard.set(email, forKey: JiraLogic.emailKey)
        if !token.isEmpty { try tokens.save(token) }
        self.site = site
        self.email = email
        clear()
        setEnabled(true)
    }

    func removeToken() {
        tokens.remove()
        clear()
        start()
    }

    func refresh() async {
        guard ready, !refreshing, let client = client() else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let search = try await client.assigned()
            guard ready else { return }
            tickets = search.tickets
            total = search.total
            error = nil
            fetched = Date()
        } catch {
            if ready { self.error = JiraError.from(error) }
        }
    }

    func client(site: String? = nil, email: String? = nil, token: String? = nil) -> JiraClient? {
        guard let site = site ?? self.site, let email = email ?? self.email, let token = token ?? tokens.token() else { return nil }
        return JiraClient(site: site, email: email, token: token)
    }

    func browseURL(_ ticket: JiraTicket) -> URL? {
        site.flatMap { JiraLogic.browseURL(site: $0, key: ticket.key) }
    }

    private func clear() {
        tickets = []
        total = nil
        error = nil
        fetched = nil
    }
}
