import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = ISO8601DateFormatter().date(from: "2026-11-12T11:00:00Z")!
private let stockholm = TimeZone(identifier: "Europe/Stockholm")!
private let anna = CalendarAttendee(name: "Anna Berg", email: "anna@gaia.example")

private final class Received: @unchecked Sendable {
    var requests: [BriefRequest] = []
}

private func event(_ id: String = "e1", title: String = "Gaia sync", in minutes: Double = 8, length: Double = 30, people: [CalendarAttendee] = [anna],
                   url: String? = nil, notes: String? = nil) -> CalendarEventInfo {
    CalendarEventInfo(id: id, title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                      attendees: people, notes: notes, url: url)
}

private func due(_ events: [CalendarEventInfo], lead: Int = 10, recording: Bool = false, briefed: Set<String> = []) -> [String] {
    MeetingBriefLogic.due(events, now: now, lead: lead, recording: recording, briefed: briefed).map(\.id)
}

private func sampleBrief() -> MeetingBrief {
    var last = PastMeeting(id: 1, title: "Gaia-exporten blir CSV", date: now.addingTimeInterval(-7 * 86400))
    last.decisions = ["Exporten går som CSV.", "Excel väntar till Q1.", "Anna testar.", "Fjärde."]
    last.openItems = ["Anna: Testa exporten", "Skriva release notes"]
    var older = PastMeeting(id: 2, title: "Release", date: now.addingTimeInterval(-14 * 86400))
    older.openItems = ["Bo: Boka demo"]
    return MeetingBrief(event: event(notes: "Agenda"), earlier: [last, older],
                        tickets: [.init(key: "QDLY-9031", summary: "Export invoices", status: "In Review", assignee: "Niklas")],
                        pullRequests: [.init(repo: "quiddly-com/finq.api", number: 2688, title: "Export as CSV", state: "Open", checks: "Checks passed", review: "Approved")],
                        agenda: "1. CSV status\n2. Search")
}

let meetingBriefTests: [(name: String, run: () throws -> Void)] = [
    ("brief: only real meetings starting within the lead time qualify", {
        check(due([event()]) == ["e1"], "inside the window")
        check(due([event(in: 12)]) == [], "too early for 10")
        check(due([event(in: 12)], lead: 15) == ["e1"], "inside 15")
        check(due([event(in: 0.5)]) == ["e1"], "app started late, still ahead")
        check(due([event(in: -1)]) == [], "already started")
        check(due([event(people: [])]) == [], "alone, no call link")
        check(due([event(people: [], url: "https://meet.google.com/abc-defg-hij")]) == ["e1"], "call link without attendees")
        check(due([event(people: [], notes: "Join: https://us02web.zoom.us/j/123456")]) == ["e1"], "link in the notes")
        var allDay = event(), declined = event(), cancelled = event()
        allDay.isAllDay = true
        declined.declined = true
        cancelled.cancelled = true
        check(due([allDay, declined, cancelled]) == [], "all-day, declined, cancelled")
        check(due([event()], recording: true) == [], "while recording")
        check(due([event("b", in: 9), event("a", in: 3)]) == ["a", "b"], "soonest first")
    }),

    ("brief: one brief per occurrence, kept across restarts and pruned after two weeks", {
        let first = event("series", in: 5)
        let nextWeek = CalendarEventInfo(id: "series", title: "Gaia sync", start: first.start.addingTimeInterval(7 * 86400),
                                         end: first.end.addingTimeInterval(7 * 86400), attendees: [anna])
        check(MeetingBriefLogic.key(first) != MeetingBriefLogic.key(nextWeek), "the start tells occurrences apart")
        check(due([first], briefed: [MeetingBriefLogic.key(first)]) == [], "already briefed")
        let stored = MeetingBriefLogic.encode([MeetingBriefLogic.key(first): first.start, "old|1": now.addingTimeInterval(-15 * 86400)])
        let loaded = MeetingBriefLogic.decodeBriefed(stored)
        check(loaded.count == 2 && MeetingBriefLogic.decodeBriefed(nil).isEmpty && MeetingBriefLogic.decodeBriefed(Data("x".utf8)).isEmpty, "round trip")
        check(Set(MeetingBriefLogic.pruned(loaded, now: now).keys) == [MeetingBriefLogic.key(first)], "pruned")
    }),

    ("brief: the setting defaults on only with calendar access, and the lead is 5, 10 or 15", {
        let defaults = UserDefaults(suiteName: "brief-\(UUID().uuidString)")!
        check(!MeetingBriefLogic.isEnabled(hasAccess: false, defaults: defaults) && MeetingBriefLogic.isEnabled(hasAccess: true, defaults: defaults), "default")
        defaults.set(false, forKey: MeetingBriefLogic.enabledKey)
        check(!MeetingBriefLogic.isEnabled(hasAccess: true, defaults: defaults), "off stays off")
        check(MeetingBriefLogic.lead(defaults: defaults) == 10, "default lead")
        defaults.set(15, forKey: MeetingBriefLogic.leadKey)
        check(MeetingBriefLogic.lead(defaults: defaults) == 15, "15")
        defaults.set(7, forKey: MeetingBriefLogic.leadKey)
        check(MeetingBriefLogic.lead(defaults: defaults) == 10, "unknown value")
    }),

    ("brief: meeting_brief picks the named meeting, else the next one today", {
        let events = [event("past", in: -90, length: 30), event("soon", title: "Standup", in: 20), event("later", title: "Gaia review", in: 120),
                      event("tomorrow", title: "Planning", in: 24 * 60)]
        func pick(_ query: String?, _ events: [CalendarEventInfo] = events) -> String? {
            MeetingBriefLogic.pick(events, query: query, now: now, timeZone: stockholm)?.id
        }
        check(pick(nil) == "soon", "next today")
        check(pick("gaia") == "later", "title part")
        check(pick("tomorrow") == "tomorrow", "id")
        check(pick("planning") == "tomorrow", "later days by name")
        check(pick("nothing") == nil, "no match")
        check(pick(nil, Array(events.suffix(1))) == nil, "none left today")
    }),

    ("brief: sections list who, last time's decisions, open items, tickets, pull requests and the agenda", {
        let sections = MeetingBriefLogic.sections(sampleBrief())
        check(sections.map(\.kind) == [.people, .lastTime, .open, .ticket, .pullRequest, .agenda], "\(sections.map(\.kind))")
        check(sections[1].lines == ["Exporten går som CSV.", "Excel väntar till Q1.", "Anna testar."], "three decisions")
        check(sections[2].lines.count == 3 && sections[2].lines[2].hasPrefix("Bo: Boka demo"), "open items from every earlier meeting: \(sections[2].lines)")
        let text = MeetingBriefLogic.text(sampleBrief(), timeZone: stockholm)
        check(text.hasPrefix("Gaia sync, 12:08\u{2013}12:38\n"), text)
        check(text.contains("\u{2022} With: Anna Berg") && text.contains("QDLY-9031: Export invoices \u{00B7} In Review \u{00B7} Niklas")
              && text.contains("finq.api#2688: Export as CSV \u{00B7} Open \u{00B7} Checks passed \u{00B7} Approved"), text)
        var withAim = sampleBrief()
        withAim.focus = "Confirm the CSV format."
        check(MeetingBriefLogic.text(withAim, timeZone: stockholm).hasSuffix("\u{2022} Aim: Confirm the CSV format.\n"), "aim last")
    }),

    ("brief: an empty brief is only who and when, and skipped when no one else is invited", {
        let bare = MeetingBrief(event: event())
        check(MeetingBriefLogic.isEmpty(bare) && MeetingBriefLogic.worthShowing(bare), "attendees: who and when")
        check(MeetingBriefLogic.sections(bare).map(\.kind) == [.people], "only who")
        let call = MeetingBrief(event: event(people: [], url: "https://meet.google.com/abc-defg-hij"))
        check(!MeetingBriefLogic.worthShowing(call), "link only")
        check(MeetingBriefLogic.text(call, timeZone: stockholm).contains("Nothing to prepare"), "says so for meeting_brief")
        check(MeetingBriefLogic.worthShowing(MeetingBrief(event: event(people: []), agenda: "Budget")), "an agenda is enough")
    }),

    ("brief: the notification says how long, with the first lines as its body", {
        check(MeetingBriefLogic.notificationTitle(event(in: 8.2), now: now) == "Gaia sync in 9 min", "rounded up")
        check(MeetingBriefLogic.notificationTitle(event(in: 0.2), now: now) == "Gaia sync in 1 min", "at least one")
        let body = MeetingBriefLogic.notificationBody(sampleBrief())
        check(body.components(separatedBy: "\n").count == 3 && body.hasPrefix("With: Anna Berg\nLast time"), body)
        check(body.count <= 220, "short")
    }),

    ("brief: the aim from Ministral is read from its JSON, and nothing else is trusted", {
        check(MeetingBriefPrompts.parse("{\"aim\": \" Agree on CSV. \"}") == "Agree on CSV.", "parsed")
        check(MeetingBriefPrompts.parse("{\"aim\": \"\"}") == nil && MeetingBriefPrompts.parse("no json") == nil, "empty and not JSON")
        check(MeetingBriefPrompts.aim(sampleBrief()).prompt.contains("Gaia sync"), "prompt holds the brief")
    }),

    ("brief: earlier meetings are matched by the in-call retrieval, with the invitation's tickets as entities", {
        let series = PastMeeting(id: 1, title: "Gaia sync", date: now.addingTimeInterval(-7 * 86400), attendees: ["anna@gaia.example"], seriesID: "s")
        let other = PastMeeting(id: 2, title: "Lunch", date: now.addingTimeInterval(-1 * 86400))
        var invite = event()
        invite.seriesID = "s"
        check(InCallRetrieval.rank([other, series], context: MeetingBriefLogic.context(invite, entities: [], now: now)).map(\.id) == [1], "series match only")
        var mentioned = other
        mentioned.mentions = ["ticket:QDLY-9031"]
        let seeds = [SpottedEntity(kind: .ticket, key: "QDLY-9031")]
        check(InCallRetrieval.rank([mentioned], context: MeetingBriefLogic.context(event(title: "x"), entities: seeds, now: now)).map(\.id) == [2], "shared ticket")
    }),

    ("brief: meeting_brief hands the request to the app and puts the event filter in the header", {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let sources = MCPServer.NoticeSources(file: root.appendingPathComponent(NoticeLogic.fileName), inbox: inbox, replyTimeout: 3, timeZone: stockholm,
                                              source: { NoticeSource(session: "s1", cwd: "/x") })
        let tools = MCPServer.briefTools(sources: sources, now: { now })
        check(tools.map(\.name) == ["meeting_brief"] && tools[0].readOnly && MCPServer.toolNames.contains("meeting_brief"), "listed, read only")
        let received = Received()
        let app = Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
                if let name = names.first(where: MeetingBriefLogic.isRequest), let data = try? Data(contentsOf: inbox.appendingPathComponent(name)),
                   let request = AgentInbox.decode(BriefRequest.self, from: data) {
                    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
                    received.requests.append(request)
                    try? AgentInbox.encode(NoticeReply(id: request.id, ok: true, notice: nil, message: "Gaia sync, 12:08\u{2013}12:38\n"))
                        .write(to: inbox.appendingPathComponent(AgentInbox.replyName(request.id)))
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        app.start()
        let answer = try tools[0].run(["event": " gaia "])
        check(answer == "Filtered by event \u{201C}gaia\u{201D}\nGaia sync, 12:08\u{2013}12:38\n", answer)
        check(received.requests.first?.event == "gaia", "trimmed event sent")
    }),
]
