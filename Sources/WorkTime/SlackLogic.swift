import Foundation

struct SlackIdentity: Equatable, Sendable {
    let userID: String
    let user: String
    let teamID: String
    let team: String
    /// The workspace address, e.g. `https://acme.slack.com/`.
    let url: String
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

enum SlackError: Error, Equatable {
    case notConfigured
    case unauthorized
    case missingScope(String)
    case rateLimited(retryAfter: Int)
    case offline
    case failed(String)

    var message: String {
        switch self {
        case .notConfigured: return "Add a Slack user token in Settings."
        case .unauthorized: return "Slack did not accept the token. Check it in Settings."
        case .missingScope(let scope): return "The Slack token lacks the \(scope) scope. Add it to your Slack app and reinstall it."
        case .rateLimited: return "Slack is rate limiting requests. Trying again shortly."
        case .offline: return "Slack cannot be reached. Check your connection."
        case .failed(let detail): return "Slack returned an error: \(detail)"
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
    static let mentionLimit = 20
    static let conversationLimit = 12
    static let recentWindow: TimeInterval = 24 * 3600

    static func isUserToken(_ token: String) -> Bool { token.hasPrefix("xoxp-") }

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
        let response = try JSONDecoder().decode(Search.self, from: checked(data))
        let cutoff = now.addingTimeInterval(-Double(mentionDays) * 86400).timeIntervalSince1970
        return (response.messages?.matches ?? []).compactMap { match in
            guard let channel = match.channel, (Double(match.ts) ?? 0) >= cutoff, match.user != me else { return nil }
            let place: String
            if channel.is_im == true {
                place = match.username ?? "Direct message"
            } else if channel.is_mpim == true {
                place = groupName(channel.name ?? "")
            } else {
                place = "#" + (channel.name ?? channel.id)
            }
            return SlackMessage(kind: .mention, teamID: match.team ?? teamID, channelID: channel.id, place: place,
                                author: match.username ?? match.user, text: match.text ?? "", ts: match.ts, permalink: match.permalink, unread: nil)
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
    }

    private struct ConversationList: Decodable {
        let channels: [Channel]
        let response_metadata: Metadata?
        struct Metadata: Decodable { let next_cursor: String? }
    }

    private struct ConversationInfo: Decodable { let channel: Channel }

    private struct History: Decodable { let messages: [Message] }

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
