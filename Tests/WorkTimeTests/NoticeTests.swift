import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let stockholm = TimeZone(identifier: "Europe/Stockholm")!
private let now = ISO8601DateFormatter().date(from: "2026-11-12T09:00:00Z")!
private let reviewer = NoticeSource(agent: "assistant:work:reviewer", workspace: "work")
private let claude = NoticeSource(session: "s1", cwd: "/Users/me/git/api")

private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func notice(_ id: String, _ title: String, source: NoticeSource = reviewer, body: String? = nil, created: TimeInterval = 0,
                    at: Date? = nil, state: AgentNotice.State? = nil) -> AgentNotice {
    AgentNotice(id: id, title: title, body: body, source: source, created: now.addingTimeInterval(created), at: at,
                state: state ?? (at == nil ? .shown : .scheduled))
}

private func time(_ text: String) -> Result<Date, NoticeError> { NoticeLogic.time(text, now: now, timeZone: stockholm) }

let noticeTests: [(name: String, run: () throws -> Void)] = [
    ("notify: at is ISO 8601 or HH:mm in local time, never in the past or more than 30 days out", {
        check((try? time("13:15").get()) == utc("2026-11-12T12:15:00Z"), "HH:mm today, Stockholm time")
        check((try? time("09:30").get()) == utc("2026-11-13T08:30:00Z"), "HH:mm already past is tomorrow")
        check((try? time("2026-11-12T13:15").get()) == utc("2026-11-12T12:15:00Z"), "ISO without offset is local")
        check((try? time("2026-11-12 13:15").get()) == utc("2026-11-12T12:15:00Z"), "a space instead of T")
        check((try? time("2026-11-12T13:15:00+02:00").get()) == utc("2026-11-12T11:15:00Z"), "offset kept")
        check((try? time("2026-11-12T12:15:00.500Z").get()) == utc("2026-11-12T12:15:00Z").addingTimeInterval(0.5), "fractional seconds")
        func problem(_ text: String) -> String {
            if case .failure(let error) = time(text) { return error.message }
            return ""
        }
        check(problem("2026-11-11T13:00").contains("in the past"), problem("2026-11-11T13:00"))
        check(problem("2026-12-20T10:00").contains("30 days"), problem("2026-12-20T10:00"))
        check(problem("soon").contains("ISO 8601"), problem("soon"))
        check(problem("25:00").contains("ISO 8601"), "no hour 25")
    }),

    ("notify: arguments become a notification, with the link and urgency checked", {
        let made = try NoticeLogic.notice(["title": " Meeting at 13:15 ", "body": "Standup", "at": "13:15", "urgency": "HIGH",
                                           "link": "https://github.com/acme/api/pull/7"], source: reviewer, now: now, timeZone: stockholm, id: "n1").get()
        check(made.title == "Meeting at 13:15" && made.state == .scheduled && made.urgency == .high && made.at == utc("2026-11-12T12:15:00Z"),
              "\(made)")
        check(try NoticeLogic.notice(["title": "Now"], source: reviewer, now: now).get().state == .shown, "no at: shown now")
        for bad: [String: Any] in [[:], ["title": "  "], ["title": "x", "urgency": "panic"], ["title": "x", "link": "ftp://x"],
                                   ["title": String(repeating: "a", count: 200)], ["title": "x", "at": "yesterday"]] {
            check((try? NoticeLogic.notice(bad, source: reviewer, now: now).get()) == nil, "refused: \(bad)")
        }
    }),

    ("notify: links open a pull request, an agent, a Jira ticket or a web page", {
        check(NoticeLogic.link("https://github.com/acme/api/pull/7") == .pullRequest(GitHubLink.Target(repo: "acme/api", number: 7)), "pr")
        check(NoticeLogic.link("main:work") == .agent("main:work"), "main")
        check(NoticeLogic.link("QDLY-1234") == .jira("QDLY-1234"), "jira key")
        check(NoticeLogic.link("https://acme.atlassian.net/browse/QDLY-1") == .web(URL(string: "https://acme.atlassian.net/browse/QDLY-1")!), "jira url")
        check(NoticeLogic.link("https://acme.slack.com/archives/C1/p123") != nil, "slack permalink")
        check(NoticeLogic.link("http://example.com") == nil && NoticeLogic.link("hello world") == nil, "not https")
    }),

    ("notify: repeats within a minute collapse, scheduled ones with the same title and time are replaced, ten a minute at most", {
        let first = notice("a", "Build failed", body: "main")
        check(NoticeLogic.admit(notice("b", "Build failed", body: "main", created: 30), existing: [first], recent: [first],
                                now: now.addingTimeInterval(30)) == .collapse("a"), "same title and body collapse")
        check(NoticeLogic.admit(notice("b", "Build failed", body: "main", created: 61), existing: [first], recent: [first],
                                now: now.addingTimeInterval(61)) == .add, "a minute later it shows again")
        check(NoticeLogic.admit(notice("b", "Build failed", source: claude, body: "main"), existing: [first], recent: [first], now: now) == .add,
              "another source is not collapsed")
        check(NoticeLogic.admit(notice("b", "Build failed", body: "other"), existing: [first], recent: [first], now: now) == .add, "another body")
        let at = utc("2026-11-12T12:15:00Z")
        let meeting = notice("m", "Standup", at: at)
        check(NoticeLogic.admit(notice("m2", "Standup", at: at), existing: [meeting], recent: [], now: now) == .replace("m"), "same time replaces")
        check(NoticeLogic.admit(notice("m2", "Standup", at: at.addingTimeInterval(60)), existing: [meeting], recent: [], now: now) == .add,
              "another time")
        check(NoticeLogic.admit(notice("m2", "Standup", source: claude, at: at), existing: [meeting], recent: [], now: now) == .add, "another source")
        let flood = (0..<10).map { notice("f\($0)", "Thing \($0)", created: Double($0)) }
        if case .reject(let message) = NoticeLogic.admit(notice("x", "One more", created: 20), existing: [], recent: flood,
                                                           now: now.addingTimeInterval(20)) {
            check(message.contains("last minute"), message)
        } else {
            check(false, "the eleventh in a minute is refused")
        }
        check(NoticeLogic.admit(notice("x", "One more", source: claude), existing: [], recent: flood, now: now) == .add, "counted per source")
    }),

    ("notify: due ones fire, ones more than ten minutes late are missed, later ones wait", {
        let notices = [notice("soon", "a", at: now.addingTimeInterval(-60)), notice("old", "b", at: now.addingTimeInterval(-3600)),
                       notice("later", "c", at: now.addingTimeInterval(600)), notice("shown", "d", at: now.addingTimeInterval(-60), state: .shown)]
        let due = NoticeLogic.due(notices, now: now)
        check(due.fire == ["soon"] && due.missed == ["old"], "\(due)")
    }),

    ("notify: an agent cancels its own scheduled notification, a Main any, others none", {
        let notices = [notice("m", "Standup", at: now.addingTimeInterval(600)), notice("s", "Shown")]
        check(NoticeLogic.cancelProblem("m", in: notices, by: reviewer) == nil, "own")
        check(NoticeLogic.cancelProblem("m", in: notices, by: NoticeSource(agent: "main:work")) == nil, "main")
        check(NoticeLogic.cancelProblem("m", in: notices, by: claude)?.contains("only it or a Main") == true, "other")
        check(NoticeLogic.cancelProblem("s", in: notices, by: reviewer)?.contains("already been shown") == true, "shown")
        check(NoticeLogic.cancelProblem("nope", in: notices, by: reviewer)?.contains("No notification") == true, "unknown")
    }),

    ("notify: the source is the agent the sidecar names, else the Claude Code session and folder", {
        let agent = NoticeSource.current(environment: ["WORKTIME_AGENT": "topic:abc", "WORKTIME_WORKSPACE": "work", "CLAUDE_SESSION_ID": "s"], cwd: "/x")
        check(agent == NoticeSource(agent: "topic:abc", workspace: "work"), "\(agent)")
        let session = NoticeSource.current(environment: ["CLAUDE_SESSION_ID": "s"], cwd: "/Users/me/git/api")
        check(session == NoticeSource(session: "s", cwd: "/Users/me/git/api") && session.identity == "session:s", "\(session)")
        check(session.label(titles: [:]) == "Claude Code \u{00B7} api", session.label(titles: [:]))
        check(agent.label(titles: ["topic:abc": "Support case"]) == "Support case", "title from the agents")
        check(NoticeSource(agent: "https://github.com/acme/api/pull/7").label(titles: [:]) == "acme/api#7", "pr agent")
        check(NoticeSource(agent: "main:work").isMain && !reviewer.isMain, "main")
    }),

    ("notify: the MCP tools hand notifications to the app and list and cancel scheduled ones", {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(NoticeLogic.fileName), inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let sources = MCPServer.NoticeSources(file: file, inbox: inbox, replyTimeout: 3, timeZone: stockholm, source: { claude })
        let tools = MCPServer.noticeTools(sources: sources, now: { now })
        check(tools.map(\.name) == ["notify", "scheduled_notifications", "cancel_notification"], "\(tools.map(\.name))")
        check(["notify", "scheduled_notifications", "cancel_notification"].allSatisfy(MCPServer.toolNames.contains), "listed")
        func run(_ name: String, _ args: [String: Any] = [:]) -> Result<String, Error> {
            Result { try tools.first { $0.name == name }!.run(args) }
        }
        let received = Box()
        let app = Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
                if let name = names.first(where: NoticeLogic.isRequest),
                   let data = try? Data(contentsOf: inbox.appendingPathComponent(name)),
                   let request = AgentInbox.decode(NoticeRequest.self, from: data) {
                    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
                    received.requests.append(request)
                    let reply = NoticeReply(id: request.id, ok: true, notice: request.notice?.id ?? request.cancel, message: "Scheduled.")
                    try? AgentInbox.encode(reply).write(to: inbox.appendingPathComponent(AgentInbox.replyName(request.id)))
                    if request.action == .cancel { return }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        app.start()
        let sent = (try? run("notify", ["title": "Standup", "at": "13:15"]).get()) ?? ""
        check(sent.hasPrefix("Scheduled. It fires at 2026-11-12 13:15") && sent.contains("cancel_notification"), sent)
        check(received.requests.first?.notice?.at == utc("2026-11-12T12:15:00Z") && received.requests.first?.source == claude, "request")
        check((try? run("notify", ["title": "x", "at": "yesterday"]).get()) == nil, "bad time refused before the app is asked")

        let mine = notice("mine", "Standup", source: claude, at: utc("2026-11-12T12:15:00Z"))
        try NoticeLogic.encode([mine, notice("theirs", "Deploy", at: utc("2026-11-12T15:00:00Z")), notice("done", "Shown")]).write(to: file)
        let listed = (try? run("scheduled_notifications").get()) ?? ""
        check(listed.hasPrefix("- id mine \u{00B7} 2026-11-12 13:15 \u{00B7} Standup \u{00B7} from Claude Code \u{00B7} api") && listed.contains("id theirs")
              && !listed.contains("id done"), listed)
        if case .failure(let error) = run("cancel_notification", ["id": "theirs"]) {
            check(error.localizedDescription.contains("only it or a Main"), error.localizedDescription)
        } else {
            check(false, "another source's notification is not cancelled")
        }
        check((try? run("cancel_notification", ["id": "mine"]).get()) == "Scheduled.", "own cancelled through the app")
        check(received.requests.last?.cancel == "mine", "cancel request")

        let quiet = MCPServer.noticeTools(sources: MCPServer.NoticeSources(file: file, inbox: inbox, replyTimeout: 0.3, source: { claude }), now: { now })
        if case .failure(let error) = Result(catching: { try quiet[0].run(["title": "anyone?"]) }) {
            check(error.localizedDescription.contains("Is the app running?"), error.localizedDescription)
        } else {
            check(false, "no app, no success")
        }
        check(((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).isEmpty, "inbox cleaned up")
    }),
]

private final class Box: @unchecked Sendable {
    var requests: [NoticeRequest] = []
}
