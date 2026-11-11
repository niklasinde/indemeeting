import Foundation

/// Sends one request and returns the body, the HTTP status and the Retry-After header. Tests replace it with a fake.
typealias SlackTransport = @Sendable (URLRequest) async throws -> (Data, Int, String?)

protocol SlackAPI: Sendable {
    func identity() async throws -> SlackIdentity
    func mentions(of identity: SlackIdentity, now: Date) async throws -> [SlackMessage]
    func directMessages(of identity: SlackIdentity, names: [String: String], now: Date) async throws -> SlackDirectMessages
    func userName(_ id: String) async throws -> String
    func revoke() async throws
}

/// The Slack Web API with a user token (`xoxp-`, or `xoxe.xoxp-` from a sign-in).
struct SlackClient: SlackAPI {
    let token: String
    var transport: SlackTransport = SlackClient.urlSession

    static let urlSession: SlackTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Retry-After"))
    }

    func identity() async throws -> SlackIdentity {
        try SlackLogic.parseIdentity(await send("auth.test"))
    }

    func mentions(of identity: SlackIdentity, now: Date) async throws -> [SlackMessage] {
        let data = try await send("search.messages", SlackLogic.searchParameters(userID: identity.userID, now: now))
        return try SlackLogic.parseMentions(data, teamID: identity.teamID, me: identity.userID, now: now)
    }

    /// The most recent DMs and group DMs, each with its read state and latest message. Names come from `names`, then `users.info`.
    func directMessages(of identity: SlackIdentity, names: [String: String], now: Date) async throws -> SlackDirectMessages {
        let listed = try SlackLogic.parseConversations(await send("conversations.list", ["types": "im,mpim", "exclude_archived": "true", "limit": "200"]))
        var conversations: [SlackConversation] = []
        for var conversation in SlackLogic.recent(listed.conversations) {
            let info = try SlackLogic.parseConversationInfo(await send("conversations.info", ["channel": conversation.id]))
            conversation.lastRead = info.lastRead
            conversation.unreadDisplay = info.unreadDisplay
            conversation.latest = info.latest
            if conversation.latest == nil && conversation.unreadDisplay != 0 {
                conversation.latest = try SlackLogic.parseLatest(await send("conversations.history", ["channel": conversation.id, "limit": "1"]))
            }
            conversations.append(conversation)
        }
        var names = names
        let people = Set(conversations.flatMap { [$0.user, $0.latest?.user].compactMap { $0 } }).filter { names[$0] == nil && !$0.hasPrefix("B") }
        for id in people { names[id] = try? await userName(id) }
        var direct = SlackLogic.directMessages(conversations, me: identity.userID, teamID: identity.teamID, names: names, now: now)
        direct.names = names
        return direct
    }

    func userName(_ id: String) async throws -> String {
        try SlackLogic.parseUserName(await send("users.info", ["user": id]))
    }

    func revoke() async throws {
        _ = try await send("auth.revoke")
    }

    /// Exchanges a sign-in code, or a refresh token, for a user token.
    static func authorize(_ request: URLRequest, now: Date, previous: SlackAuth? = nil,
                          transport: SlackTransport = urlSession) async throws -> SlackAuth {
        try SlackLogic.parseAuth(await perform(request, transport: transport), now: now, previous: previous)
    }

    private func send(_ method: String, _ parameters: [String: String] = [:]) async throws -> Data {
        try await Self.perform(SlackLogic.request(method: method, token: token, parameters: parameters), transport: transport)
    }

    private static func perform(_ request: URLRequest, transport: SlackTransport) async throws -> Data {
        let (data, status, retryAfter): (Data, Int, String?)
        do { (data, status, retryAfter) = try await transport(request) } catch { throw SlackError.from(error) }
        if status == 429 { throw SlackError.rateLimited(retryAfter: SlackLogic.retryAfter(retryAfter)) }
        guard (200..<300).contains(status) else { throw SlackError.failed("HTTP \(status)") }
        do {
            return try SlackLogic.checked(data)
        } catch SlackError.rateLimited {
            throw SlackError.rateLimited(retryAfter: SlackLogic.retryAfter(retryAfter))
        }
    }
}
