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

    let tokens = TokenStore.slack
    var makeClient: (String) -> SlackAPI = { SlackClient(token: $0) }
    private var names: [String: String] = [:]
    private var loop: Task<Void, Never>?
    private var refreshing = false

    var configured: Bool { hasToken }
    var ready: Bool { configured && shown }
    var interval: Int { GitHubModel.storedInterval(SlackLogic.intervalKey) }

    func start() {
        hasToken = tokens.token() != nil
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
        try tokens.save(token)
        clear()
        start()
    }

    func removeToken() {
        tokens.remove()
        clear()
        start()
    }

    /// Fetches once; returns the seconds to wait first when Slack is rate limiting.
    @discardableResult
    func refresh() async -> Int? {
        guard ready, !refreshing, let token = tokens.token() else { return nil }
        refreshing = true
        defer { refreshing = false }
        let client = makeClient(token)
        do {
            let me: SlackIdentity
            if let identity { me = identity } else { me = try await client.identity() }
            identity = me
            let now = Date()
            let mentions = try await client.mentions(of: me, now: now)
            let direct = try await client.directMessages(of: me, names: names, now: now)
            names.merge(direct.names) { $1 }
            let mentioned = Set((mentions + direct.messages).flatMap { SlackLogic.mentionedUsers(in: $0.text) }).filter { names[$0] == nil }
            for id in mentioned.prefix(20) { names[id] = try? await client.userName(id) }
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

    func test(token: String) async -> Result<SlackIdentity, SlackError> {
        do { return .success(try await makeClient(token).identity()) } catch { return .failure(SlackError.from(error)) }
    }

    func open(_ message: SlackMessage) {
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
        messages = []
        badge = 0
        error = nil
        fetched = nil
    }

    #if DEBUG
    /// Shows made-up state, for the previews.
    func showSample(messages: [SlackMessage], hasToken: Bool = true, unreadKnown: Bool = true, badge: Int = 0, error: SlackError? = nil) {
        loop?.cancel()
        self.hasToken = hasToken
        self.messages = messages
        self.unreadKnown = unreadKnown
        self.badge = badge
        self.error = error
        fetched = hasToken ? Date() : nil
    }
    #endif
}
