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

private let historyFixture = Data("""
{"ok":true,"has_more":false,"messages":[
 {"ts":"\(ts(100))","user":"U0ANNA","text":"thread started later","reply_count":2,"reply_users":["U0BO","U0ME"]},
 {"ts":"\(ts(200))","user":"U0BO","text":"follow-up"},
 {"ts":"\(ts(300))","user":"U0ANNA","text":"<@U0ME> deploy?","reactions":[{"name":"eyes","users":["U0BO"],"count":1}]},
 {"ts":"\(ts(400))","user":"U0BO","text":"<@U0ME> ping","reactions":[{"name":"+1","users":["U0ME"],"count":1}]},
 {"ts":"\(ts(500))","user":"U0BO","text":"<@U0ME> question","reply_count":1,"reply_users":["U0ME"]}
]}
""".utf8)

private let repliesFixture = Data("""
{"ok":true,"has_more":false,"messages":[
 {"ts":"\(ts(3000))","thread_ts":"\(ts(3000))","user":"U0ANNA","text":"root","reply_users":["U0BO"],"subscribed":true,"last_read":"\(ts(2500))"},
 {"ts":"\(ts(2900))","thread_ts":"\(ts(3000))","user":"U0BO","text":"<@U0ME> before read"},
 {"ts":"\(ts(2000))","thread_ts":"\(ts(3000))","user":"U0BO","text":"<@U0ME> after read"}
]}
""".utf8)

private func mention(_ channel: String, _ ts: String, thread: String? = nil) -> SlackMessage {
    var copy = message(.mention, channel, ts)
    copy.threadTS = thread
    return copy
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
    ("the PKCE challenge is the verifier's SHA-256 in base64url, and each sign-in gets a fresh state and verifier", {
        check(SlackLogic.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 vector")
        let first = SlackLogic.newSignIn(), second = SlackLogic.newSignIn()
        check(first != second, "random")
        check(first.verifier.count == 43 && first.state.count == 22, "lengths \(first.verifier.count) \(first.state.count)")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        check(first.verifier.unicodeScalars.allSatisfy(allowed.contains), "unreserved characters only")
    }),

    ("the authorize link asks for the user scopes with PKCE and the app's redirect, and no bot scopes", {
        let signIn = SlackSignIn(state: "st4te", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = SlackLogic.authorizeURL(clientID: "123.456", signIn: signIn)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        check(url.absoluteString.hasPrefix("https://slack.com/oauth/v2/authorize?"), "page")
        check(query == ["client_id": "123.456", "user_scope": SlackLogic.scopes.joined(separator: ","), "redirect_uri": "worktime://slack-auth",
                        "state": "st4te", "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "code_challenge_method": "S256"],
              "\(query)")
    }),

    ("the callback gives its code only when the state matches the waiting sign-in", {
        let signIn = SlackSignIn(state: "abc", verifier: "v")
        let mismatch = SlackError.signIn("the reply did not match this sign-in. Try again")
        func code(_ link: String, _ waiting: SlackSignIn? = signIn) -> Result<String, SlackError> {
            Result { try SlackLogic.callbackCode(URL(string: link)!, expecting: waiting) }.mapError { $0 as! SlackError }
        }
        check(SlackLogic.isCallback(URL(string: "worktime://slack-auth?code=1")!), "callback")
        check(SlackLogic.isCallback(URL(string: "meetingrecorder://slack-auth")!), "legacy scheme")
        check(!SlackLogic.isCallback(URL(string: "worktime://pr?url=x")!) && !SlackLogic.isCallback(URL(string: "https://slack-auth/")!), "others")
        check(try code("worktime://slack-auth?code=c0de&state=abc").get() == "c0de", "match")
        check(code("worktime://slack-auth?code=c0de&state=evil") == .failure(mismatch), "state mismatch")
        check(code("worktime://slack-auth?code=c0de") == .failure(mismatch), "no state")
        check(code("worktime://slack-auth?code=c0de&state=abc", nil) == .failure(mismatch), "nothing waiting")
        check(code("worktime://slack-auth?error=access_denied&state=abc") == .failure(.signIn("you cancelled it")), "cancelled")
        check(code("worktime://slack-auth?state=abc") == .failure(.signIn("Slack sent no code")), "no code")
    }),

    ("the code and refresh requests are form posts to oauth.v2.access with the client id and no secret", {
        func fields(_ request: URLRequest) -> [String: String] {
            var components = URLComponents()
            components.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
            return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let exchange = SlackLogic.tokenRequest(clientID: "123.456", code: "c/d+e", verifier: "ver")
        check(exchange.httpMethod == "POST" && exchange.url?.absoluteString == "https://slack.com/api/oauth.v2.access", "endpoint")
        check(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded", "form")
        check(exchange.value(forHTTPHeaderField: "Authorization") == nil, "no bearer")
        check(fields(exchange) == ["client_id": "123.456", "code": "c/d+e", "code_verifier": "ver", "redirect_uri": "worktime://slack-auth",
                                   "grant_type": "authorization_code"], "\(fields(exchange))")
        let refresh = SlackLogic.refreshRequest(clientID: "123.456", refreshToken: "xoxe-1-r")
        check(fields(refresh) == ["client_id": "123.456", "grant_type": "refresh_token", "refresh_token": "xoxe-1-r"], "\(fields(refresh))")
        check(!String(decoding: exchange.httpBody!, as: UTF8.self).contains("client_secret"), "no secret")
    }),

    ("the token response gives the user's rotating token, and a refresh keeps the refresh token when Slack sends none", {
        let signedIn = Data(#"{"ok":true,"app_id":"A1","team":{"id":"T0ACME","name":"Acme"},"authed_user":{"id":"U0ME","scope":"search:read","access_token":"xoxe.xoxp-1-abc","expires_in":43200,"refresh_token":"xoxe-1-ref","token_type":"user"}}"#.utf8)
        let auth = try SlackLogic.parseAuth(signedIn, now: now)
        check(auth == SlackAuth(accessToken: "xoxe.xoxp-1-abc", refreshToken: "xoxe-1-ref", expires: now.addingTimeInterval(43200)), "\(auth)")
        let topLevel = Data(#"{"ok":true,"access_token":"xoxe.xoxp-1-new","token_type":"user","expires_in":43200}"#.utf8)
        let renewed = try SlackLogic.parseAuth(topLevel, now: now, previous: auth)
        check(renewed.accessToken == "xoxe.xoxp-1-new" && renewed.refreshToken == "xoxe-1-ref", "kept refresh token")
        let bot = Data(#"{"ok":true,"access_token":"xoxb-1","token_type":"bot"}"#.utf8)
        check((try? SlackLogic.parseAuth(bot, now: now)) == nil, "a bot token is refused")
        var caught: Error?
        do { _ = try SlackLogic.parseAuth(Data(#"{"ok":false,"error":"invalid_code_verifier"}"#.utf8), now: now) } catch { caught = error }
        check(caught as? SlackError == .failed("invalid_code_verifier"), "\(String(describing: caught))")
    }),

    ("a signed-in token is refreshed five minutes before it runs out; a pasted token never is", {
        let auth = SlackAuth(accessToken: "xoxe.xoxp-1", refreshToken: "xoxe-1-r", expires: now.addingTimeInterval(600))
        check(!SlackLogic.needsRefresh(auth, now: now), "ten minutes left")
        check(SlackLogic.needsRefresh(auth, now: now.addingTimeInterval(400)), "three minutes left")
        check(SlackLogic.needsRefresh(auth, now: now.addingTimeInterval(9000)), "expired")
        check(!SlackLogic.needsRefresh(SlackAuth(accessToken: "xoxp-1"), now: now), "pasted")
    }),

    ("the stored value is the plain token for a pasted one and JSON for a sign-in, and both read back", {
        check(SlackAuth(stored: "xoxp-1-2") == SlackAuth(accessToken: "xoxp-1-2"), "token saved before sign-in existed")
        check(SlackAuth(accessToken: "xoxp-1-2").stored == "xoxp-1-2", "pasted stays plain")
        let auth = SlackAuth(accessToken: "xoxe.xoxp-1", refreshToken: "xoxe-1-r", expires: now)
        check(auth.stored.hasPrefix("{") && SlackAuth(stored: auth.stored) == auth, "round trip")
        check(SlackAuth(stored: "") == nil && SlackAuth(stored: "{broken") == nil, "nothing")
    }),

    ("a code is exchanged through the transport without a bearer token", {
        let sent = Calls()
        let transport: SlackTransport = { request in
            sent.methods.append("\(request.httpMethod ?? "") \(request.url!.lastPathComponent) \(request.value(forHTTPHeaderField: "Authorization") ?? "-")")
            return (Data(#"{"ok":true,"authed_user":{"access_token":"xoxe.xoxp-9","refresh_token":"xoxe-1-9","expires_in":60}}"#.utf8), 200, nil)
        }
        try blocking {
            let auth = try await SlackClient.authorize(SlackLogic.tokenRequest(clientID: "1.2", code: "c", verifier: "v"), now: now, transport: transport)
            check(auth.accessToken == "xoxe.xoxp-9" && auth.expires == now.addingTimeInterval(60), "\(auth)")
        }
        check(sent.methods == ["POST oauth.v2.access -"], "\(sent.methods)")
    }),

    ("no error message carries a Slack token", {
        let detail = "bad xoxp-1-2-3 and xoxe.xoxp-1-abc and xoxe-1-ref and xoxb-9"
        for error in [SlackError.failed(detail), .signIn(detail)] {
            check(!error.message.contains("xoxp-1") && !error.message.contains("abc") && !error.message.contains("ref") && !error.message.contains("xoxb-9"),
                  error.message)
        }
        check(SecretRedaction.redact("token xoxe.xoxp-1-abc end", key: nil) == "token xox\u{2026} end", "redacted")
    }),

    ("a mention's thread comes from its permalink", {
        let search = Data("""
        {"ok":true,"messages":{"matches":[{"ts":"\(ts(60))","text":"<@U0ME>","user":"U0BO","channel":{"id":"C0DEV","name":"dev"},
         "permalink":"https://acme.slack.com/archives/C0DEV/p1792999940000000?thread_ts=1792999000.000100&cid=C0DEV"}]}}
        """.utf8)
        let mentions = try SlackLogic.parseMentions(search, teamID: "T0ACME", me: "U0ME", now: now)
        check(mentions.first?.threadTS == "1792999000.000100", "\(String(describing: mentions.first?.threadTS))")
        check(try SlackLogic.parseMentions(searchFixture, teamID: "T0ACME", me: "U0ME", now: now).allSatisfy { $0.threadTS == nil }, "top level")
    }),

    ("the read plan fetches each channel once from its oldest open mention and each thread once, skipping marked mentions", {
        let mentions = [mention("C0DEV", "300.0"), mention("C0DEV", "100.0"), mention("C0OPS", "250.0", thread: "200.0"),
                        mention("C0OPS", "260.0", thread: "200.0"), mention("C0OLD", "50.0"), message(.direct, "D0ANNA", "400.0")]
        let plan = SlackLogic.readPlan(mentions, marks: ["C0OLD-50.0": .dismissed])
        check(plan.channels == [.init(id: "C0DEV", oldest: "100.0"), .init(id: "C0OPS", oldest: "250.0")], "\(plan.channels)")
        check(plan.threads == [.init(channel: "C0OPS", ts: "200.0")], "\(plan.threads)")
        check(SlackLogic.historyParameters(plan.channels[0]) == ["channel": "C0DEV", "oldest": "100.0", "inclusive": "true", "limit": "50"], "history")
        let many = (0..<30).map { mention("C\($0)", "\(1000 + $0).0", thread: "\($0).0") }
        let capped = SlackLogic.readPlan(many, marks: [:])
        check(capped.channels.count == SlackLogic.readChannelLimit && capped.threads.count == SlackLogic.readThreadLimit, "limits")
        check(capped.channels.first?.id == "C29", "most recent first")
    }),

    ("a mention needs me until I reply, react, post after it, read past it or mark it, and with no history it still does", {
        let channel = try SlackLogic.parseReadHistory(historyFixture)
        check(channel.messages.count == 5 && channel.messages[3].reactors == ["U0ME"] && channel.messages[0].replyUsers == ["U0BO", "U0ME"], "parsed")
        var state = SlackReadState(channels: ["C0DEV": channel])
        func reason(_ m: SlackMessage, marks: [String: SlackHandled] = [:]) -> SlackHandled? {
            SlackLogic.handled(m, me: "U0ME", state: state, marks: marks)
        }
        check(reason(mention("C0DEV", ts(500))) == .replied, "replied in its thread")
        check(reason(mention("C0DEV", ts(400))) == .reacted, "reacted")
        check(reason(mention("C0DEV", ts(300))) == .postedAfter, "replied in a later thread")
        check(reason(mention("C0DEV", ts(50))) == nil, "nothing after it")
        check(reason(mention("C0OPS", ts(50))) == nil, "no history fails open")
        check(reason(mention("C0DEV", ts(50)), marks: ["C0DEV-\(ts(50))": .viewed]) == .viewed, "viewed in WorkTime")
        check(reason(message(.direct, "C0DEV", ts(500))) == nil, "DMs are not judged")
        state.channels["C0DEV"]?.lastRead = ts(40)
        check(reason(mention("C0DEV", ts(50))) == .read, "channel read past it")
        state.channels["C0DEV"]?.messages.append(.init(ts: ts(10), user: "U0ME"))
        check(reason(mention("C0DEV", ts(50))) == .postedAfter, "posting beats reading")
    }),

    ("a mention in a thread is handled by a reply after it or the thread's own read position, not the channel's", {
        let thread = try SlackLogic.parseReadHistory(repliesFixture)
        check(thread.lastRead == ts(2500), "the parent carries last_read")
        var state = SlackReadState(channels: ["C0DEV": SlackReadHistory(lastRead: ts(1), messages: [])],
                                   threads: [SlackLogic.threadKey("C0DEV", ts(3000)): thread])
        let before = mention("C0DEV", ts(2900), thread: ts(3000)), after = mention("C0DEV", ts(2000), thread: ts(3000))
        check(SlackLogic.handled(before, me: "U0ME", state: state, marks: [:]) == .read, "read past it in the thread")
        check(SlackLogic.handled(after, me: "U0ME", state: state, marks: [:]) == nil, "channel read does not count for a thread")
        state.threads[SlackLogic.threadKey("C0DEV", ts(3000))]?.messages.append(.init(ts: ts(1500), user: "U0ME"))
        check(SlackLogic.handled(after, me: "U0ME", state: state, marks: [:]) == .replied, "replied after it")
        let annotated = SlackLogic.annotated([before, after], me: "U0ME", state: state, marks: [:])
        check(annotated.map(\.handled) == [.replied, .replied], "a reply after both answers both")
    }),

    ("marks older than eight days are pruned and the rest read back", {
        let stored: [String: String] = ["C0DEV-\(ts(3600))": "dismissed", "C0OPS-\(ts(9 * 86400))": "viewed", "C0X-\(ts(60))": "bogus"]
        let marks = SlackLogic.marks(stored, now: now)
        check(marks == ["C0DEV-\(ts(3600))": .dismissed], "\(marks)")
        check(SlackLogic.stored(marks) == ["C0DEV-\(ts(3600))": "dismissed"], "stored")
        check(SlackLogic.marks(nil, now: now).isEmpty, "nothing stored")
    }),

    ("a fresh read state keeps its entries and borrows the rest from the last one", {
        let old = SlackReadState(channels: ["C1": SlackReadHistory(lastRead: "1.0"), "C2": SlackReadHistory(lastRead: "2.0")])
        let merged = SlackReadState(channels: ["C1": SlackReadHistory(lastRead: "9.0")]).merged(over: old)
        check(merged.channels["C1"]?.lastRead == "9.0" && merged.channels["C2"]?.lastRead == "2.0", "\(merged)")
    }),

    ("the client reads one history and info per channel and replies per thread, leaves failures out and stops when rate limited", {
        let calls = Calls()
        let client = SlackClient(token: "xoxp-fake", transport: fake(calls) { method, parameters in
            switch (method, parameters["channel"]) {
            case ("conversations.history", "C0DEV"): return (200, historyFixture, nil)
            case ("conversations.info", "C0DEV"): return (200, infoFixture("C0DEV", unread: nil, lastRead: ts(40), latest: nil), nil)
            case ("conversations.history", "C0OPS"): return (200, Data(#"{"ok":false,"error":"channel_not_found"}"#.utf8), nil)
            case ("conversations.replies", "C0DEV"): return (200, repliesFixture, nil)
            default: return (429, Data(), "30")
            }
        })
        let mentions = [mention("C0DEV", ts(50)), mention("C0OPS", ts(60)), mention("C0DEV", ts(2000), thread: ts(3000)), mention("C0RL", ts(70)),
                        mention("C0LAST", ts(80))]
        nonisolated(unsafe) var result: (mentions: [SlackMessage], state: SlackReadState)?
        try blocking { result = await client.annotate(mentions, me: "U0ME", marks: [:]) }
        check(result?.mentions.map(\.handled) == [.read, nil, .postedAfter, nil, nil], "\(String(describing: result?.mentions.map(\.handled)))")
        check(result?.state.channels.keys.sorted() == ["C0DEV"], "failures left out")
        check(calls.methods.filter { $0 == "conversations.history C0DEV" }.count == 1, "one history per channel: \(calls.methods)")
        check(!calls.methods.contains { $0.contains("C0LAST") || $0.hasPrefix("conversations.replies") }, "stopped after the rate limit: \(calls.methods)")
    }),
]
