import CryptoKit
import Foundation

struct SlackIdentity: Equatable, Sendable {
    let userID: String
    let user: String
    let teamID: String
    let team: String
    /// The workspace address, e.g. `https://acme.slack.com/`.
    let url: String
}

/// A pasted message link: `https://acme.slack.com/archives/C123/p1700000000123456`, with `?thread_ts=` for a reply.
struct SlackThreadLink: Equatable, Sendable {
    let host: String
    let channel: String
    let ts: String
    let threadTS: String?

    /// The message that starts the thread.
    var root: String { threadTS ?? ts }
    var url: String { "https://\(host)/archives/\(channel)/p\(ts.replacingOccurrences(of: ".", with: ""))" + (threadTS.map { "?thread_ts=\($0)" } ?? "") }
}

struct SlackMessage: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case mention, direct }

    let kind: Kind
    let teamID: String
    let channelID: String
    /// `#general` for a channel, the person for a DM, the people for a group DM.
    var place: String
    var author: String?
    var text: String
    let ts: String
    var permalink: String?
    /// Unread messages in a DM; nil when Slack does not say.
    var unread: Int?
    /// The thread a mention was posted in.
    var threadTS: String? = nil
    /// Why a mention no longer needs the user; nil while it does.
    var handled: SlackHandled? = nil

    var id: String { "\(channelID)-\(ts)" }
    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }
}

/// A DM or group DM as `conversations.list` and `conversations.info` return it.
struct SlackConversation: Equatable, Sendable {
    let id: String
    var user: String?
    var name: String?
    var isGroup: Bool
    var updated: Double?
    var lastRead: String?
    var unreadDisplay: Int?
    var latest: SlackRawMessage?
}

enum SlackHandled: String, Sendable {
    case dismissed, viewed, replied, reacted, postedAfter, read

    var label: String {
        switch self {
        case .dismissed: "dismissed"
        case .viewed: "viewed"
        case .replied: "you replied"
        case .reacted: "you reacted"
        case .postedAfter: "you posted after"
        case .read: "read"
        }
    }
}

/// A channel's or thread's messages from `conversations.history` or `conversations.replies`, with the user's read position.
struct SlackReadHistory: Equatable, Sendable {
    struct Message: Equatable, Sendable {
        let ts: String
        var user: String?
        var replyUsers: [String] = []
        var reactors: [String] = []
    }

    var lastRead: String?
    var messages: [Message] = []
}

/// What `SlackLogic.handled` decides from: channel histories by channel id, threads by `SlackLogic.threadKey`.
struct SlackReadState: Equatable, Sendable {
    var channels: [String: SlackReadHistory] = [:]
    var threads: [String: SlackReadHistory] = [:]

    /// Keeps this state's entries and fills the rest from `older`, so a failed fetch reuses the last good answer.
    func merged(over older: SlackReadState) -> SlackReadState {
        SlackReadState(channels: channels.merging(older.channels) { new, _ in new }, threads: threads.merging(older.threads) { new, _ in new })
    }
}

/// The histories to fetch for a refresh: each channel once from its oldest open mention, and each thread a mention is in.
struct SlackReadPlan: Equatable, Sendable {
    struct Channel: Equatable, Sendable {
        let id: String
        let oldest: String
    }
    struct Thread: Equatable, Sendable {
        let channel: String
        let ts: String
    }

    var channels: [Channel] = []
    var threads: [Thread] = []
}

struct SlackRawMessage: Equatable, Sendable {
    let ts: String
    let text: String
    let user: String?
}

struct SlackDirectMessages: Equatable, Sendable {
    var messages: [SlackMessage]
    /// False when Slack gave no read state, so the list is the recent DMs rather than the unread ones.
    var unreadKnown: Bool
    /// The people looked up on the way, to reuse for the next refresh.
    var names: [String: String] = [:]
}

/// What is kept in the secrets file: the access token, and for a sign-in its refresh token and expiry. A pasted token is stored as is.
struct SlackAuth: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expires: Date?

    init(accessToken: String, refreshToken: String? = nil, expires: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expires = expires
    }

    init?(stored: String) {
        if stored.hasPrefix("{") {
            guard let auth = try? JSONDecoder().decode(SlackAuth.self, from: Data(stored.utf8)) else { return nil }
            self = auth
        } else {
            guard !stored.isEmpty else { return nil }
            self.init(accessToken: stored)
        }
    }

    var stored: String {
        guard refreshToken != nil || expires != nil, let data = try? JSONEncoder().encode(self) else { return accessToken }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The verifier and state of a sign-in waiting for its callback.
struct SlackSignIn: Equatable, Sendable {
    let state: String
    let verifier: String
}

enum SlackError: Error, Equatable {
    case notConfigured
    case unauthorized
    case signInAgain
    case signIn(String)
    case missingScope(String)
    case rateLimited(retryAfter: Int)
    case offline
    case failed(String)

    var message: String {
        switch self {
        case .notConfigured: return "Sign in with Slack in Settings."
        case .unauthorized: return "Slack did not accept the token. Check it in Settings."
        case .signInAgain: return "Slack signed you out. Sign in again in Settings."
        case .signIn(let detail): return "Slack sign-in failed: \(SecretRedaction.redact(detail, key: nil))."
        case .missingScope(let scope): return "The Slack token lacks the \(scope) scope. Add it to your Slack app and reinstall it."
        case .rateLimited: return "Slack is rate limiting requests. Trying again shortly."
        case .offline: return "Slack cannot be reached. Check your connection."
        case .failed(let detail): return "Slack returned an error: \(SecretRedaction.redact(detail, key: nil))"
        }
    }

    static func from(code: String, needed: String?) -> SlackError {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive": return .unauthorized
        case "missing_scope": return .missingScope(needed ?? "needed")
        case "ratelimited": return .rateLimited(retryAfter: 60)
        default: return .failed(code)
        }
    }

    static func from(_ error: Error) -> SlackError {
        if let error = error as? SlackError { return error }
        let offline: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut,
                                        .networkConnectionLost, .dnsLookupFailed]
        if let error = error as? URLError, offline.contains(error.code) { return .offline }
        return .failed(error.localizedDescription)
    }
}

enum SlackLogic {
    static let enabledKey = "slackEnabled"
    static let intervalKey = "slackRefreshMinutes"
    static let base = "https://slack.com/api/"
    static let appsPage = URL(string: "https://api.slack.com/apps")!
    static let scopes = ["search:read", "im:history", "mpim:history", "channels:history", "groups:history", "users:read",
                         "channels:read", "groups:read", "im:read", "mpim:read"]
    static let mentionDays = 7
    static let marksKey = "slackMentionMarks"
    static let markDays = 8
    static let historyLimit = 50
    static let readChannelLimit = 12
    static let readThreadLimit = 8
    static let mentionLimit = 20
    static let conversationLimit = 12
    static let recentWindow: TimeInterval = 24 * 3600

    static let clientIDKey = "slackClientID"
    static let authorizePage = "https://slack.com/oauth/v2/authorize"
    static let redirect = "\(AppURL.scheme)://slack-auth"
    static let refreshMargin: TimeInterval = 300

    static func isUserToken(_ token: String) -> Bool { token.hasPrefix("xoxp-") }

    // MARK: Sign in

    static func randomBase64URL(bytes count: Int = 32) -> String {
        base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The S256 code challenge: the verifier's SHA-256, base64url without padding.
    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func newSignIn() -> SlackSignIn {
        SlackSignIn(state: randomBase64URL(bytes: 16), verifier: randomBase64URL())
    }

    static func authorizeURL(clientID: String, signIn: SlackSignIn) -> URL {
        var components = URLComponents(string: authorizePage)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "user_scope", value: scopes.joined(separator: ",")),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: signIn.state),
            URLQueryItem(name: "code_challenge", value: challenge(signIn.verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    static func isCallback(_ url: URL) -> Bool {
        AppURL.accepts(scheme: url.scheme) && url.host?.lowercased() == "slack-auth"
    }

    /// The code in a `worktime://slack-auth` callback, once its state matches the sign-in that is waiting.
    static func callbackCode(_ url: URL, expecting signIn: SlackSignIn?) throws -> String {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        if let error = value("error") { throw SlackError.signIn(error == "access_denied" ? "you cancelled it" : error) }
        guard let signIn, value("state") == signIn.state else { throw SlackError.signIn("the reply did not match this sign-in. Try again") }
        guard let code = value("code"), !code.isEmpty else { throw SlackError.signIn("Slack sent no code") }
        return code
    }

    static func tokenRequest(clientID: String, code: String, verifier: String) -> URLRequest {
        form("oauth.v2.access", ["client_id": clientID, "code": code, "code_verifier": verifier, "redirect_uri": redirect,
                                 "grant_type": "authorization_code"])
    }

    static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        form("oauth.v2.access", ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    private static func form(_ method: String, _ fields: [String: String]) -> URLRequest {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var request = URLRequest(url: URL(string: base + method)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&").utf8)
        request.timeoutInterval = 30
        return request
    }

    /// The user token from `oauth.v2.access`, for a sign-in or a refresh; a refresh that sends no new refresh token keeps the old one.
    static func parseAuth(_ data: Data, now: Date, previous: SlackAuth? = nil) throws -> SlackAuth {
        let response = try JSONDecoder().decode(TokenResponse.self, from: checked(data))
        if let user = response.authed_user, let token = user.access_token {
            return SlackAuth(accessToken: token, refreshToken: user.refresh_token ?? previous?.refreshToken,
                             expires: user.expires_in.map { now.addingTimeInterval(Double($0)) })
        }
        guard let token = response.access_token, response.token_type == "user" || token.contains("xoxp-") else {
            throw SlackError.signIn("Slack sent no user token")
        }
        return SlackAuth(accessToken: token, refreshToken: response.refresh_token ?? previous?.refreshToken,
                         expires: response.expires_in.map { now.addingTimeInterval(Double($0)) })
    }

    /// True when a signed-in token runs out within the margin; a pasted token never expires.
    static func needsRefresh(_ auth: SlackAuth, now: Date) -> Bool {
        guard auth.refreshToken != nil, let expires = auth.expires else { return false }
        return expires.timeIntervalSince(now) < refreshMargin
    }

    static func request(method: String, token: String, parameters: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(string: base + method)!
        if !parameters.isEmpty {
            components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    static func mentionQuery(userID: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let since = now.addingTimeInterval(-Double(mentionDays + 1) * 86400)
        return "<@\(userID)> after:\(formatter.string(from: since))"
    }

    static func searchParameters(userID: String, now: Date) -> [String: String] {
        ["query": mentionQuery(userID: userID, now: now), "sort": "timestamp", "sort_dir": "desc", "count": "\(mentionLimit)"]
    }

    /// Checks `ok` and turns Slack's error codes into a `SlackError`.
    static func checked(_ data: Data) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw SlackError.failed("unexpected response") }
        guard envelope.ok else { throw SlackError.from(code: envelope.error ?? "unknown", needed: envelope.needed) }
        return data
    }

    static func retryAfter(_ header: String?) -> Int {
        header.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { max($0, 1) } ?? 60
    }

    // MARK: Parsing

    static func parseIdentity(_ data: Data) throws -> SlackIdentity {
        let auth = try JSONDecoder().decode(AuthTest.self, from: checked(data))
        return SlackIdentity(userID: auth.user_id, user: auth.user ?? auth.user_id, teamID: auth.team_id, team: auth.team ?? "", url: auth.url ?? "")
    }

    static func parseMentions(_ data: Data, teamID: String, me: String, now: Date) throws -> [SlackMessage] {
        let cutoff = now.addingTimeInterval(-Double(mentionDays) * 86400).timeIntervalSince1970
        return try parseSearch(data, teamID: teamID) { match in (Double(match.ts) ?? 0) >= cutoff && match.user != me }
    }

    static func parseSearch(_ data: Data, teamID: String) throws -> [SlackMessage] { try parseSearch(data, teamID: teamID) { _ in true } }

    private static func parseSearch(_ data: Data, teamID: String, keep: (Search.Match) -> Bool) throws -> [SlackMessage] {
        let response = try JSONDecoder().decode(Search.self, from: checked(data))
        return (response.messages?.matches ?? []).compactMap { match in
            guard let channel = match.channel, keep(match) else { return nil }
            let place: String
            if channel.is_im == true {
                place = match.username ?? "Direct message"
            } else if channel.is_mpim == true {
                place = groupName(channel.name ?? "")
            } else {
                place = "#" + (channel.name ?? channel.id)
            }
            return SlackMessage(kind: .mention, teamID: match.team ?? teamID, channelID: channel.id, place: place,
                                author: match.username ?? match.user, text: match.text ?? "", ts: match.ts, permalink: match.permalink, unread: nil,
                                threadTS: match.permalink.flatMap(threadLink)?.threadTS)
        }
    }

    static func parseConversations(_ data: Data) throws -> (conversations: [SlackConversation], cursor: String?) {
        let response = try JSONDecoder().decode(ConversationList.self, from: checked(data))
        let cursor = response.response_metadata?.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
        return (response.channels.map(conversation), cursor)
    }

    static func parseConversationInfo(_ data: Data) throws -> SlackConversation {
        conversation(try JSONDecoder().decode(ConversationInfo.self, from: checked(data)).channel)
    }

    static func parseLatest(_ data: Data) throws -> SlackRawMessage? {
        try JSONDecoder().decode(History.self, from: checked(data)).messages.first.map(raw)
    }

    static let threadLimit = 200
    static let searchCountLimit = 50

    /// A message link copied from Slack, or nil for anything else.
    static func threadLink(_ input: String) -> SlackThreadLink? {
        guard let url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              let host = url.host?.lowercased(), host.hasSuffix(".slack.com") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "archives", parts[1].wholeMatch(of: #/[A-Z0-9]{5,}/#) != nil,
              let digits = parts[2].wholeMatch(of: #/p([0-9]{7,})/#)?.1 else { return nil }
        let ts = String(digits.dropLast(6)) + "." + String(digits.suffix(6))
        let thread = url.queryItems?.first { $0.name == "thread_ts" }?.value
        guard thread.map({ $0.wholeMatch(of: #/[0-9]+\.[0-9]+/#) != nil }) ?? true else { return nil }
        return SlackThreadLink(host: host, channel: parts[1], ts: ts, threadTS: thread == ts ? nil : thread)
    }

    static func repliesParameters(_ link: SlackThreadLink) -> [String: String] {
        ["channel": link.channel, "ts": link.root, "limit": "\(threadLimit)"]
    }

    static func searchParameters(query: String, count: Int) -> [String: String] {
        ["query": query, "sort": "timestamp", "sort_dir": "desc", "count": "\(min(max(count, 1), searchCountLimit))"]
    }

    /// The thread's messages oldest first, bots named by their username, and whether Slack has more than were returned.
    static func parseReplies(_ data: Data) throws -> (messages: [SlackRawMessage], more: Bool) {
        let response = try JSONDecoder().decode(History.self, from: checked(data))
        return (response.messages.map { SlackRawMessage(ts: $0.ts, text: $0.text ?? "", user: $0.user ?? $0.username) }, response.has_more == true)
    }

    static func threadMarkdown(_ messages: [SlackRawMessage], more: Bool, link: SlackThreadLink, names: [String: String]) -> String {
        guard !messages.isEmpty else { return "The thread has no messages.\n" }
        let header = "Slack thread \(link.url) \u{00B7} \(messages.count) message\(messages.count == 1 ? "" : "s")" + (more ? ", more not shown" : "")
        return header + "\n\n" + messages.map { message in
            "- \(timeText(message.ts)) \(message.user.map { names[$0] ?? $0 } ?? "someone"): " + clean(message.text, names: names)
        }.joined(separator: "\n") + "\n"
    }

    static func searchMarkdown(_ messages: [SlackMessage], query: String, names: [String: String]) -> String {
        guard !messages.isEmpty else { return "No Slack messages match \(query).\n" }
        return messages.map { message in
            let author = message.author.map { names[$0] ?? $0 }.map { " \u{00B7} \($0)" } ?? ""
            return "- \(timeText(message.ts)) \u{00B7} \(message.place)\(author): " + clean(message.text, names: names)
                + (message.permalink.map { "\n  \($0)" } ?? "")
        }.joined(separator: "\n") + "\n"
    }

    /// `2026-11-10 14:03` in the Mac's time zone.
    static func timeText(_ ts: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ts) ?? 0))
    }

    static func parseUserName(_ data: Data) throws -> String {
        let user = try JSONDecoder().decode(UserInfo.self, from: checked(data)).user
        return [user.profile?.display_name, user.real_name, user.profile?.real_name, user.name]
            .compactMap { $0 }.first { !$0.isEmpty } ?? user.id
    }

    /// The most recently active DMs first, as many as are worth a look per refresh.
    static func recent(_ conversations: [SlackConversation], limit: Int = conversationLimit) -> [SlackConversation] {
        Array(conversations.sorted { ($0.updated ?? 0) > ($1.updated ?? 0) }.prefix(limit))
    }

    /// How many unread messages a DM has: Slack's own count, or one when its latest message from someone else is after `last_read`.
    static func unread(_ conversation: SlackConversation, me: String) -> Int? {
        if let count = conversation.unreadDisplay { return count }
        guard let lastRead = conversation.lastRead, let latest = conversation.latest else { return nil }
        guard latest.user != me else { return 0 }
        return (Double(latest.ts) ?? 0) > (Double(lastRead) ?? 0) ? 1 : 0
    }

    /// The DMs to show: the unread ones when Slack gives read state for any of them, otherwise the ones active in the last 24 hours.
    static func directMessages(_ conversations: [SlackConversation], me: String, teamID: String, names: [String: String],
                               now: Date) -> SlackDirectMessages {
        let unreadKnown = conversations.contains { unread($0, me: me) != nil }
        let messages = conversations.compactMap { conversation -> SlackMessage? in
            guard let latest = conversation.latest else { return nil }
            let count = unread(conversation, me: me)
            if unreadKnown {
                guard let count, count > 0 else { return nil }
            } else {
                guard now.timeIntervalSince1970 - (Double(latest.ts) ?? 0) <= recentWindow, latest.user != me else { return nil }
            }
            let place = conversation.isGroup ? groupName(conversation.name ?? "") : conversation.user.map { names[$0] ?? $0 } ?? "Direct message"
            return SlackMessage(kind: .direct, teamID: teamID, channelID: conversation.id, place: place,
                                author: latest.user.map { names[$0] ?? $0 }, text: latest.text, ts: latest.ts, permalink: nil, unread: count)
        }
        return SlackDirectMessages(messages: messages, unreadKnown: unreadKnown)
    }

    /// `mpdm-anna--bo--me-1` as `anna, bo, me`.
    static func groupName(_ name: String) -> String {
        var text = name
        if text.hasPrefix("mpdm-") { text.removeFirst(5) }
        if let dash = text.range(of: "-", options: .backwards), text[dash.upperBound...].allSatisfy(\.isNumber) {
            text = String(text[..<dash.lowerBound])
        }
        return text.components(separatedBy: "--").filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Mentions and DMs newest first, a message found both ways once, as its DM.
    static func merged(mentions: [SlackMessage], direct: [SlackMessage]) -> [SlackMessage] {
        let directIDs = Set(direct.map(\.id))
        let all = direct + mentions.filter { !directIDs.contains($0.id) }
        return all.sorted { (Double($0.ts) ?? 0, $0.id) > (Double($1.ts) ?? 0, $1.id) }
    }

    // MARK: Needs me

    static func threadKey(_ channel: String, _ ts: String) -> String { "\(channel)/\(ts)" }

    /// The histories that tell whether the mentions are handled, skipping the ones marked in WorkTime, most recent first within the limits.
    static func readPlan(_ mentions: [SlackMessage], marks: [String: SlackHandled]) -> SlackReadPlan {
        let open = mentions.filter { $0.kind == .mention && marks[$0.id] == nil }.sorted { (Double($0.ts) ?? 0) > (Double($1.ts) ?? 0) }
        var plan = SlackReadPlan()
        for mention in open {
            if let index = plan.channels.firstIndex(where: { $0.id == mention.channelID }) {
                plan.channels[index] = .init(id: mention.channelID, oldest: mention.ts)
            } else if plan.channels.count < readChannelLimit {
                plan.channels.append(.init(id: mention.channelID, oldest: mention.ts))
            }
            if let thread = mention.threadTS, plan.threads.count < readThreadLimit, !plan.threads.contains(.init(channel: mention.channelID, ts: thread)) {
                plan.threads.append(.init(channel: mention.channelID, ts: thread))
            }
        }
        return plan
    }

    static func historyParameters(_ channel: SlackReadPlan.Channel) -> [String: String] {
        ["channel": channel.id, "oldest": channel.oldest, "inclusive": "true", "limit": "\(historyLimit)"]
    }

    static func repliesParameters(_ thread: SlackReadPlan.Thread) -> [String: String] {
        ["channel": thread.channel, "ts": thread.ts, "limit": "\(threadLimit)"]
    }

    /// Messages with who replied and reacted; for a thread, the user's read position that Slack puts on its first message.
    static func parseReadHistory(_ data: Data) throws -> SlackReadHistory {
        let messages = try JSONDecoder().decode(History.self, from: checked(data)).messages
        return SlackReadHistory(lastRead: messages.first { $0.thread_ts == $0.ts }?.last_read, messages: messages.map {
            SlackReadHistory.Message(ts: $0.ts, user: $0.user, replyUsers: $0.reply_users ?? [], reactors: ($0.reactions ?? []).flatMap { $0.users ?? [] })
        })
    }

    /// Why a mention no longer needs the user, or nil while it does. Without a history for it, it still does.
    static func handled(_ mention: SlackMessage, me: String, state: SlackReadState, marks: [String: SlackHandled]) -> SlackHandled? {
        guard mention.kind == .mention else { return nil }
        if let mark = marks[mention.id] { return mark }
        let ts = Double(mention.ts) ?? 0
        let after = { (other: String) in (Double(other) ?? 0) > ts }
        let thread = mention.threadTS.flatMap { state.threads[threadKey(mention.channelID, $0)] }
        let channel = state.channels[mention.channelID]
        let own = (mention.threadTS == nil ? channel : thread)?.messages.first { $0.ts == mention.ts }
        if own?.replyUsers.contains(me) == true || thread?.messages.contains(where: { $0.user == me && after($0.ts) }) == true { return .replied }
        if own?.reactors.contains(me) == true { return .reacted }
        if channel?.messages.contains(where: { after($0.ts) && ($0.user == me || $0.replyUsers.contains(me)) }) == true { return .postedAfter }
        let lastRead = mention.threadTS == nil ? channel?.lastRead : thread?.lastRead
        if let lastRead, (Double(lastRead) ?? 0) >= ts { return .read }
        return nil
    }

    static func annotated(_ mentions: [SlackMessage], me: String, state: SlackReadState, marks: [String: SlackHandled]) -> [SlackMessage] {
        mentions.map { mention in
            var copy = mention
            copy.handled = handled(mention, me: me, state: state, marks: marks)
            return copy
        }
    }

    /// The mentions dismissed or viewed in WorkTime, as stored by message id, without the ones older than `markDays`.
    static func marks(_ stored: Any?, now: Date) -> [String: SlackHandled] {
        let cutoff = now.timeIntervalSince1970 - Double(markDays) * 86400
        return ((stored as? [String: String]) ?? [:]).reduce(into: [:]) { marks, entry in
            guard let mark = SlackHandled(rawValue: entry.value), let ts = entry.key.split(separator: "-").last.flatMap({ Double($0) }),
                  ts >= cutoff else { return }
            marks[entry.key] = mark
        }
    }

    static func stored(_ marks: [String: SlackHandled]) -> [String: String] { marks.mapValues(\.rawValue) }

    // MARK: Text

    /// The user ids a text mentions without a label, to look up their names.
    static func mentionedUsers(in text: String) -> [String] {
        tokens(in: text).compactMap { token in
            guard token.hasPrefix("@"), !token.contains("|") else { return nil }
            return String(token.dropFirst())
        }
    }

    /// Slack's markup as plain text: names for user mentions, `#name` for channels, labels for links; emoji codes stay.
    static func clean(_ text: String, names: [String: String]) -> String {
        var output = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            output += rest[..<open]
            output += replacement(String(rest[rest.index(after: open)..<close]), names: names)
            rest = rest[rest.index(after: close)...]
        }
        output += rest
        return decodeEntities(output).replacingOccurrences(of: "\n", with: " ")
    }

    private static func replacement(_ token: String, names: [String: String]) -> String {
        let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
        let target = parts.first ?? ""
        let label = parts.count > 1 ? parts[1] : nil
        switch target.first {
        case "@":
            let id = String(target.dropFirst())
            return "@" + (names[id] ?? label.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 } ?? id)
        case "#":
            return "#" + (label ?? String(target.dropFirst()))
        case "!":
            if let label { return label }
            let command = target.dropFirst().split(separator: "^").first.map(String.init) ?? ""
            return "@" + command
        default:
            return label ?? (target.hasPrefix("mailto:") ? String(target.dropFirst(7)) : target)
        }
    }

    private static func tokens(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            found.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Links

    static func deepLink(_ message: SlackMessage) -> URL? {
        var components = URLComponents()
        components.scheme = "slack"
        components.host = "channel"
        components.queryItems = [URLQueryItem(name: "team", value: message.teamID), URLQueryItem(name: "id", value: message.channelID),
                                 URLQueryItem(name: "message", value: message.ts)]
        return components.url
    }

    /// Slack's permalink, or one built from the workspace address: `/archives/C123/p1700000000123456`.
    static func webLink(_ message: SlackMessage, workspace: String?) -> URL? {
        if let permalink = message.permalink { return URL(string: permalink) }
        guard let workspace, !workspace.isEmpty else { return nil }
        let root = workspace.hasSuffix("/") ? workspace : workspace + "/"
        return URL(string: "\(root)archives/\(message.channelID)/p\(message.ts.replacingOccurrences(of: ".", with: ""))")
    }

    static func badge(_ direct: SlackDirectMessages) -> Int {
        direct.unreadKnown ? direct.messages.reduce(0) { $0 + max($1.unread ?? 1, 1) } : 0
    }

    // MARK: Decoding

    private static func conversation(_ channel: Channel) -> SlackConversation {
        SlackConversation(id: channel.id, user: channel.user, name: channel.name, isGroup: channel.is_mpim == true,
                          updated: channel.updated.map { $0 > 10_000_000_000 ? $0 / 1000 : $0 }, lastRead: channel.last_read,
                          unreadDisplay: channel.unread_count_display, latest: channel.latest.map(raw))
    }

    private static func raw(_ message: Message) -> SlackRawMessage {
        SlackRawMessage(ts: message.ts, text: message.text ?? "", user: message.user ?? message.bot_id)
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let error: String?
        let needed: String?
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let token_type: String?
        let refresh_token: String?
        let expires_in: Int?
        let authed_user: User?
        struct User: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Int?
        }
    }

    private struct AuthTest: Decodable {
        let url: String?
        let team: String?
        let user: String?
        let team_id: String
        let user_id: String
    }

    private struct Search: Decodable {
        let messages: Matches?
        struct Matches: Decodable { let matches: [Match]? }
        struct Match: Decodable {
            let ts: String
            let text: String?
            let user: String?
            let username: String?
            let team: String?
            let permalink: String?
            let channel: MatchChannel?
        }
        struct MatchChannel: Decodable {
            let id: String
            let name: String?
            let is_im: Bool?
            let is_mpim: Bool?
        }
    }

    private struct Channel: Decodable {
        let id: String
        let user: String?
        let name: String?
        let is_mpim: Bool?
        let updated: Double?
        let last_read: String?
        let unread_count_display: Int?
        let latest: Message?
    }

    private struct Message: Decodable {
        let ts: String
        let text: String?
        let user: String?
        let bot_id: String?
        let username: String?
        var thread_ts: String? = nil
        var last_read: String? = nil
        var reply_users: [String]? = nil
        var reactions: [Reaction]? = nil
        struct Reaction: Decodable { let users: [String]? }
    }

    private struct ConversationList: Decodable {
        let channels: [Channel]
        let response_metadata: Metadata?
        struct Metadata: Decodable { let next_cursor: String? }
    }

    private struct ConversationInfo: Decodable { let channel: Channel }

    private struct History: Decodable {
        let messages: [Message]
        let has_more: Bool?
    }

    private struct UserInfo: Decodable {
        let user: User
        struct User: Decodable {
            let id: String
            let name: String?
            let real_name: String?
            let profile: Profile?
        }
        struct Profile: Decodable {
            let display_name: String?
            let real_name: String?
        }
    }
}
