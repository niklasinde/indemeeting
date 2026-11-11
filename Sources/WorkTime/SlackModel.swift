import AppKit

/// Slack messages that need the user: mentions from the last week and unread DMs, fetched while the notch bar shows Slack.
@MainActor
final class SlackModel: ObservableObject {
    static let shared = SlackModel()

    @Published private(set) var hasToken = false
    @Published private(set) var shown = false
    @Published private(set) var identity: SlackIdentity?
    @Published private(set) var messages: [SlackMessage] = []
    @Published private(set) var unreadKnown = true
    @Published private(set) var badge = 0
    @Published private(set) var error: SlackError?
    @Published private(set) var fetched: Date?
    /// `Anna Berg · Acme` once signed in.
    @Published private(set) var account: String?
    @Published private(set) var signInError: SlackError?
    @Published private(set) var clientID = UserDefaults.standard.string(forKey: SlackLogic.clientIDKey) ?? ""

    let tokens = TokenStore.slack
    var makeClient: (String) -> SlackAPI = { SlackClient(token: $0) }
    var transport: SlackTransport = SlackClient.urlSession
    private var names: [String: String] = [:]
    private var readState = SlackReadState()
    private var pending: SlackSignIn?
    private var renewal: Task<SlackAuth, Error>?
    private var loop: Task<Void, Never>?
    private var refreshing = false

    var configured: Bool { hasToken }
    var ready: Bool { configured && shown }
    var interval: Int { GitHubModel.storedInterval(SlackLogic.intervalKey) }

    func start() {
        hasToken = storedAuth() != nil
        loop?.cancel()
        loop = nil
        guard ready else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.refresh() ?? self.interval * 60
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            }
        }
    }

    /// The notch bar calls this when Slack is turned on or off there; a hidden panel fetches nothing.
    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        start()
    }

    func setInterval(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: SlackLogic.intervalKey)
        start()
    }

    func save(token: String) throws {
        try store(SlackAuth(accessToken: token))
        clear()
        start()
    }

    func removeToken() {
        tokens.remove()
        clear()
        start()
    }

    func setClientID(_ id: String) {
        clientID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(clientID, forKey: SlackLogic.clientIDKey)
    }

    /// Opens Slack's sign-in page in the browser; Slack sends the user back to `worktime://slack-auth`.
    func signIn() {
        guard !clientID.isEmpty else { return }
        let signIn = SlackLogic.newSignIn()
        pending = signIn
        signInError = nil
        NSWorkspace.shared.open(SlackLogic.authorizeURL(clientID: clientID, signIn: signIn))
    }

    func finishSignIn(_ url: URL) async {
        do {
            let code = try SlackLogic.callbackCode(url, expecting: pending)
            guard let signIn = pending else { return }
            pending = nil
            let request = SlackLogic.tokenRequest(clientID: clientID, code: code, verifier: signIn.verifier)
            try store(await SlackClient.authorize(request, now: Date(), transport: transport))
            clear()
            start()
            await loadAccount()
        } catch {
            signInError = SlackError.from(error)
        }
    }

    /// Forgets the token and asks Slack to revoke it.
    func signOut() {
        let token = storedAuth()?.accessToken
        pending = nil
        removeToken()
        guard let token else { return }
        let client = makeClient(token)
        Task { try? await client.revoke() }
    }

    func loadAccount() async {
        guard hasToken, account == nil else { return }
        do {
            account = try await authorized { client in
                let me = try await client.identity()
                self.identity = me
                let name = (try? await client.userName(me.userID)) ?? me.user
                return me.team.isEmpty ? name : "\(name) \u{00B7} \(me.team)"
            }
        } catch {
            self.error = SlackError.from(error)
        }
    }

    /// Fetches once; returns the seconds to wait first when Slack is rate limiting.
    @discardableResult
    func refresh() async -> Int? {
        guard ready, !refreshing, hasToken else { return nil }
        refreshing = true
        defer { refreshing = false }
        do {
            let (mentions, direct) = try await authorized { client in
                let me: SlackIdentity
                if let identity = self.identity { me = identity } else { me = try await client.identity() }
                self.identity = me
                let now = Date()
                let found = try await client.mentions(of: me, now: now)
                let (mentions, state) = await client.annotate(found, me: me.userID, marks: self.marks(now: now), cached: self.readState)
                self.readState = state
                let direct = try await client.directMessages(of: me, names: self.names, now: now)
                self.names.merge(direct.names) { $1 }
                let mentioned = Set((mentions + direct.messages).flatMap { SlackLogic.mentionedUsers(in: $0.text) }).filter { self.names[$0] == nil }
                for id in mentioned.prefix(20) { self.names[id] = try? await client.userName(id) }
                return (mentions, direct)
            }
            guard ready else { return nil }
            show(mentions: mentions, direct: direct)
            error = nil
            fetched = Date()
            return nil
        } catch {
            guard ready else { return nil }
            let failure = SlackError.from(error)
            self.error = failure
            if case .rateLimited(let seconds) = failure { return seconds }
            return nil
        }
    }

    /// Refreshes when the panel opens and the last fetch is a minute old, so a mention read in Slack meanwhile drops out.
    func refreshIfStale(after seconds: TimeInterval = 60) {
        guard ready, !refreshing, let fetched, Date().timeIntervalSince(fetched) > seconds else { return }
        if case .rateLimited = error { return }
        Task { await refresh() }
    }

    /// Hides a mention from Needs me, kept for `SlackLogic.markDays`.
    func mark(_ message: SlackMessage, _ reason: SlackHandled) {
        guard message.kind == .mention, message.handled == nil else { return }
        var marks = marks(now: Date())
        marks[message.id] = reason
        UserDefaults.standard.set(SlackLogic.stored(marks), forKey: SlackLogic.marksKey)
        if let index = messages.firstIndex(where: { $0.id == message.id && $0.kind == .mention }) { messages[index].handled = reason }
    }

    private func marks(now: Date) -> [String: SlackHandled] {
        SlackLogic.marks(UserDefaults.standard.dictionary(forKey: SlackLogic.marksKey), now: now)
    }

    func test(token: String) async -> Result<SlackIdentity, SlackError> {
        do { return .success(try await makeClient(token).identity()) } catch { return .failure(SlackError.from(error)) }
    }

    private func storedAuth() -> SlackAuth? { tokens.token().flatMap(SlackAuth.init(stored:)) }

    private func store(_ auth: SlackAuth) throws { try tokens.save(auth.stored) }

    /// Runs `work` with a token that works: refreshed first when it is about to run out, and once more when Slack turns it down.
    private func authorized<T>(_ work: (SlackAPI) async throws -> T) async throws -> T {
        try await SlackClient.authorized(stored: storedAuth, renew: renew, save: store, client: makeClient, work)
    }

    /// One renewal at a time: a second caller waits for the one already running.
    private func renew(_ auth: SlackAuth) async throws -> SlackAuth {
        let clientID = clientID, transport = transport
        let task = renewal ?? Task { try await SlackClient.renew(auth, clientID: clientID, transport: transport) }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    /// Opens the message in Slack; a mention counts as viewed from then on.
    func open(_ message: SlackMessage) {
        mark(message, .viewed)
        if let app = SlackLogic.deepLink(message), NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else if let web = SlackLogic.webLink(message, workspace: identity?.url) {
            NSWorkspace.shared.open(web)
        }
    }

    private func show(mentions: [SlackMessage], direct: SlackDirectMessages) {
        let cleaned = { (message: SlackMessage) -> SlackMessage in
            var copy = message
            copy.text = SlackLogic.clean(message.text, names: self.names)
            copy.author = message.author.map { self.names[$0] ?? $0 }
            return copy
        }
        messages = SlackLogic.merged(mentions: mentions.map(cleaned), direct: direct.messages.map(cleaned))
        unreadKnown = direct.unreadKnown
        badge = SlackLogic.badge(direct)
    }

    private func clear() {
        identity = nil
        readState = SlackReadState()
        messages = []
        badge = 0
        error = nil
        fetched = nil
        account = nil
    }

    #if DEBUG
    /// Shows made-up state, for the previews.
    func showSample(messages: [SlackMessage], hasToken: Bool = true, unreadKnown: Bool = true, badge: Int = 0, error: SlackError? = nil,
                    account: String? = nil, clientID: String = "") {
        loop?.cancel()
        self.account = account
        self.clientID = clientID
        self.hasToken = hasToken
        self.messages = messages
        self.unreadKnown = unreadKnown
        self.badge = badge
        self.error = error
        fetched = hasToken ? Date() : nil
    }
    #endif
}
