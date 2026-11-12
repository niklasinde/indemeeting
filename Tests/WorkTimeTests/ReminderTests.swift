import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let stockholm = TimeZone(identifier: "Europe/Stockholm")!
private let now = ISO8601DateFormatter().date(from: "2026-11-12T09:00:00Z")!
private let reviewer = NoticeSource(agent: "assistant:work:reviewer", workspace: "work")
private let lists = [TodoList(id: "work", title: "Work", source: "Exchange"), TodoList(id: "home", title: "Home", source: "iCloud")]

private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private final class FakeReminders: ReminderStore, @unchecked Sendable {
    var access = TodoAccess.granted
    var lists = [TodoList]()
    var defaultListID: String? = "home"
    var items: [AgentReminder] = []

    init(lists: [TodoList]) { self.lists = lists }

    func requestAccess() async -> Bool { access == .granted }
    func todos(in list: String) async throws -> [TodoItem] { [] }
    func addTodo(_ text: String, to list: String) throws {}
    func delete(_ id: String) throws { items.removeAll { $0.id == id } }
    func complete(_ id: String) throws {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].completed = true }
    }
    func reminders(in lists: [String]?) async throws -> [AgentReminder] {
        items.filter { !$0.completed && (lists?.contains($0.list) ?? true) }
    }
    func reminder(_ id: String) -> AgentReminder? { items.first { $0.id == id } }
    func add(_ reminder: AgentReminder) throws -> String {
        var saved = reminder
        saved.id = "r\(items.count + 1)"
        items.append(saved)
        return saved.id
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private func waiting<T>(_ work: @escaping () async -> T) -> T {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await work()
        done.signal()
    }
    done.wait()
    return box.value!
}

private func request(_ action: ReminderRequest.Action, draft: ReminderDraft? = nil, list: String? = nil, dueBefore: Date? = nil,
                     reminder: String? = nil, created: Date = now) -> ReminderRequest {
    ReminderRequest(id: UUID().uuidString, action: action, draft: draft, list: list, dueBefore: dueBefore, reminder: reminder,
                    source: reviewer, created: created)
}

private func handle(_ request: ReminderRequest, store: FakeReminders?, stored: String? = nil, jiraSite: String? = nil) -> NoticeReply {
    waiting { await ReminderLogic.handle(request, store: store, stored: stored, addedBy: "Reviewer", jiraSite: jiraSite, now: now, timeZone: stockholm) }
}

private func draft(_ args: [String: Any]) -> Result<ReminderDraft, NoticeError> {
    ReminderLogic.draft(args, now: now, timeZone: stockholm)
}

let reminderTests: [(name: String, run: () throws -> Void)] = [
    ("reminders: due is read as notify's at, and a date alone is an all-day due date from today on", {
        func due(_ text: String) -> Result<ReminderDue, NoticeError> { ReminderLogic.due(text, now: now, timeZone: stockholm) }
        check((try? due("13:15").get()) == ReminderDue(date: utc("2026-11-12T12:15:00Z")), "HH:mm today with a time")
        check((try? due("2026-11-13T09:00").get()) == ReminderDue(date: utc("2026-11-13T08:00:00Z")), "ISO local")
        check((try? due("2026-11-13").get()) == ReminderDue(date: utc("2026-11-12T23:00:00Z"), allDay: true), "a day, Stockholm midnight")
        check((try? due("2026-11-12").get())?.allDay == true, "today is fine for a day")
        func problem(_ text: String) -> String {
            if case .failure(let error) = due(text) { return error.message }
            return ""
        }
        check(problem("2026-11-11") == "due 2026-11-11 is in the past.", problem("2026-11-11"))
        check(problem("2026-12-20").contains("30 days"), problem("2026-12-20"))
        check(problem("2026-11-12T08:00").hasPrefix("due 2026-11-12T08:00 is in the past"), problem("2026-11-12T08:00"))
        check(problem("someday").hasPrefix("due must be an ISO 8601"), problem("someday"))
        check((try? ReminderLogic.dueBefore("2026-11-13", now: now, timeZone: stockholm).get()) == utc("2026-11-13T23:00:00Z"), "a day counts in full")
        check((try? ReminderLogic.dueBefore("2026-11-01T10:00", now: now, timeZone: stockholm).get()) == utc("2026-11-01T09:00:00Z"), "past is fine")
        check((try? ReminderLogic.dueBefore("whenever", now: now, timeZone: stockholm).get()) == nil, "unreadable")
    }),

    ("reminders: add_reminder's arguments become a draft, with the link and priority checked", {
        let made = try draft(["title": " Review the PR ", "notes": "Before standup", "due": "2026-11-13", "list": "Work",
                              "link": "acme/api#7", "priority": "HIGH"]).get()
        check(made == ReminderDraft(title: "Review the PR", notes: "Before standup", due: ReminderDue(date: utc("2026-11-12T23:00:00Z"), allDay: true),
                                    list: "Work", link: "acme/api#7", priority: .high), "\(made)")
        check(try draft(["title": "x"]).get() == ReminderDraft(title: "x"), "only a title")
        for link in ["https://github.com/acme/api/pull/7", "QDLY-1234", "https://acme.atlassian.net/browse/QDLY-1", "https://example.com/a"] {
            check((try? draft(["title": "x", "link": link]).get()) != nil, link)
        }
        for bad: [String: Any] in [[:], ["title": " "], ["title": String(repeating: "a", count: 200)], ["title": "x", "priority": "urgent"],
                                   ["title": "x", "link": "main:work"], ["title": "x", "link": "ftp://x"], ["title": "x", "due": "yesterday"],
                                   ["title": "x", "notes": String(repeating: "a", count: 1001)]] {
            check((try? draft(bad).get()) == nil, "refused: \(bad)")
        }
    }),

    ("reminders: links become urls, a Jira key only with the site set up, and the notes name the link and the sender", {
        check(ReminderLogic.url("acme/api#7", jiraSite: nil)?.absoluteString == "https://github.com/acme/api/pull/7", "pr ref")
        check(ReminderLogic.url("QDLY-1", jiraSite: "acme.atlassian.net")?.absoluteString == "https://acme.atlassian.net/browse/QDLY-1", "jira")
        check(ReminderLogic.url("QDLY-1", jiraSite: nil) == nil, "no site")
        check(ReminderLogic.url("https://example.com/a", jiraSite: nil)?.absoluteString == "https://example.com/a", "web")
        check(ReminderLogic.notes("Do it", link: "QDLY-1", addedBy: "Main \u{00B7} work") == "Do it\nQDLY-1\nAdded by Main \u{00B7} work", "notes")
        check(ReminderLogic.notes(nil, link: nil, addedBy: "Claude Code \u{00B7} api") == "Added by Claude Code \u{00B7} api", "only the sender")
        check(ReminderPriority(eventKit: ReminderPriority.high.eventKit) == .high && ReminderPriority(eventKit: 0) == .none
              && ReminderPriority(eventKit: 7) == .low, "EventKit priorities")
    }),

    ("reminders: a list by name in any case, else the notch bar's list, else the default; unknown names list the choices", {
        func list(_ name: String?, stored: String? = nil, defaultID: String? = "home") -> String {
            switch ReminderLogic.list(named: name, in: lists, stored: stored, defaultID: defaultID) {
            case .success(let found): return found.id
            case .failure(let error): return error.message
            }
        }
        check(list("work") == "work", "by name")
        check(list("Groceries") == "No Reminders list named Groceries. The lists are: Work, Home.", list("Groceries"))
        check(list(nil, stored: "work") == "work", "the notch bar's list")
        check(list(nil, stored: TodoLogic.allLists) == "home", "All shown: the default list")
        check(list(nil, stored: "gone") == "home" && list(nil, defaultID: nil) == "work", "default, else the first")
        if case .success = ReminderLogic.list(named: nil, in: [], stored: nil, defaultID: nil) { check(false, "no lists") }
    }),

    ("reminders: an open one with the same title and due in the same list is a duplicate", {
        let at = utc("2026-11-12T12:15:00Z")
        let open = [AgentReminder(id: "a", title: "Review PR", list: "work", due: ReminderDue(date: at)),
                    AgentReminder(id: "b", title: "Call", list: "work", due: ReminderDue(date: utc("2026-11-12T23:00:00Z"), allDay: true)),
                    AgentReminder(id: "c", title: "Done", list: "work", completed: true)]
        func duplicate(_ title: String, list: String = "work", due: ReminderDue? = nil) -> String? {
            ReminderLogic.duplicate(of: AgentReminder(title: title, list: list, due: due), in: open, timeZone: stockholm)?.id
        }
        check(duplicate("review pr", due: ReminderDue(date: at.addingTimeInterval(20))) == "a", "same minute, any case")
        check(duplicate("Review PR", due: ReminderDue(date: at.addingTimeInterval(3600))) == nil, "another time")
        check(duplicate("Review PR", list: "home", due: ReminderDue(date: at)) == nil, "another list")
        check(duplicate("Review PR") == nil, "no due against a due one")
        check(duplicate("Call", due: ReminderDue(date: utc("2026-11-13T10:00:00Z"), allDay: true)) == "b", "same day")
        check(duplicate("Call", due: ReminderDue(date: utc("2026-11-13T10:00:00Z"))) == nil, "a time is not all day")
        check(duplicate("Done") == nil, "a completed one is not")
    }),

    ("reminders: the app adds, dedupes, lists and completes, and says why when it cannot", {
        let store = FakeReminders(lists: lists)
        let review = ReminderDraft(title: "Review", notes: "Soon", due: ReminderDue(date: utc("2026-11-12T12:15:00Z")), link: "QDLY-9", priority: .medium)
        let added = handle(request(.add, draft: review), store: store, stored: "work", jiraSite: "acme.atlassian.net")
        check(added.ok && added.notice == "r1" && added.message == "Added \"Review\" to Work, due 2026-11-12 13:15; id r1.", added.message)
        check(store.items.first == AgentReminder(id: "r1", title: "Review", list: "work", due: review.due, link: "https://acme.atlassian.net/browse/QDLY-9",
                                                 notes: "Soon\nhttps://acme.atlassian.net/browse/QDLY-9\nAdded by Reviewer", priority: .medium),
              "\(String(describing: store.items.first))")
        let again = handle(request(.add, draft: ReminderDraft(title: "review", due: review.due)), store: store, stored: "work")
        check(again.ok && again.notice == "r1" && again.message.contains("not added again") && store.items.count == 1, again.message)
        check(handle(request(.add, draft: ReminderDraft(title: "Review", due: review.due, list: "Home")), store: store).notice == "r2", "other list")
        check(handle(request(.add, draft: ReminderDraft(title: "x", list: "Nope")), store: store).message.contains("The lists are: Work, Home"), "unknown list")
        _ = handle(request(.add, draft: ReminderDraft(title: "Someday")), store: store, stored: "work")

        let all = handle(request(.list), store: store).message
        check(all == "- id r1 \u{00B7} Work \u{00B7} Review \u{00B7} due 2026-11-12 13:15 \u{00B7} medium priority \u{00B7} https://acme.atlassian.net/browse/QDLY-9\n"
              + "- id r2 \u{00B7} Home \u{00B7} Review \u{00B7} due 2026-11-12 13:15\n- id r3 \u{00B7} Work \u{00B7} Someday\n", all)
        check(handle(request(.list, list: "work", dueBefore: utc("2026-11-13T00:00:00Z")), store: store).message.hasPrefix("- id r1") , "filtered")
        check(handle(request(.list, dueBefore: utc("2026-11-12T10:00:00Z")), store: store).message == "No open reminders.\n", "none due yet")

        check(handle(request(.complete, reminder: "r1"), store: store).message == "Completed \"Review\" in Work.", "completed")
        check(handle(request(.complete, reminder: "r1"), store: store).message.contains("already completed"), "twice")
        check(!handle(request(.complete, reminder: "nope"), store: store).ok, "unknown id")

        store.access = .unknown
        check(handle(request(.list), store: store).message.contains("has not been given Reminders access"), "not asked yet")
        store.access = .denied
        check(handle(request(.list), store: store).message.contains("System Settings"), "denied")
        check(handle(request(.list), store: nil).message == "WorkTime has not opened Reminders yet.", "no store")
        check(handle(request(.list, created: now.addingTimeInterval(-600)), store: store).message == "The request is too old.", "stale")
    }),

    ("reminders: the MCP tools hand requests to the app, which answers from Reminders", {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reminders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let claude = NoticeSource(session: "s1", cwd: "/Users/me/git/api")
        let sources = MCPServer.NoticeSources(file: root.appendingPathComponent(NoticeLogic.fileName), inbox: inbox, replyTimeout: 3,
                                              timeZone: stockholm, source: { claude })
        let tools = MCPServer.reminderTools(sources: sources, now: { now })
        check(tools.map(\.name) == ["add_reminder", "reminders", "complete_reminder"] && tools.map(\.readOnly) == [false, true, false], "\(tools.map(\.name))")
        check(tools.map(\.name).allSatisfy(MCPServer.toolNames.contains), "listed")
        func run(_ name: String, _ args: [String: Any] = [:]) -> Result<String, Error> {
            Result { try tools.first { $0.name == name }!.run(args) }
        }
        let store = FakeReminders(lists: lists)
        let received = Box<[ReminderRequest]>()
        received.value = []
        let app = Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
                if let name = names.first(where: ReminderLogic.isRequest),
                   let data = try? Data(contentsOf: inbox.appendingPathComponent(name)),
                   let request = AgentInbox.decode(ReminderRequest.self, from: data) {
                    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
                    received.value?.append(request)
                    let reply = waiting {
                        await ReminderLogic.handle(request, store: store, stored: nil, addedBy: request.source.label(titles: [:]), jiraSite: nil,
                                                   now: now, timeZone: stockholm)
                    }
                    try? AgentInbox.encode(reply).write(to: inbox.appendingPathComponent(AgentInbox.replyName(request.id)))
                    if request.action == .complete { return }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        app.start()
        let added = (try? run("add_reminder", ["title": "Merge it", "due": "2026-11-13", "link": "https://github.com/acme/api/pull/7"]).get()) ?? ""
        check(added == "Added \"Merge it\" to Home, due 2026-11-13; id r1.", added)
        check(received.value?.first?.source == claude && received.value?.first?.draft?.due?.allDay == true, "request")
        check(store.items.first?.notes == "https://github.com/acme/api/pull/7\nAdded by Claude Code \u{00B7} api", "\(String(describing: store.items.first?.notes))")
        check((try? run("add_reminder", ["title": "x", "due": "yesterday"]).get()) == nil, "bad due refused before the app is asked")
        let listed = (try? run("reminders", ["due_before": "2026-11-13"]).get()) ?? ""
        check(listed.hasPrefix("- id r1 \u{00B7} Home \u{00B7} Merge it \u{00B7} due 2026-11-13"), listed)
        if case .failure(let error) = run("reminders", ["list": "Groceries"]) {
            check(error.localizedDescription.contains("The lists are: Work, Home"), error.localizedDescription)
        } else {
            check(false, "unknown list is an error")
        }
        check((try? run("complete_reminder", ["id": "r1"]).get()) == "Completed \"Merge it\" in Home.", "completed")

        let quiet = MCPServer.reminderTools(sources: MCPServer.NoticeSources(inbox: inbox, replyTimeout: 0.3, source: { claude }), now: { now })
        if case .failure(let error) = Result(catching: { try quiet[0].run(["title": "anyone?"]) }) {
            check(error.localizedDescription.contains("did not take the reminder") && error.localizedDescription.contains("Is the app running?"),
                  error.localizedDescription)
        } else {
            check(false, "no app, no success")
        }
        check(((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).isEmpty, "inbox cleaned up")
    }),
]
