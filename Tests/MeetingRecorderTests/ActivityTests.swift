import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private let t0 = Date(timeIntervalSince1970: 1_792_300_000)

private func sample(_ offset: TimeInterval, app: String = "Xcode", title: String? = "MainWindow.swift", url: String? = nil,
                    repo: String? = nil, branch: String? = nil, ticket: String? = nil, claude: [ClaudeSession] = []) -> ActivitySample {
    ActivitySample(time: t0.addingTimeInterval(offset), appBundle: "com.\(app)", appName: app, windowTitle: title, url: url,
                   repo: repo, branch: branch, ticket: ticket, claude: claude)
}

private func block(_ start: TimeInterval, _ end: TimeInterval, app: String = "Xcode", title: String? = nil, url: String? = nil,
                   repo: String? = nil, branch: String? = nil, ticket: String? = nil, claude: [ClaudeSession] = [], idle: Bool = false,
                   project: Int64? = nil) -> ActivityBlock {
    ActivityBlock(id: Int64(start), start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
                  key: ActivityKey(appBundle: idle ? nil : "com.\(app)", appName: idle ? nil : app, windowTitle: title, url: url, repo: repo,
                                   branch: branch, ticket: ticket, claude: claude, idle: idle), projectID: project)
}

private func tempFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}

private let projects = [Project(id: 1, name: "Quiddly", color: "#5B8DEF"), Project(id: 2, name: "Inde", color: "#E0665C")]
private let rules = [ProjectRule(id: 1, projectID: 1, field: .repo, pattern: "finq.api"),
                     ProjectRule(id: 2, projectID: 1, field: .ticket, pattern: "QDLY"),
                     ProjectRule(id: 3, projectID: 2, field: .host, pattern: "indepower.se"),
                     ProjectRule(id: 4, projectID: 2, field: .app, pattern: "Xcode")]

let activityTests: [(name: String, run: () throws -> Void)] = [
    ("consecutive samples with the same fields collapse into one block", {
        var open: ActivityBlock?
        var closed: [ActivityBlock] = []
        for s in [sample(0), sample(5), sample(10), sample(15, title: "Other.swift"), sample(20, title: "Other.swift"), .idle(at: t0.addingTimeInterval(25))] {
            let result = ActivityLogic.collapse(open, with: s)
            if let done = result.closed { closed.append(done) }
            open = result.open
        }
        check(closed.count == 2, "two blocks closed, got \(closed.count)")
        check(closed[0].start == t0 && closed[0].end == t0.addingTimeInterval(15), "first block covers three samples \(closed[0])")
        check(closed[1].key.windowTitle == "Other.swift" && closed[1].duration == 10, "second block")
        check(open?.key.idle == true && open?.duration == 5, "idle block open")

        let gap = ActivityLogic.collapse(block(0, 10), with: sample(40))
        check(gap.closed != nil && gap.open.start == t0.addingTimeInterval(40), "a gap longer than the interval starts a new block")
        let touching = ActivityLogic.collapse(block(0, 10, title: "MainWindow.swift"), with: sample(10))
        check(touching.closed == nil && touching.open.end == t0.addingTimeInterval(15), "a sample right at the end extends")
    }),

    ("capture settings and excluded apps strip fields", {
        var settings = ActivitySettings()
        let s = sample(0, app: "1Password", title: "Login for bank", url: "bank.se/login", repo: "x", ticket: "QDLY-1")
        let filtered = ActivityLogic.filtered(s, settings: settings)
        check(filtered.appName == "1Password" && filtered.windowTitle == nil && filtered.url == nil && filtered.repo == nil && filtered.ticket == nil,
              "excluded app keeps only the app \(filtered)")
        check(settings.excludes(appName: "keychain access", bundle: nil), "case-insensitive")
        settings.titles = false
        settings.git = false
        let partial = ActivityLogic.filtered(sample(0, title: "t", url: "a.se", repo: "r", branch: "b"), settings: settings)
        check(partial.windowTitle == nil && partial.url == "a.se" && partial.repo == nil && partial.branch == nil, "toggles \(partial)")
        settings.claude = false
        check(ActivityLogic.filtered(sample(0, claude: [ClaudeSession(id: "a", folder: "/x", title: "t")]), settings: settings).claude.isEmpty, "claude off")
    }),

    ("tickets are found in titles, branches and urls", {
        check(ActivityLogic.ticket(in: "NI/QDLY-8296 — finq.api") == "QDLY-8296", "branch")
        check(ActivityLogic.ticket(in: nil, "QDLY-8178: Search the fields — PyCharm") == "QDLY-8178", "title after nil")
        check(ActivityLogic.ticket(in: "quiddly.atlassian.net/browse/ISD-13089") == "ISD-13089", "url")
        check(ActivityLogic.ticket(in: "utf-8 and ab-12") == nil, "lowercase")
    }),

    ("repositories are matched by folder name as a whole word, longest first", {
        let repos = ["finq.api", "finq.admin-ui", "indemeeting", "inde"].map { URL(fileURLWithPath: "/Users/me/git/\($0)") }
        check(ActivityLogic.repository(inTitle: "MainWindow.swift — indemeeting", repositories: repos)?.lastPathComponent == "indemeeting", "editor")
        check(ActivityLogic.repository(inTitle: "niklasinde@mac finq.admin-ui — zsh", repositories: repos)?.lastPathComponent == "finq.admin-ui",
              "longest wins over finq.api prefix")
        check(ActivityLogic.repository(inTitle: "~/git/inde/finq.api — Claude", repositories: repos)?.lastPathComponent == "finq.api", "path")
        check(ActivityLogic.repository(inTitle: "indemeeting", repositories: repos)?.lastPathComponent == "indemeeting",
              "inde is only a prefix of indemeeting")
        check(ActivityLogic.repository(inTitle: "Slack — #general", repositories: repos) == nil, "no repo")
        check(ActivityLogic.repository(inTitle: nil, repositories: repos) == nil, "nil title")
    }),

    ("the branch is read from .git/HEAD, also through a worktree's gitdir file", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: main.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        check(ActivityLogic.branch(ofRepository: main) == "main", "plain repo")
        try "ref: refs/heads/NI/QDLY-8296\n".write(to: main.appendingPathComponent(".git/worktrees/wt/HEAD"), atomically: true, encoding: .utf8)
        let worktree = folder.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        check(ActivityLogic.branch(ofRepository: worktree) == "NI/QDLY-8296", "worktree \(ActivityLogic.branch(ofRepository: worktree) ?? "nil")")
        check(ActivityLogic.branch(fromHEAD: "9a68712abcdef0123456\n") == "9a68712a", "detached")
        check(ActivityLogic.branch(ofRepository: folder.appendingPathComponent("missing")) == nil, "no repo")
        let repos = ActivityLogic.repositories(under: folder)
        check(Set(repos.map(\.lastPathComponent)) == ["repo", "wt"], "finds repos and worktrees \(repos)")
    }),

    ("urls keep host and path only", {
        check(ActivityLogic.cleanURL("https://github.com/quiddly-com/finq.api/pull/1966?diff=split#top") == "github.com/quiddly-com/finq.api/pull/1966", "query and fragment dropped")
        check(ActivityLogic.cleanURL("https://Mail.Google.com/") == "mail.google.com", "root path")
        check(ActivityLogic.cleanURL("https://x.se/a/b/") == "x.se/a/b", "trailing slash")
        check(ActivityLogic.cleanURL("file:///Users/me/doc.pdf") == nil, "file urls skipped")
        check(ActivityLogic.cleanURL("chrome://newtab") == nil && ActivityLogic.cleanURL("") == nil && ActivityLogic.cleanURL(nil) == nil, "non-http")
    }),

    ("claude sessions take their folder and title from the transcript", {
        let reminder = "<system-reminder>\\nYou are operating in a git worktree.\\n</system-reminder>\\nFix the flaky test in StoreTests\\nand push it"
        let jsonl = """
        {"type":"queue-operation","operation":"enqueue"}
        {"type":"user","cwd":"/Users/me/git/inde/indemeeting","message":{"role":"user","content":[{"type":"text","text":"\(reminder)"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}
        {"type":"user","cwd":"/Users/me/git/inde/indemeeting","message":{"role":"user","content":"second message"}}
        """
        let session = ActivityLogic.claudeSession(id: "abc", jsonl: jsonl)
        check(session == ClaudeSession(id: "abc", folder: "/Users/me/git/inde/indemeeting", title: "Fix the flaky test in StoreTests"),
              "first user line without reminders \(String(describing: session))")
        let titled = jsonl + "\n{\"type\":\"custom-title\",\"customTitle\":\"Flaky store test\"}"
        check(ActivityLogic.claudeSession(id: "abc", jsonl: titled)?.title == "Flaky store test", "custom-title line wins")
        check(ActivityLogic.claudeSession(id: "abc", jsonl: jsonl, customTitle: "From sidecar")?.title == "From sidecar", "sidecar wins")
        let plain = "{\"type\":\"user\",\"cwd\":\"/x\",\"message\":{\"content\":\"\(String(repeating: "long ", count: 30))\"}}"
        let truncated = ActivityLogic.claudeSession(id: "z", jsonl: plain, titleLimit: 20)!.title
        check(truncated.count <= 20 && truncated.hasSuffix("\u{2026}"), "truncated '\(truncated)'")
        check(ActivityLogic.claudeSession(id: "q", jsonl: "{\"type\":\"user\",\"cwd\":\"/x\",\"message\":{\"content\":\"<local-command-stdout>x</local-command-stdout>\"}}")?.title == "Untitled session", "only tags")
        check(ActivityLogic.claudeSession(id: "n", jsonl: "{\"type\":\"summary\"}") == nil, "no user message")
        check(ActivityLogic.decodeProjectFolder("-Users-me-git-inde-indemeeting") == "/Users/me/git/inde/indemeeting", "folder name")
    }),

    ("project rules match repo, ticket prefix, host and app; a block's own project wins", {
        func project(_ b: ActivityBlock) -> String? { ActivityLogic.project(for: b, rules: rules, projects: projects)?.name }
        check(project(block(0, 5, app: "PyCharm", repo: "finq.api")) == "Quiddly", "repo")
        check(project(block(0, 5, app: "Safari", url: "quiddly.atlassian.net/browse/QDLY-1", ticket: "QDLY-1")) == "Quiddly", "ticket prefix")
        check(project(block(0, 5, app: "Safari", ticket: "QDLYX-1")) == nil, "prefix needs the dash")
        check(project(block(0, 5, app: "Safari", url: "devops.indepower.se/x")) == "Inde", "host suffix")
        check(project(block(0, 5, app: "Safari", url: "notindepower.se/x")) == nil, "host suffix needs a dot")
        check(project(block(0, 5, app: "Xcode")) == "Inde", "app name")
        check(project(block(0, 5, app: "Xcode", repo: "finq.api")) == "Quiddly", "first matching rule wins")
        check(project(block(0, 5, app: "Xcode", project: 1)) == "Quiddly", "override")
        check(project(block(0, 5, app: "Slack")) == nil, "unmatched")
    }),

    ("day totals per project and app clip blocks to the day", {
        let day = t0.addingTimeInterval(100)..<t0.addingTimeInterval(1000)
        let blocks = [block(0, 400, app: "Xcode"), block(400, 700, app: "Safari", url: "indepower.se"), block(700, 800, idle: true),
                      block(800, 1200, app: "PyCharm", repo: "finq.api")]
        let byProject = ActivityLogic.projectTotals(blocks, in: day, rules: rules, projects: projects)
        check(byProject == [.init(name: "Inde", seconds: 600), .init(name: "Quiddly", seconds: 200)], "clipped and summed \(byProject)")
        let byApp = ActivityLogic.appTotals(blocks, in: day)
        check(byApp.map(\.name) == ["Safari", "Xcode", "PyCharm"] && byApp[0].seconds == 300, "equal totals by name \(byApp)")
        check(ActivityLogic.activeSeconds(blocks, in: day) == 800, "idle left out")
        let unassigned = ActivityLogic.projectTotals([block(0, 500, app: "Slack"), block(500, 600, app: "Xcode")], in: day, rules: rules, projects: projects)
        check(unassigned.map(\.name) == ["Inde", "Unassigned"], "unassigned last \(unassigned)")
        check(ActivityLogic.hoursText(0) == "0 min" && ActivityLogic.hoursText(20) == "<1 min" && ActivityLogic.hoursText(3600) == "1 h"
              && ActivityLogic.hoursText(5400) == "1 h 30 min" && ActivityLogic.hoursText(90) == "2 min", "hours text")
        let week = ActivityLogic.week(containing: Date(timeIntervalSince1970: 1_792_300_000), calendar: utc)
        check(week.count == 7 && utc.component(.weekday, from: week[0].lowerBound) == 2 && week[6].upperBound == week[0].lowerBound.addingTimeInterval(7 * 86400),
              "monday to sunday")
    }),

    ("the week exports as csv and markdown per day and project", {
        let monday = ActivityLogic.week(containing: t0, calendar: utc)[0].lowerBound
        func at(_ day: Int, _ hour: Double) -> Date { monday.addingTimeInterval(Double(day) * 86400 + hour * 3600) }
        func b(_ day: Int, _ from: Double, _ to: Double, app: String, repo: String? = nil, branch: String? = nil, ticket: String? = nil,
               url: String? = nil, title: String? = nil) -> ActivityBlock {
            ActivityBlock(id: 1, start: at(day, from), end: at(day, to), key: ActivityKey(appBundle: app, appName: app, windowTitle: title, url: url,
                          repo: repo, branch: branch, ticket: ticket, claude: [], idle: false), projectID: nil)
        }
        let blocks = [b(0, 9, 10.5, app: "PyCharm", repo: "finq.api", branch: "NI/QDLY-8296", ticket: "QDLY-8296"),
                      b(0, 10.5, 11, app: "Safari", ticket: "QDLY-8296", url: "github.com/quiddly-com/finq.api/pull/1"),
                      b(0, 13, 14, app: "Xcode", title: "Main, \"quoted\""),
                      b(2, 9, 9.25, app: "Slack")]
        let report = ActivityLogic.WeekReport(days: ActivityLogic.week(containing: t0, calendar: utc), blocks: blocks, rules: rules,
                                              projects: projects, calendar: utc)
        let csv = ActivityLogic.csv(report)
        let lines = csv.split(separator: "\n")
        check(lines[0] == "date,project,hours,details", "header")
        check(lines[1] == "\(ActivityLogic.dateText(monday)),Quiddly,2.00,QDLY-8296; finq.api (NI/QDLY-8296); github.com", "quiddly row '\(lines[1])'")
        check(lines[2] == "\(ActivityLogic.dateText(monday)),Inde,1.00,\"Main, \"\"quoted\"\"\"", "quoted field '\(lines[2])'")
        check(lines[3].hasSuffix(",Unassigned,0.25,Slack") && lines.count == 4, "slack on wednesday '\(lines[3])'")
        let markdown = ActivityLogic.markdown(report)
        check(markdown.hasPrefix("# Week ") && markdown.contains("Total: 3 h 15 min"), "title and total \(markdown.prefix(80))")
        check(markdown.contains("### Quiddly \u{00B7} 2 h\n- QDLY-8296\n- finq.api (NI/QDLY-8296)\n- github.com\n"), "project bullets \(markdown)")
        check(markdown.contains("### Unassigned \u{00B7} 15 min\n- Slack"), "unassigned")
        check(markdown.components(separatedBy: "\n## ").count == 3, "only days with activity")
    }),

    ("the context summary lists projects, apps, repos, tickets, urls, claude sessions and meetings", {
        let range = t0..<t0.addingTimeInterval(3600)
        let claude = ClaudeSession(id: "s1", folder: "/Users/me/git/inde/indemeeting", title: "Activity tracking")
        let blocks = [block(0, 1800, app: "Xcode", title: "ActivityLogic.swift — indemeeting", repo: "indemeeting", branch: "main", claude: [claude]),
                      block(1800, 2400, app: "Safari", url: "github.com/quiddly-com/finq.api/pull/1966", ticket: "QDLY-8296", claude: [claude]),
                      block(2400, 2700, idle: true),
                      block(2700, 3600, app: "Slack", title: "general (Quiddly) — Slack")]
        let meetings = [ActivityLogic.MeetingSummaryLine(date: t0.addingTimeInterval(600), title: "Standup", duration: 900)]
        let markdown = ActivityLogic.contextMarkdown(blocks: blocks, meetings: meetings, range: range, rules: rules, projects: projects)
        check(markdown.hasPrefix("# Activity "), "title")
        check(markdown.contains("Active: 55 min"), "active without idle \(markdown)")
        check(markdown.contains("## Projects\n- Inde: 30 min\n- Quiddly: 10 min\n- Unassigned: 15 min"), "projects \(markdown)")
        check(markdown.contains("## Apps\n- Xcode \u{00B7} 30 min\n- Slack \u{00B7} 15 min\n- Safari \u{00B7} 10 min"), "apps")
        check(markdown.contains("## Repositories\n- indemeeting (main) \u{00B7} 30 min"), "repos")
        check(markdown.contains("## Tickets\n- QDLY-8296 \u{00B7} 10 min"), "tickets")
        check(markdown.contains("## Websites\n- github.com/quiddly-com/finq.api/pull/1966 \u{00B7} 10 min"), "urls")
        check(markdown.contains("## Claude sessions\n- Activity tracking (indemeeting) \u{00B7} 40 min"), "claude lane spans both blocks")
        check(markdown.contains("## Windows\n- general (Quiddly) \u{2014} Slack \u{00B7} 15 min"), "titles only where no repo or url")
        check(markdown.contains("## Meetings\n- ") && markdown.contains("Standup \u{00B7} 15 min"), "meetings")
        check(ActivityLogic.contextArguments(["app", "--context"]) == 8 && ActivityLogic.contextArguments(["app", "--context", "2.5"]) == 2.5
              && ActivityLogic.contextArguments(["app"]) == nil && ActivityLogic.contextArguments(["app", "--context", "x"]) == 8, "arguments")
    }),

    ("blocks, projects and rules round-trip through the database", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let quiddly = try store.addProject("Quiddly")
        let inde = try store.addProject("Inde", color: "#000000")
        check(quiddly.color == Project.colors[0] && inde.color == "#000000", "colors")
        try store.addRule(project: quiddly.id, field: .repo, pattern: " finq.api ")
        check(try store.rules().map(\.pattern) == ["finq.api"], "trimmed rule")
        let claude = ClaudeSession(id: "s1", folder: "/Users/me/git/x", title: "Title with\ttab")
        var open = ActivityLogic.collapse(nil, with: sample(0, repo: "finq.api", branch: "main", ticket: "QDLY-1", claude: [claude])).open
        open.id = try store.saveBlock(open)
        open = ActivityLogic.collapse(open, with: sample(5, repo: "finq.api", branch: "main", ticket: "QDLY-1", claude: [claude])).open
        check(try store.saveBlock(open) == open.id, "update keeps the id")
        var away = block(100, 200, idle: true)
        away.id = 0
        try store.saveBlock(away)
        let blocks = try store.blocks(in: t0..<t0.addingTimeInterval(1000))
        check(blocks.count == 2 && blocks[0].duration == 10 && blocks[0].key.claude == [claude] && blocks[1].key.idle, "read back \(blocks)")
        check(blocks[0].key == open.key && blocks[0].projectID == nil, "same key")
        check(ActivityLogic.project(for: blocks[0], rules: try store.rules(), projects: try store.projects())?.name == "Quiddly", "rule applies")
        try store.setProject(ofBlock: open.id, inde.id)
        check(try store.blocks(in: t0..<t0.addingTimeInterval(10)).first?.projectID == inde.id, "override saved")
        try store.deleteProject(inde.id)
        check(try store.blocks(in: t0..<t0.addingTimeInterval(10)).first?.projectID == nil, "deleting a project clears overrides")
        try store.deleteProject(quiddly.id)
        check(try store.rules().isEmpty, "rules go with the project")
        check(try store.deleteBlocks(before: t0.addingTimeInterval(150)) == 1, "retention deletes blocks that ended before")
        check(try store.blocks(in: t0..<t0.addingTimeInterval(1000)).count == 1, "the other block stays")
        check(try store.blocks(in: t0.addingTimeInterval(-10)..<t0).isEmpty, "outside")
    }),

    ("the text around the cursor is excerpted and kept once it has settled", {
        let text = (1...50).map { "word\($0)" }.joined(separator: " ")
        let middle = ActivityLogic.excerpt(value: text, cursor: 150, limit: 60)!
        check(middle.hasPrefix("\u{2026}") && middle.hasSuffix("\u{2026}") && middle.count <= 62, "both ends cut '\(middle)'")
        check(middle.contains("word2"), "around the cursor \(middle)")
        let start = ActivityLogic.excerpt(value: text, cursor: 0, limit: 60)!
        check(!start.hasPrefix("\u{2026}") && start.hasPrefix("word1 word2"), "start '\(start)'")
        let end = ActivityLogic.excerpt(value: text, cursor: 10_000, limit: 60)!
        check(end.hasSuffix("word50") && end.hasPrefix("\u{2026}"), "cursor past the end '\(end)'")
        check(ActivityLogic.excerpt(value: "a\r\nb\nc", cursor: 1) == "a b c", "one line")
        check(ActivityLogic.excerpt(value: "  \n ", cursor: 0) == nil, "blank")
        check(ActivityLogic.excerpt(value: "short", cursor: 2) == "short", "short")

        var watch = TypingWatch()
        check(watch.update("Hello", now: t0) == nil, "new text is not kept yet")
        check(watch.update("Hello wor", now: t0.addingTimeInterval(5)) == nil, "changed, timer restarts")
        check(watch.update("Hello wor", now: t0.addingTimeInterval(9)) == nil, "not settled yet")
        check(watch.update("Hello wor", now: t0.addingTimeInterval(10)) == "Hello wor", "settled after 5 s")
        check(watch.update("Hello wor", now: t0.addingTimeInterval(20)) == nil, "kept only once")
        watch.blockChanged()
        check(watch.update("Hello wor", now: t0.addingTimeInterval(25)) == "Hello wor", "kept again for the next block")
        check(watch.update(nil, now: t0.addingTimeInterval(30)) == nil && watch.update(nil, now: t0.addingTimeInterval(40)) == nil, "nothing focused")
    }),

    ("ai classification: cache keys ignore counters, prompts list the fields, results map onto the fixed lists", {
        let a = ActivityKey(appBundle: "com.apple.Terminal", appName: "Terminal", windowTitle: "finq.api \u{2014} zsh \u{2014} 80\u{00D7}24", url: nil,
                            repo: "finq.api", branch: "main", ticket: nil, claude: [], idle: false)
        var b = a
        b.windowTitle = "finq.api \u{2014} zsh \u{2014} 120\u{00D7}40"
        b.branch = "other"
        check(ActivityAI.cacheKey(a) == ActivityAI.cacheKey(b), "sizes and branches do not matter \(ActivityAI.cacheKey(a))")
        var c = a
        c.url = "github.com/x"
        check(ActivityAI.cacheKey(a) != ActivityAI.cacheKey(c), "address matters")
        var slack = a
        slack.appBundle = "com.tinyspeck.slackmacgap"
        slack.windowTitle = "general (3)  \u{2014}  Slack"
        check(ActivityAI.cacheKey(slack) == "com.tinyspeck.slackmacgap|general (#) \u{2014} slack||finq.api", "normalised '\(ActivityAI.cacheKey(slack))'")

        var b1 = block(0, 5, app: "Safari", url: "github.com/quiddly-com/finq.api/pull/1966", repo: "finq.api", branch: "NI/QDLY-8296", ticket: "QDLY-8296")
        b1.typedExcerpt = "Looks good, one nit on the rounding"
        let prompt = ActivityAI.prompt(for: b1, projects: projects)
        check(prompt == """
            App: Safari
            Address: github.com/quiddly-com/finq.api/pull/1966
            Repository: finq.api on branch NI/QDLY-8296
            Ticket: QDLY-8296
            Text being written: Looks good, one nit on the rounding
            Projects: Quiddly, Inde
            """, "prompt\n\(prompt)")
        check(ActivityAI.prompt(for: block(0, 5, app: "Slack"), projects: []).hasSuffix("Projects: none"), "no projects")
        check(ActivityAI.projectChoices(projects) == ["none", "Quiddly", "Inde"], "choices")

        let mapped = ActivityAI.classification(category: "Code Review", description: "Reviewing a pull request about rounding fees in reminders",
                                               project: "quiddly", projects: projects)
        check(mapped == .init(category: .codeReview, description: "Reviewing a pull request about rounding fees in", projectID: 1),
              "mapped \(mapped)")
        check(ActivityAI.classification(category: "gaming", description: " ", project: "none", projects: projects)
              == .init(category: .other, description: nil, projectID: nil), "unknown values")
        check(ActivityLogic.categoryTotals([block(0, 5, app: "x")], in: t0..<t0.addingTimeInterval(10)).isEmpty, "uncategorised left out")
    }),

    ("a rule or a manual choice beats the ai project guess", {
        var guessed = block(0, 100, app: "Slack")
        guessed.aiProjectID = 2
        check(ActivityLogic.project(for: guessed, rules: rules, projects: projects)?.name == "Inde", "guess used when nothing else matches")
        check(ActivityLogic.projectIsGuessed(guessed, rules: rules), "shown as a guess")
        guessed.key.repo = "finq.api"
        check(ActivityLogic.project(for: guessed, rules: rules, projects: projects)?.name == "Quiddly", "rule wins")
        check(!ActivityLogic.projectIsGuessed(guessed, rules: rules), "not a guess with a rule")
        guessed.projectID = 2
        check(ActivityLogic.project(for: guessed, rules: rules, projects: projects)?.name == "Inde", "manual choice wins over the rule")
        var coding = block(0, 3600, app: "Xcode")
        coding.category = .coding
        var review = block(3600, 5400, app: "Safari")
        review.category = .codeReview
        let totals = ActivityLogic.categoryTotals([coding, review, block(5400, 6000, app: "Slack")], in: t0..<t0.addingTimeInterval(7200))
        check(totals == [.init(name: "Coding", seconds: 3600), .init(name: "Code review", seconds: 1800)], "category totals \(totals)")
        let context = ActivityLogic.contextMarkdown(blocks: [coding, review], meetings: [], range: t0..<t0.addingTimeInterval(7200))
        check(context.contains("## Categories\n- Coding \u{00B7} 1 h\n- Code review \u{00B7} 30 min"), "context categories \(context)")
        var written = block(0, 60, app: "Mail")
        written.typedExcerpt = "Hi Anna, the release is on Tuesday"
        check(ActivityLogic.contextMarkdown(blocks: [written], meetings: [], range: t0..<t0.addingTimeInterval(100))
              .contains("## Writing\n- Mail \u{00B7} \u{201C}Hi Anna, the release is on Tuesday\u{201D}"), "context writing")
    }),

    ("classifications and their cache round-trip through the database", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let project = try store.addProject("Quiddly")
        var open = block(0, 60, app: "Safari", url: "github.com/x")
        open.id = 0
        open.typedExcerpt = "LGTM"
        let id = try store.saveBlock(open)
        var idle = block(100, 200, idle: true)
        idle.id = 0
        try store.saveBlock(idle)
        let pending = try store.unclassifiedBlocks(endedBefore: t0.addingTimeInterval(1000), limit: 10)
        check(pending.map(\.id) == [id] && pending[0].typedExcerpt == "LGTM", "only the finished non-idle block \(pending)")
        check(try store.unclassifiedBlocks(endedBefore: t0.addingTimeInterval(30), limit: 10).isEmpty, "still open blocks wait")
        try store.setClassification(ofBlock: id, .init(category: .codeReview, description: "Reviewing a PR", projectID: project.id))
        let saved = try store.blocks(in: t0..<t0.addingTimeInterval(1000))[0]
        check(saved.category == .codeReview && saved.aiDescription == "Reviewing a PR" && saved.aiProjectID == project.id, "classified \(saved)")
        check(try store.unclassifiedBlocks(endedBefore: t0.addingTimeInterval(1000), limit: 10).isEmpty, "done")
        try store.saveBlock(saved)
        check(try store.blocks(in: t0..<t0.addingTimeInterval(1000))[0].category == .codeReview, "saving a block keeps its classification")
        check(try store.cachedClassification("k") == nil, "empty cache")
        try store.cacheClassification("k", category: "coding", description: "Editing", project: "Quiddly")
        try store.cacheClassification("k", category: "coding", description: "Editing Swift", project: nil)
        let cached = try store.cachedClassification("k")
        check(cached?.category == "coding" && cached?.description == "Editing Swift" && cached?.project == nil, "upsert \(String(describing: cached))")
        try store.deleteProject(project.id)
        check(try store.blocks(in: t0..<t0.addingTimeInterval(1000))[0].aiProjectID == nil, "deleting a project clears guesses")
    }),
]
