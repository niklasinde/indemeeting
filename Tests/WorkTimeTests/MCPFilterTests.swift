import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let stockholm = TimeZone(identifier: "Europe/Stockholm")!
private let now = ISO8601DateFormatter().date(from: "2026-11-12T09:00:00Z")!

private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func failure<T>(_ result: () throws -> T) -> String {
    do { _ = try result() } catch { return error.localizedDescription }
    return ""
}

private func block(app: String = "Xcode", repo: String? = nil, branch: String? = nil, ticket: String? = nil, project: Int64? = nil,
                   category: ActivityCategory? = nil) -> ActivityBlock {
    ActivityBlock(id: 1, start: now, end: now.addingTimeInterval(600),
                  key: ActivityKey(appBundle: "com.apple.\(app)", appName: app, windowTitle: nil, url: nil, repo: repo, branch: branch, ticket: ticket,
                                   claude: [], idle: false, owner: repo == nil ? nil : "acme"),
                  projectID: project, category: category)
}

private func meeting(_ id: Int64, _ title: String, created: String, minutes: Double? = nil, app: String? = nil,
                     status: ProcessingStatus = .summarised) -> Meeting {
    Meeting(id: id, audioFile: "m\(id).m4a", created: utc(created), duration: minutes.map { $0 * 60 }, titleOverride: title, notes: "", status: status,
            source: app.map { MeetingSource(app: $0) })
}

private func state(_ key: String, status: AgentState.Status = .idle, pr: String? = nil, seen: Bool = true, result: String? = nil) -> AgentState {
    AgentState(key: key, title: key, prURL: pr, status: status, lastResult: result, seen: seen)
}

private func tool(_ tools: [MCPTool], _ name: String, _ args: [String: Any] = [:]) -> Result<String, Error> {
    Result { try tools.first { $0.name == name }!.run(args) }
}

let mcpFilterTests: [(name: String, run: () throws -> Void)] = [
    ("filters: choices, flags, minutes and dates are read the same way everywhere", {
        check(try FilterLogic.choice(["status": "FAILED"], "status", allowed: MeetingFilter.statuses) == "failed", "case-insensitive choice")
        check(failure { try FilterLogic.choice(["status": "x"], "status", allowed: ["a", "b"]) } == "status must be one of a, b, not x.", "allowed values named")
        check(try FilterLogic.flag(["f": "TRUE"], "f") == true && FilterLogic.flag([:], "f") == nil, "flag")
        check(!failure { try FilterLogic.flag(["f": 3], "f") }.isEmpty, "bad flag")
        check(!failure { try FilterLogic.minutes(["m": -1], "m") }.isEmpty, "negative minutes")
        check(try FilterLogic.bound(["since": "2026-11-10"], "since", end: false, now: now, timeZone: stockholm) == utc("2026-11-09T23:00:00Z"), "start of day")
        check(try FilterLogic.bound(["until": "2026-11-10"], "until", end: true, now: now, timeZone: stockholm) == utc("2026-11-10T23:00:00Z"), "end counts the day")
        check(failure { try FilterLogic.bound(["since": "soon"], "since", end: false, now: now) }.hasPrefix("since must be a date"), "bad date")
        check(FilterLogic.matches("Intrum AB", "intrum") && !FilterLogic.matches(nil, "x") && FilterLogic.matches(nil, nil), "matches")
        check(FilterLogic.header([]) == "" && FilterLogic.header(["repo \u{201C}api\u{201D}", "since 2026-11-01"]) == "Filtered by repo \u{201C}api\u{201D}, since 2026-11-01\n", "header")
    }),

    ("filters: meetings narrow by date, speaker, source, state, length, action items and text, all together", {
        let a = meeting(1, "Planning with Anna", created: "2026-11-02T09:00:00Z", minutes: 60, app: "Zoom")
        let b = meeting(2, "Standup", created: "2026-11-10T09:00:00Z", minutes: 10, app: "Google Meet", status: .failed)
        func filter(_ args: [String: Any]) throws -> MeetingFilter { try MeetingFilter(args, now: now, timeZone: stockholm) }
        func kept(_ args: [String: Any], speakers: [Int64: [String]] = [:], open: [Int64: Int] = [:]) throws -> [Int64] {
            let f = try filter(args)
            return [a, b].filter { f.matches($0, speakers: speakers[$0.id] ?? [], openActionItems: open[$0.id] ?? 0) }.map(\.id)
        }
        check(try kept([:]) == [1, 2], "no filter keeps all")
        check(try kept(["since": "2026-11-05"]) == [2] && kept(["until": "2026-11-02"]) == [1], "dates, until counts the day")
        check(try kept(["with": "anna"]) == [1] && kept(["with": "bo"], speakers: [2: ["Bo Berg"]]) == [2], "title or speaker")
        check(try kept(["source": "zoom"]) == [1] && kept(["status": "failed"]) == [2] && kept(["min_minutes": 30]) == [1], "source, status, length")
        check(try kept(["has_action_items": true], open: [2: 1]) == [2] && kept(["has_action_items": false], open: [2: 1]) == [1], "action items")
        check(try kept(["since": "2026-11-01", "source": "meet", "status": "failed"]) == [2] && kept(["source": "zoom", "status": "failed"]) == [], "combined")
        check(try filter(["since": "2026-11-01", "with": "Anna"]).applied == ["since \u{201C}2026-11-01\u{201D}", "with \u{201C}Anna\u{201D}"], "applied")
        check(failure { try filter(["status": "done"]) }.contains("none, summarised, unavailable, failed, stopped"), "status values named")
        check(failure { try filter(["since": "2026-11-10", "until": "2026-11-01"]) } == "since must be before until.", "order")
    }),

    ("filters: the meeting tools filter what the store holds", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("filters-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let first = "Meeting-2026-11-02-1000.m4a", second = "Meeting-2026-11-10-1000.m4a"
        let segments = [TranscriptSegment(start: 1, text: "Budget talk", speaker: .numbered(1))]
        try store.saveTranscript(first, segments: segments, language: .english, engine: "x", speakers: [SpeakerProfile(speaker: .numbered(1), name: "Anna Berg")])
        try store.saveTranscript(second, segments: segments, language: .english, engine: "x")
        try store.saveSummary(first, ParsedSummary(MeetingSummary(title: "Budget", actionItems: [.init(task: "Send it", owner: "Anna")], topics: [])))
        try store.saveSummary(second, ParsedSummary(MeetingSummary(title: "Retro", actionItems: [], topics: [])))
        let tools = MCPServer.meetingTools(.success(store), now: { now })
        let recent = (try? tool(tools, "recent_meetings", ["with": "anna"]).get()) ?? ""
        check(recent.hasPrefix("Filtered by with \u{201C}anna\u{201D}\n") && recent.contains("Budget") && !recent.contains("Retro"), recent)
        let open = (try? tool(tools, "recent_meetings", ["has_action_items": true]).get()) ?? ""
        check(open.contains("Budget") && !open.contains("Retro"), open)
        let found = (try? tool(tools, "search_meetings", ["query": "budget", "since": "2026-11-01", "until": "2026-11-05"]).get()) ?? ""
        check(found.hasPrefix("Filtered by since \u{201C}2026-11-01\u{201D}, until \u{201C}2026-11-05\u{201D}\n") && found.contains("Budget"), found)
        let none = (try? tool(tools, "search_meetings", ["query": "budget", "since": "2026-11-11"]).get()) ?? ""
        check(none.hasSuffix("No meetings match \u{201C}budget\u{201D}.\n"), none)
        check(failure { try tools.first { $0.name == "search_meetings" }!.run(["query": "x", "status": "?"]) }.contains("status must be one of"), "bad value")
        let plain = (try? tool(tools, "recent_meetings").get()) ?? ""
        check(!plain.contains("Filtered by") && plain.contains("Budget") && plain.contains("Retro"), "unchanged without filters")
    }),

    ("filters: activity blocks narrow by app, repository, branch, ticket, project and category", {
        let api = block(repo: "api", branch: "NI/QDLY-8296", ticket: nil, project: 1, category: .coding)
        let browser = block(app: "Chrome", ticket: "ISD-5", project: nil, category: .research)
        let projects = [Project(id: 1, name: "Quiddly", color: "#000")]
        func kept(_ args: [String: Any]) throws -> [Bool] {
            let filter = try ActivityFilter(args)
            return [api, browser].map { filter.matches($0, rules: [], projects: projects) }
        }
        check(try kept([:]) == [true, true], "no filter")
        check(try kept(["app": "chrome"]) == [false, true] && kept(["repo": "acme/api"]) == [true, false], "app, repo")
        check(try kept(["branch": "qdly"]) == [true, false] && kept(["ticket": "QDLY-8296"]) == [true, false] && kept(["ticket": "isd"]) == [false, true], "branch, ticket from the branch")
        check(try kept(["project": "quid"]) == [true, false] && kept(["project": "unassigned"]) == [false, true], "project")
        check(try kept(["category": "CODING"]) == [true, false] && kept(["app": "xcode", "category": "research/browsing"]) == [false, false], "category, combined")
        check(failure { try ActivityFilter(["category": "fun"]) }.contains("code review"), "categories named")
        check(try ActivityFilter(["repo": "api", "category": "coding"]).applied == ["repo \u{201C}api\u{201D}", "category \u{201C}coding\u{201D}"], "applied")
    }),

    ("filters: agents narrow by kind, status, need and text", {
        let pr = "https://github.com/acme/api/pull/7", topic = "topic:\(UUID().uuidString)"
        let agents = [state("main:work", result: "done"), state(pr, status: .waiting, pr: pr), state(topic), state("assistant:work:dev"),
                      state("https://github.com/acme/api/pull/8", pr: "https://github.com/acme/api/pull/8", seen: false, result: "fixed the build")]
        func kept(_ args: [String: Any]) throws -> [String] {
            let filter = try AgentFilter(args)
            return agents.filter(filter.matches).map(\.key)
        }
        check(try kept([:]).count == 5, "no filter")
        check(try kept(["kind": "main"]) == ["main:work"] && kept(["kind": "topic"]) == [topic] && kept(["kind": "assistant"]) == ["assistant:work:dev"], "kinds")
        check(try kept(["kind": "pr"]).count == 2, "pull request agents")
        check(try kept(["status": "waiting"]) == [pr], "status")
        check(try kept(["needs_me": true]).count == 2 && kept(["needs_me": false]).count == 3, "needs me: waiting or unseen result")
        check(try kept(["kind": "pr", "needs_me": true, "query": "BUILD"]) == ["https://github.com/acme/api/pull/8"], "combined with text")
        check(failure { try AgentFilter(["kind": "robot"]) } == "kind must be one of main, pr, topic, assistant, not robot.", "kinds named")
        check(try AgentFilter(["kind": "pr", "workspace": "work"], names: ["status"]).applied == [], "only the named arguments")
    }),

    ("filters: scheduled notifications and reminders narrow by sender, urgency, time, priority and text", {
        let claude = NoticeSource(session: "s1", cwd: "/Users/me/git/api")
        let reviewer = NoticeSource(agent: "assistant:work:reviewer", workspace: "work")
        let early = AgentNotice(id: "1", title: "Standup", body: "daily", urgency: .high, source: claude, created: now, at: utc("2026-11-12T11:00:00Z"), state: .scheduled)
        let late = AgentNotice(id: "2", title: "Deploy", source: reviewer, created: now, at: utc("2026-11-14T11:00:00Z"), state: .scheduled)
        func kept(_ args: [String: Any]) throws -> [String] {
            let filter = try NoticeFilter(args, now: now, timeZone: stockholm)
            return [early, late].filter(filter.matches).map(\.id)
        }
        check(try kept([:]) == ["1", "2"] && kept(["source": "reviewer"]) == ["2"] && kept(["source": "api"]) == ["1"], "source")
        check(try kept(["urgency": "high"]) == ["1"] && kept(["query": "daily"]) == ["1"], "urgency, text")
        check(try kept(["due_before": "2026-11-12"]) == ["1"] && kept(["due_after": "2026-11-13"]) == ["2"], "times")
        check(try kept(["due_after": "2026-11-12", "due_before": "2026-11-13", "urgency": "high"]) == ["1"], "combined")
        check(failure { try NoticeFilter(["urgency": "loud"], now: now) }.contains("normal, high"), "urgency values named")

        func reminder(_ title: String, due: String?, priority: ReminderPriority = .none, notes: String? = nil) -> AgentReminder {
            AgentReminder(id: title, title: title, due: due.map { ReminderDue(date: utc($0)) }, notes: notes, priority: priority)
        }
        let items = [reminder("Merge", due: "2026-11-12T10:00:00Z", priority: .high), reminder("Call", due: "2026-11-15T10:00:00Z", notes: "about Merge"),
                     reminder("Someday", due: nil)]
        func open(_ filter: ReminderFilter) -> [String] { ReminderLogic.open(items, filter: filter).map(\.title) }
        check(open(ReminderFilter()) == ["Merge", "Call", "Someday"], "no filter")
        check(open(ReminderFilter(dueBefore: utc("2026-11-13T00:00:00Z"))) == ["Merge"] && open(ReminderFilter(dueAfter: utc("2026-11-13T00:00:00Z"))) == ["Call"], "due window")
        check(open(ReminderFilter(priority: .high)) == ["Merge"] && open(ReminderFilter(query: "merge")) == ["Merge", "Call"], "priority, text in title or notes")
        check(open(ReminderFilter(dueAfter: utc("2026-11-01T00:00:00Z"), priority: .high, query: "merge")) == ["Merge"], "combined")
    }),

    ("filters: jira_search composes structured filters into JQL, quoted and escaped, and keeps raw JQL working", {
        func clauses(_ args: [String: Any]) throws -> [String] { try JQLFilter.clauses(args) }
        let open = "status = \"Open\""
        check(try clauses([:]) == [] && JQLFilter.compose(jql: " project = ISD ORDER BY created ", clauses: []) == "project = ISD ORDER BY created", "raw jql untouched")
        let some = try clauses(["assignee": "me", "status": "Open, In Review", "project": "ISD"])
        check(some == ["assignee in (currentUser())", "project = \"ISD\"", "status in (\"Open\", \"In Review\")"], "\(some)")
        check(try clauses(["assignee": "unassigned"]) == ["assignee is EMPTY"], "unassigned")
        check(try clauses(["text": #"say "hi" \ now"#]) == [#"text ~ "say \"hi\" \\ now""#], "escaped")
        check(try clauses(["updated_since": "2026-11-01", "updated_before": "-1d", "type": "Bug"]) == ["issuetype = \"Bug\"", "updated >= \"2026-11-01\"", "updated < \"-1d\""], "dates")
        check(failure { try clauses(["updated_since": "yesterday"]) }.hasPrefix("updated_since must be a date"), "bad date")
        let both = JQLFilter.compose(jql: "text ~ \"order by me\" OR key = A-1 ORDER BY created ASC", clauses: [open])
        check(both == "(text ~ \"order by me\" OR key = A-1) AND status = \"Open\" ORDER BY created ASC", both)
        check(JQLFilter.compose(jql: nil, clauses: [open]) == "status = \"Open\" ORDER BY updated DESC", JQLFilter.compose(jql: nil, clauses: [open]))
        check(JQLFilter.compose(jql: "project = A", clauses: [open]) == "(project = A) AND status = \"Open\"", "no order by")
    }),

    ("filters: slack_search composes channel, sender, days and attachments into Slack's modifiers", {
        let made = try SlackSearchFilter.modifiers(["channel": "#dev", "from": "@anna", "since": "2026-11-10", "until": "2026-11-12", "has": "Link"], now: now, timeZone: stockholm)
        check(made.terms == ["in:#dev", "from:@anna", "after:2026-11-09", "before:2026-11-13", "has:link"], "\(made.terms)")
        check(made.applied == ["channel \u{201C}#dev\u{201D}", "from \u{201C}@anna\u{201D}", "since \u{201C}2026-11-10\u{201D}", "until \u{201C}2026-11-12\u{201D}", "has \u{201C}link\u{201D}"], "\(made.applied)")
        check(try SlackSearchFilter.modifiers([:], now: now).terms == [], "none")
        check(failure { try SlackSearchFilter.modifiers(["channel": "a b"], now: now) }.hasPrefix("channel must be one name"), "spaces")
        check(failure { try SlackSearchFilter.modifiers(["since": "2026-11-12", "until": "2026-11-10"], now: now, timeZone: stockholm) } == "since must be before until.", "order")
        check(failure { try SlackSearchFilter.modifiers(["has": "gif"], now: now) }.contains("link, reaction, pin, star"), "values named")
    }),
]
