import Foundation

/// Sends one request and returns the body, the HTTP status and the Retry-After header. Tests replace it with a fake.
typealias SlackTransport = @Sendable (URLRequest) async throws -> (Data, Int, String?)

protocol SlackAPI: Sendable {
    func identity() async throws -> SlackIdentity
    func mentions(of identity: SlackIdentity, now: Date) async throws -> [SlackMessage]
    func directMessages(of identity: SlackIdentity, names: [String: String], now: Date) async throws -> SlackDirectMessages
    func userName(_ id: String) async throws -> String
    func readState(_ plan: SlackReadPlan) async -> SlackReadState
    func revoke() async throws
}

extension SlackAPI {
    /// The mentions with why each no longer needs the user, from fresh histories filled in by `cached` where a fetch failed.
    func annotate(_ mentions: [SlackMessage], me: String, marks: [String: SlackHandled],
                  cached: SlackReadState = SlackReadState()) async -> (mentions: [SlackMessage], state: SlackReadState) {
        let state = await readState(SlackLogic.readPlan(mentions, marks: marks)).merged(over: cached)
        return (SlackLogic.annotated(mentions, me: me, state: state, marks: marks), state)
    }
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

    /// One history per channel and one reply list per thread in `plan`. A failed call leaves its entry out; rate limiting stops the rest.
    func readState(_ plan: SlackReadPlan) async -> SlackReadState {
        var state = SlackReadState()
        func fetch<T>(_ method: String, _ parameters: [String: String], _ parse: (Data) throws -> T) async throws -> T? {
            do { return try parse(await send(method, parameters)) } catch let error as SlackError {
                if case .rateLimited = error { throw error }
                return nil
            } catch { return nil }
        }
        do {
            for channel in plan.channels {
                guard var history = try await fetch("conversations.history", SlackLogic.historyParameters(channel), SlackLogic.parseReadHistory) else { continue }
                history.lastRead = try await fetch("conversations.info", ["channel": channel.id], SlackLogic.parseConversationInfo)?.lastRead
                state.channels[channel.id] = history
            }
            for thread in plan.threads {
                state.threads[SlackLogic.threadKey(thread.channel, thread.ts)] =
                    try await fetch("conversations.replies", SlackLogic.repliesParameters(thread), SlackLogic.parseReadHistory)
            }
        } catch {}
        return state
    }

    func thread(_ link: SlackThreadLink) async throws -> (messages: [SlackRawMessage], more: Bool) {
        try SlackLogic.parseReplies(await send("conversations.replies", SlackLogic.repliesParameters(link)))
    }

    func search(_ query: String, count: Int, teamID: String) async throws -> [SlackMessage] {
        try SlackLogic.parseSearch(await send("search.messages", SlackLogic.searchParameters(query: query, count: count)), teamID: teamID)
    }

    /// Display names for the user ids in `ids` that `names` lacks, at most `limit` looked up; the ones that fail stay ids.
    func names(_ ids: [String], known names: [String: String] = [:], limit: Int = 30) async -> [String: String] {
        var names = names
        for id in Set(ids).filter({ names[$0] == nil && $0.wholeMatch(of: #/[UW][A-Z0-9]+/#) != nil }).sorted().prefix(limit) {
            names[id] = try? await userName(id)
        }
        return names
    }

    /// Runs `work` with a token that works: renewed first when it is about to run out, and once more when Slack turns it down.
    static func authorized<Client, T>(stored: () -> SlackAuth?, renew: (SlackAuth) async throws -> SlackAuth, save: (SlackAuth) throws -> Void,
                                      client: (String) -> Client, now: Date = Date(), isolation: isolated (any Actor)? = #isolation,
                                      _ work: (Client) async throws -> T) async throws -> T {
        func token(renewing: Bool) async throws -> String {
            guard let auth = stored() else { throw SlackError.notConfigured }
            guard renewing || SlackLogic.needsRefresh(auth, now: now) else { return auth.accessToken }
            guard auth.refreshToken != nil else { throw SlackError.unauthorized }
            let renewed: SlackAuth
            do { renewed = try await renew(auth) } catch SlackError.offline { throw SlackError.offline } catch { throw SlackError.signInAgain }
            try save(renewed)
            return renewed.accessToken
        }
        do {
            return try await work(client(try await token(renewing: false)))
        } catch SlackError.unauthorized where stored()?.refreshToken != nil {
            return try await work(client(try await token(renewing: true)))
        }
    }

    /// Exchanges the stored refresh token for a new user token.
    static func renew(_ auth: SlackAuth, clientID: String, transport: SlackTransport = urlSession) async throws -> SlackAuth {
        guard let refreshToken = auth.refreshToken else { throw SlackError.unauthorized }
        return try await authorize(SlackLogic.refreshRequest(clientID: clientID, refreshToken: refreshToken), now: Date(), previous: auth, transport: transport)
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
