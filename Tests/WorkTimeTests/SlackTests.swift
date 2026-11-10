import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_793_000_000)
private let me = SlackIdentity(userID: "U0ME", user: "niklas", teamID: "T0ACME", team: "Acme", url: "https://acme.slack.com/")

private func ts(_ secondsAgo: Double) -> String { String(format: "%.6f", now.timeIntervalSince1970 - secondsAgo) }

private let authFixture = Data(#"{"ok":true,"url":"https://acme.slack.com/","team":"Acme","user":"niklas","team_id":"T0ACME","user_id":"U0ME"}"#.utf8)

private let searchFixture = Data("""
{"ok":true,"query":"<@U0ME>","messages":{"total":4,"matches":[
 {"iid":"1","ts":"\(ts(600))","text":"<@U0ME> can you look at <https://github.com/acme/api/pull/7|PR 7>? :eyes:","user":"U0ANNA","username":"anna","team":"T0ACME",
  "permalink":"https://acme.slack.com/archives/C0DEV/p1792999400000000","channel":{"id":"C0DEV","name":"dev","is_im":false,"is_mpim":false}},
 {"iid":"2","ts":"\(ts(7200))","text":"ping <@U0ME>","user":"U0BO","username":"bo","team":"T0ACME","channel":{"id":"G0GRP","name":"mpdm-anna--bo--niklas-1","is_im":false,"is_mpim":true}},
 {"iid":"3","ts":"\(ts(8 * 86400))","text":"old <@U0ME>","user":"U0BO","username":"bo","channel":{"id":"C0DEV","name":"dev"}},
 {"iid":"4","ts":"\(ts(60))","text":"note to self <@U0ME>","user":"U0ME","username":"niklas","channel":{"id":"C0DEV","name":"dev"}}
]}}
""".utf8)

private let listFixture = Data("""
{"ok":true,"channels":[
 {"id":"D0OLD","is_im":true,"user":"U0OLD","updated":1700000000000},
 {"id":"D0ANNA","is_im":true,"user":"U0ANNA","updated":\(Int(now.timeIntervalSince1970 - 300) * 1000)},
 {"id":"G0GRP","is_mpim":true,"name":"mpdm-anna--bo--niklas-1","updated":\(Int(now.timeIntervalSince1970 - 900) * 1000)}
],"response_metadata":{"next_cursor":"dGVhbTpD"}}
""".utf8)

private func infoFixture(_ id: String, unread: Int?, lastRead: String?, latest: (String, String, String)?) -> Data {
    var fields = [#""id":"\#(id)""#]
    if let unread { fields.append(#""unread_count_display":\#(unread)"#) }
    if let lastRead { fields.append(#""last_read":"\#(lastRead)""#) }
    if let latest { fields.append(#""latest":{"ts":"\#(latest.0)","user":"\#(latest.1)","text":"\#(latest.2)"}"#) }
    return Data(#"{"ok":true,"channel":{\#(fields.joined(separator: ","))}}"#.utf8)
}

private func message(_ kind: SlackMessage.Kind, _ channel: String, _ ts: String) -> SlackMessage {
    SlackMessage(kind: kind, teamID: "T0ACME", channelID: channel, place: channel, author: nil, text: "", ts: ts, permalink: nil, unread: nil)
}

private final class Calls: @unchecked Sendable {
    var methods: [String] = []
}

private func fake(_ calls: Calls, answer: @escaping @Sendable (String, [String: String]) -> (Int, Data, String?)) -> SlackTransport {
    { request in
        let url = request.url!
        let method = url.lastPathComponent
        let parameters = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.methods.append(parameters["channel"].map { "\(method) \($0)" } ?? method)
        let (status, body, retry) = answer(method, parameters)
        return (body, status, retry)
    }
}

let slackTests: [(name: String, run: () throws -> Void)] = [
    ("auth.test gives the user, team and workspace address", {
        let identity = try SlackLogic.parseIdentity(authFixture)
        check(identity == me, "\(identity)")
    }),

    ("Slack's error codes become errors that say what to fix", {
        func code(_ body: String) -> SlackError? {
            do { _ = try SlackLogic.checked(Data(body.utf8)); return nil } catch { return error as? SlackError }
        }
        check(code(#"{"ok":false,"error":"invalid_auth"}"#) == .unauthorized, "invalid_auth")
        check(code(#"{"ok":false,"error":"missing_scope","needed":"search:read"}"#) == .missingScope("search:read"), "missing scope")
        check(code(#"{"ok":false,"error":"channel_not_found"}"#) == .failed("channel_not_found"), "other")
        check(code("<html>") == .failed("unexpected response"), "not json")
        check(code(#"{"ok":true}"#) == nil, "ok")
        check(SlackError.missingScope("search:read").message.contains("search:read"), "message names the scope")
    }),

    ("the mention search asks for the last week newest first", {
        let parameters = SlackLogic.searchParameters(userID: "U0ME", now: now)
        check(parameters["query"]?.hasPrefix("<@U0ME> after:") == true, "query \(parameters["query"] ?? "")")
        check(parameters["sort"] == "timestamp" && parameters["sort_dir"] == "desc", "sorted by time")
        let request = SlackLogic.request(method: "search.messages", token: "xoxp-fake", parameters: parameters)
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer xoxp-fake", "bearer token")
        check(request.url?.absoluteString.hasPrefix("https://slack.com/api/search.messages?") == true, "url \(request.url?.absoluteString ?? "")")
    }),

    ("search.messages becomes mentions from the last week, without my own messages", {
        let mentions = try SlackLogic.parseMentions(searchFixture, teamID: "T0ACME", me: "U0ME", now: now)
        check(mentions.map(\.channelID) == ["C0DEV", "G0GRP"], "kept \(mentions.map(\.channelID))")
        check(mentions[0].place == "#dev" && mentions[0].author == "anna", "channel and author")
        check(mentions[0].permalink?.hasSuffix("p1792999400000000") == true, "permalink")
        check(mentions[1].place == "anna, bo, niklas", "group DM \(mentions[1].place)")
        check(mentions.allSatisfy { $0.kind == .mention && $0.teamID == "T0ACME" }, "kind and team")
    }),

    ("conversations.list and conversations.info are parsed with read state", {
        let listed = try SlackLogic.parseConversations(listFixture)
        check(listed.cursor == "dGVhbTpD", "cursor")
        check(listed.conversations.map(\.id) == ["D0OLD", "D0ANNA", "G0GRP"], "ids")
        check(listed.conversations[1].user == "U0ANNA" && !listed.conversations[1].isGroup && listed.conversations[2].isGroup, "im and mpim")
        check(listed.conversations[0].updated == 1_700_000_000, "milliseconds become seconds")
        check(SlackLogic.recent(listed.conversations, limit: 2).map(\.id) == ["D0ANNA", "G0GRP"], "most recent first")
        let info = try SlackLogic.parseConversationInfo(infoFixture("D0ANNA", unread: 2, lastRead: ts(900), latest: (ts(300), "U0ANNA", "lunch?")))
        check(info.unreadDisplay == 2 && info.lastRead == ts(900), "read state")
        check(info.latest == SlackRawMessage(ts: ts(300), text: "lunch?", user: "U0ANNA"), "latest")
        let history = try SlackLogic.parseLatest(Data(#"{"ok":true,"messages":[{"ts":"1.0","text":"hi","bot_id":"B1"}]}"#.utf8))
        check(history == SlackRawMessage(ts: "1.0", text: "hi", user: "B1"), "history")
    }),

    ("a DM is unread by Slack's count, or by its latest message from someone else after last_read", {
        let latest = SlackRawMessage(ts: ts(60), text: "", user: "U0ANNA")
        var conversation = SlackConversation(id: "D1", isGroup: false, unreadDisplay: 3)
        check(SlackLogic.unread(conversation, me: "U0ME") == 3, "count")
        conversation = SlackConversation(id: "D1", isGroup: false, lastRead: ts(120), latest: latest)
        check(SlackLogic.unread(conversation, me: "U0ME") == 1, "newer than last read")
        conversation.lastRead = ts(30)
        check(SlackLogic.unread(conversation, me: "U0ME") == 0, "read")
        conversation = SlackConversation(id: "D1", isGroup: false, lastRead: ts(120), latest: SlackRawMessage(ts: ts(60), text: "", user: "U0ME"))
        check(SlackLogic.unread(conversation, me: "U0ME") == 0, "my own last message")
        check(SlackLogic.unread(SlackConversation(id: "D1", isGroup: false, latest: latest), me: "U0ME") == nil, "unknown")
    }),

    ("only unread DMs are listed when Slack gives read state, otherwise the last 24 hours", {
        let conversations = [
            SlackConversation(id: "D0ANNA", user: "U0ANNA", isGroup: false, unreadDisplay: 2, latest: SlackRawMessage(ts: ts(300), text: "lunch?", user: "U0ANNA")),
            SlackConversation(id: "D0BO", user: "U0BO", isGroup: false, unreadDisplay: 0, latest: SlackRawMessage(ts: ts(60), text: "ok", user: "U0BO")),
            SlackConversation(id: "G0GRP", name: "mpdm-anna--bo--niklas-1", isGroup: true, lastRead: ts(9000), latest: SlackRawMessage(ts: ts(900), text: "standup?", user: "U0BO")),
        ]
        let direct = SlackLogic.directMessages(conversations, me: "U0ME", teamID: "T0ACME", names: ["U0ANNA": "Anna", "U0BO": "Bo"], now: now)
        check(direct.unreadKnown, "read state known")
        check(direct.messages.map(\.channelID) == ["D0ANNA", "G0GRP"], "unread only: \(direct.messages.map(\.channelID))")
        check(direct.messages[0].place == "Anna" && direct.messages[0].unread == 2, "person and count")
        check(direct.messages[1].place == "anna, bo, niklas" && direct.messages[1].author == "Bo", "group and author")
        check(SlackLogic.badge(direct) == 3, "badge counts unread messages")
        let unknown = conversations.map { conversation -> SlackConversation in
            var copy = conversation
            copy.unreadDisplay = nil
            copy.lastRead = nil
            return copy
        } + [SlackConversation(id: "D0OLD", user: "U0OLD", isGroup: false, latest: SlackRawMessage(ts: ts(2 * 86400), text: "old", user: "U0OLD"))]
        let recent = SlackLogic.directMessages(unknown, me: "U0ME", teamID: "T0ACME", names: [:], now: now)
        check(!recent.unreadKnown, "no read state")
        check(recent.messages.map(\.channelID) == ["D0ANNA", "D0BO", "G0GRP"], "last 24 hours: \(recent.messages.map(\.channelID))")
        check(SlackLogic.badge(recent) == 0, "no badge without read state")
    }),

    ("Slack markup is cleaned: names for mentions, #name for channels, labels for links, emoji codes kept", {
        let names = ["U0ANNA": "Anna"]
        check(SlackLogic.clean("<@U0ANNA> see <#C0DEV|dev> and <https://x.com/a|the doc> :tada:", names: names)
              == "@Anna see #dev and the doc :tada:", "basic")
        check(SlackLogic.clean("<https://x.com/a> <mailto:a@b.se|a@b.se> <mailto:c@d.se>", names: [:]) == "https://x.com/a a@b.se c@d.se", "bare links")
        check(SlackLogic.clean("<@U0BO> <@U0CY|cy> <#C0OPS>", names: names) == "@U0BO @cy #C0OPS", "unknown names fall back")
        check(SlackLogic.clean("<!here> <!channel> <!subteam^S1|@devs> <!date^1700000000^{date}|Nov 14>", names: [:])
              == "@here @channel @devs Nov 14", "special mentions")
        check(SlackLogic.clean("a &lt;b&gt; &amp; c\nd", names: [:]) == "a <b> & c d", "entities and newlines")
        check(SlackLogic.clean("no markup < here", names: [:]) == "no markup < here", "a lone bracket stays")
        check(SlackLogic.mentionedUsers(in: "<@U0ANNA> <@U0BO|bo> <#C1|x> <@U0CY>") == ["U0ANNA", "U0CY"], "ids to look up")
    }),

    ("a group DM's name lists its people", {
        check(SlackLogic.groupName("mpdm-anna--bo--niklas-1") == "anna, bo, niklas", "mpdm")
        check(SlackLogic.groupName("anna--bo") == "anna, bo", "without prefix and suffix")
    }),

    ("a message opens through a slack:// deep link, or its permalink or archive link on the web", {
        var mention = message(.mention, "C0DEV", "1792999400.000100")
        check(SlackLogic.deepLink(mention)?.absoluteString == "slack://channel?team=T0ACME&id=C0DEV&message=1792999400.000100", "deep link")
        check(SlackLogic.webLink(mention, workspace: "https://acme.slack.com/")?.absoluteString
              == "https://acme.slack.com/archives/C0DEV/p1792999400000100", "archive link")
        check(SlackLogic.webLink(mention, workspace: "https://acme.slack.com")?.absoluteString
              == "https://acme.slack.com/archives/C0DEV/p1792999400000100", "without a trailing slash")
        mention.permalink = "https://acme.slack.com/archives/C0DEV/p1"
        check(SlackLogic.webLink(mention, workspace: nil)?.absoluteString == mention.permalink, "permalink wins")
        check(SlackLogic.webLink(message(.direct, "D1", "1.2"), workspace: nil) == nil, "nothing to build from")
    }),

    ("mentions and DMs merge newest first, a DM found by the search once", {
        let mentions = [message(.mention, "C0DEV", "300.0"), message(.mention, "D0ANNA", "200.0"), message(.mention, "C0OPS", "100.0")]
        let direct = [message(.direct, "D0ANNA", "200.0"), message(.direct, "D0BO", "250.0")]
        let merged = SlackLogic.merged(mentions: mentions, direct: direct)
        check(merged.map(\.channelID) == ["C0DEV", "D0BO", "D0ANNA", "C0OPS"], "\(merged.map(\.channelID))")
        check(merged.first { $0.channelID == "D0ANNA" }?.kind == .direct, "the DM wins")
    }),

    ("the client fetches mentions and DMs, skipping the history of read DMs and naming people", {
        let calls = Calls()
        let client = SlackClient(token: "xoxp-fake", transport: fake(calls) { method, parameters in
            switch (method, parameters["channel"]) {
            case ("auth.test", _): return (200, authFixture, nil)
            case ("search.messages", _): return (200, searchFixture, nil)
            case ("conversations.list", _): return (200, listFixture, nil)
            case ("conversations.info", "D0ANNA"): return (200, infoFixture("D0ANNA", unread: 1, lastRead: nil, latest: nil), nil)
            case ("conversations.info", "G0GRP"): return (200, infoFixture("G0GRP", unread: 0, lastRead: nil, latest: nil), nil)
            case ("conversations.info", _): return (200, infoFixture(parameters["channel"]!, unread: 0, lastRead: nil, latest: nil), nil)
            case ("conversations.history", "D0ANNA"):
                return (200, Data(#"{"ok":true,"messages":[{"ts":"\#(ts(300))","user":"U0ANNA","text":"lunch <@U0ME>?"}]}"#.utf8), nil)
            case ("users.info", _): return (200, Data(#"{"ok":true,"user":{"id":"U0ANNA","name":"anna","real_name":"Anna Berg","profile":{"display_name":""}}}"#.utf8), nil)
            default: return (404, Data(), nil)
            }
        })
        nonisolated(unsafe) var identity: SlackIdentity?
        nonisolated(unsafe) var mentions: [SlackMessage] = []
        nonisolated(unsafe) var direct: SlackDirectMessages?
        try blocking {
            identity = try await client.identity()
            mentions = try await client.mentions(of: me, now: now)
            direct = try await client.directMessages(of: me, names: [:], now: now)
        }
        check(identity == me, "identity")
        check(mentions.count == 2, "mentions")
        check(direct?.messages.map(\.channelID) == ["D0ANNA"], "unread DM \(String(describing: direct?.messages.map(\.channelID)))")
        check(direct?.messages.first?.place == "Anna Berg" && direct?.names["U0ANNA"] == "Anna Berg", "named")
        check(!calls.methods.contains("conversations.history G0GRP") && !calls.methods.contains("conversations.history D0OLD"), "no history for read DMs: \(calls.methods)")
        check(calls.methods.contains("conversations.history D0ANNA"), "history for the unread one")
    }),

    ("a rate limited answer carries Slack's Retry-After", {
        for (status, body) in [(429, Data()), (200, Data(#"{"ok":false,"error":"ratelimited"}"#.utf8))] {
            let client = SlackClient(token: "xoxp-fake", transport: fake(Calls()) { _, _ in (status, body, "30") })
            nonisolated(unsafe) var caught: Error?
            try? blocking {
                do { _ = try await client.identity() } catch { caught = error }
            }
            check(caught as? SlackError == .rateLimited(retryAfter: 30), "status \(status): \(String(describing: caught))")
        }
        check(SlackLogic.retryAfter(nil) == 60 && SlackLogic.retryAfter("0") == 1 && SlackLogic.retryAfter(" 12 ") == 12, "header parsing")
    }),

    ("a user token is told apart from a bot token, and no error message carries the token", {
        check(SlackLogic.isUserToken("xoxp-1-2") && !SlackLogic.isUserToken("xoxb-1-2"), "prefix")
        for error in [SlackError.unauthorized, .notConfigured, .offline, .rateLimited(retryAfter: 1), .missingScope("im:read")] {
            check(!error.message.contains("xoxp"), "no token in \(error)")
        }
    }),
]
