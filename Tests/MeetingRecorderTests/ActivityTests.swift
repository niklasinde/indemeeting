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

    ("capture settings and blocked apps strip fields", {
        var settings = ActivitySettings()
        var s = sample(0, app: "1Password", title: "Login for bank", url: "bank.se/login", repo: "x", ticket: "QDLY-1")
        s.claudePrompt = "secret"
        let filtered = ActivityLogic.filtered(s, settings: settings)!
        check(filtered.appName == "1Password" && filtered.appBundle == "com.1Password" && filtered.windowTitle == nil && filtered.url == nil
              && filtered.repo == nil && filtered.ticket == nil && filtered.claudePrompt == nil && filtered.redaction == .private,
              "blocked app keeps only the app \(filtered)")
        check(settings.blocks(appName: "keychain access", bundle: nil), "case-insensitive")
        check(settings.blockedApps == ["1Password", "Keychain Access", "Passwords"], "default blocked apps")
        settings.titles = false
        settings.git = false
        let partial = ActivityLogic.filtered(sample(0, title: "t", url: "a.se", repo: "r", branch: "b"), settings: settings)!
        check(partial.windowTitle == nil && partial.url == "a.se" && partial.repo == nil && partial.branch == nil && partial.redaction == nil,
              "toggles \(partial)")
        settings.claude = false
        check(ActivityLogic.filtered(sample(0, claude: [ClaudeSession(id: "a", folder: "/x", title: "t")]), settings: settings)!.claude.isEmpty, "claude off")
    }),

    ("website patterns are normalised and match the host and its subdomains", {
        check(HostPattern.normalized("https://Www.Bank.SE/login?x=1") == "www.bank.se", "scheme, path and query dropped")
        check(HostPattern.normalized("  github.com/quiddly-com ") == "github.com", "path")
        check(HostPattern.normalized("*.Atlassian.net") == "*.atlassian.net", "wildcard kept")
        check(HostPattern.normalized("user@localhost:8080") == "localhost", "credentials and port")
        check(HostPattern.normalized("bank.se.") == "bank.se", "trailing dot")
        for bad in ["", "   ", "https://", "bad host.se", "-x.se", "a..b", "*.", "ex*ample.com", "*.*.x.se"] {
            check(HostPattern.normalized(bad) == nil, "invalid: \(bad)")
        }
        check(HostPattern.matches("bank.se", host: "bank.se") && HostPattern.matches("bank.se", host: "www.bank.se"), "suffix")
        check(!HostPattern.matches("bank.se", host: "mybank.se") && !HostPattern.matches("bank.se", host: "bank.se.evil.com"), "whole labels only")
        check(HostPattern.matches("*.atlassian.net", host: "quiddly.atlassian.net") && !HostPattern.matches("*.atlassian.net", host: "atlassian.net"),
              "wildcard covers only subdomains")
        check(HostPattern.matches("GitHub.com", host: "GITHUB.COM"), "case")
        check(HostPattern.presets.allSatisfy { HostPattern.normalized($0.pattern) == $0.pattern }, "presets are normalised")
        let rule = ProjectRule(id: 1, projectID: 1, field: .host, pattern: "*.atlassian.net")
        check(rule.matches(block(0, 1, url: "quiddly.atlassian.net/browse/QDLY-1").key), "project rules take wildcards too")
    }),

    ("app and website modes are independent and the blocklist wins", {
        func key(_ app: String, _ bundle: String, url: String? = nil) -> ActivityKey {
            ActivitySample(time: t0, appBundle: bundle, appName: app, windowTitle: "t", url: url).key
        }
        let chrome = "com.google.Chrome"
        var settings = ActivitySettings()
        check(settings.capture(key("Xcode", "com.apple.dt.Xcode")) == .keep, "everything is tracked by default")
        check(settings.capture(key("Chrome", chrome, url: "news.se/a")) == .keep, "any website by default")

        settings.siteMode = .onlyAllowed
        settings.allowedSites = ["*.atlassian.net", "github.com"]
        check(settings.capture(key("Chrome", chrome, url: "quiddly.atlassian.net/browse/X-1")) == .keep, "allowed site keeps detail")
        check(settings.capture(key("Chrome", chrome, url: "gist.github.com/x")) == .keep, "subdomain of an allowed site")
        check(settings.capture(key("Chrome", chrome, url: "news.se/a")) == .redact(.otherSite), "other site")
        check(settings.capture(key("Chrome", chrome)) == .redact(.otherSite), "a browser without an address is another site")
        check(settings.capture(key("Firefox", "org.mozilla.firefox")) == .redact(.otherSite), "firefox has no address")
        check(settings.capture(key("Xcode", "com.apple.dt.Xcode")) == .keep, "other apps are not affected by the website mode")

        settings.blockedSites = ["github.com"]
        check(settings.capture(key("Chrome", chrome, url: "github.com/x")) == .redact(.private), "a blocked site beats the allowlist")

        settings.appMode = .onlyAllowed
        settings.allowedApps = ["Xcode", "com.apple.Terminal"]
        check(settings.capture(key("Xcode", "com.apple.dt.Xcode")) == .keep, "allowed by name")
        check(settings.capture(key("Terminal", "com.apple.Terminal")) == .keep, "allowed by bundle id")
        check(settings.capture(key("Slack", "com.tinyspeck.slackmacgap")) == .redact(.other), "not allowed: other")
        check(settings.capture(key("Chrome", chrome, url: "quiddly.atlassian.net/x")) == .keep, "a browser counts as allowed on an allowed site")
        check(settings.capture(key("Chrome", chrome, url: "news.se")) == .redact(.other), "a browser off the allowed sites is other")
        settings.allowedApps.append("Google Chrome")
        check(settings.capture(key("Google Chrome", chrome, url: "news.se")) == .redact(.otherSite), "an allowed browser still follows the website list")
        settings.siteMode = .allExceptBlocked
        check(settings.capture(key("Google Chrome", chrome, url: "news.se")) == .keep, "allowed browser, all websites")

        settings.blockedApps.append("Xcode")
        check(settings.capture(key("Xcode", "com.apple.dt.Xcode")) == .redact(.private), "a blocked app beats the allowlist")
        settings.removeBlocked = true
        check(settings.capture(key("Xcode", "com.apple.dt.Xcode")) == .remove, "blocked apps removed")
        check(settings.capture(key("Google Chrome", chrome, url: "github.com/x")) == .remove, "blocked sites removed")
        check(settings.capture(key("Slack", "com.tinyspeck.slackmacgap")) == .redact(.other), "apps outside the allowlist stay as other")
        settings.siteMode = .onlyAllowed
        check(settings.capture(key("Google Chrome", chrome, url: "news.se")) == .remove, "other sites removed")
        check(settings.capture(ActivitySample.idle(at: t0).key) == .keep, "idle is left alone")
        check(settings.action(for: .coding) == .keep, "category exclusion still applies after classification")
        settings.excludedCategories = [.coding]
        check(settings.action(for: .coding) == .remove, "and follows the remove toggle")
    }),

    ("app and website lists round-trip through the settings, keeping the old excluded apps", {
        let defaults = UserDefaults(suiteName: "activity-\(UUID().uuidString)")!
        defaults.register(defaults: ActivitySettings.defaults)
        var settings = ActivitySettings(defaults)
        check(settings.blockedApps == ActivitySettings.defaultExcluded && settings.allowedApps.isEmpty && settings.blockedSites.isEmpty
              && settings.allowedSites.isEmpty && settings.appMode == .allExceptBlocked && settings.siteMode == .allExceptBlocked
              && !settings.removeBlocked && !settings.needsHost, "defaults")
        defaults.set(["Slack"], forKey: "activityExcludedApps")
        defaults.set(["Xcode"], forKey: ActivitySettings.allowedAppsKey)
        defaults.set(["bank.se"], forKey: ActivitySettings.blockedSitesKey)
        defaults.set(["github.com", "*.atlassian.net"], forKey: ActivitySettings.allowedSitesKey)
        defaults.set("allowed", forKey: ActivitySettings.appModeKey)
        defaults.set("allowed", forKey: ActivitySettings.siteModeKey)
        defaults.set(true, forKey: "activityRemoveExcludedCategories")
        settings = ActivitySettings(defaults)
        check(settings.blockedApps == ["Slack"] && settings.allowedApps == ["Xcode"] && settings.blockedSites == ["bank.se"]
              && settings.allowedSites == ["github.com", "*.atlassian.net"] && settings.appMode == .onlyAllowed
              && settings.siteMode == .onlyAllowed && settings.removeBlocked && settings.needsHost, "read back \(settings)")
        defaults.set("bogus", forKey: ActivitySettings.appModeKey)
        check(ActivitySettings(defaults).appMode == .allExceptBlocked, "unknown mode falls back")
    }),

    ("the store keeps the redaction and applies the rules to existing activity", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        func add(_ start: TimeInterval, app: String, bundle: String? = nil, url: String? = nil, redaction: ActivityRedaction? = nil) throws -> Int64 {
            var b = block(start, start + 10, app: app, title: "Secret", url: url, repo: "r", ticket: "AB-1")
            b.id = 0
            b.key.appBundle = bundle ?? b.key.appBundle
            b.key.redaction = redaction
            b.typedExcerpt = "typed"
            b.aiDescription = "desc"
            return try store.saveBlock(b)
        }
        let chrome = "com.google.Chrome"
        let xcode = try add(0, app: "Xcode")
        _ = try add(10, app: "Slack")
        _ = try add(20, app: "Google Chrome", bundle: chrome, url: "news.se/a")
        _ = try add(30, app: "Google Chrome", bundle: chrome, url: "quiddly.atlassian.net/browse/X-1")
        _ = try add(40, app: "Google Chrome", bundle: chrome, url: "online.bank.se/login")
        _ = try add(50, app: "1Password", redaction: .private)
        var idle = block(60, 70, idle: true)
        idle.id = 0
        try store.saveBlock(idle)
        let range = t0..<t0.addingTimeInterval(100)
        check(try store.blocks(in: range)[5].key.redaction == .private, "redaction round-trips")

        var settings = ActivitySettings()
        settings.appMode = .onlyAllowed
        settings.allowedApps = ["Xcode", "Google Chrome"]
        settings.siteMode = .onlyAllowed
        settings.allowedSites = ["*.atlassian.net"]
        settings.blockedSites = ["bank.se"]
        check(try store.applyRules(settings) == 3, "slack, news.se and the bank changed")
        let blocks = try store.blocks(in: range)
        check(blocks[0].id == xcode && blocks[0].key.windowTitle == "Secret" && blocks[0].typedExcerpt == "typed", "allowed app kept")
        let other = blocks[1]
        check(other.key.redaction == .other && other.key.appName == nil && other.key.appBundle == nil && other.key.windowTitle == nil
              && other.typedExcerpt == nil && other.aiDescription == nil && other.duration == 10, "other keeps only times \(other)")
        check(blocks[2].key.redaction == .otherSite && blocks[2].key.appName == "Google Chrome" && blocks[2].key.url == nil, "other site")
        check(blocks[3].key.redaction == nil && blocks[3].key.url == "quiddly.atlassian.net/browse/X-1", "allowed site kept")
        check(blocks[4].key.redaction == .private && blocks[4].key.url == nil && blocks[4].key.appName == "Google Chrome", "blocked site private")
        check(blocks[6].key.idle, "idle untouched")
        check(try store.applyRules(settings) == 0, "applying again changes nothing")

        settings.removeBlocked = true
        check(try store.applyRules(settings) == 3, "private and other-site blocks removed, other kept")
        check(try store.blocks(in: range).map { $0.key.redaction?.rawValue ?? ($0.key.idle ? "idle" : "kept") } == ["kept", "other", "kept", "idle"],
              "what is left")
    }),

    ("non-work follows the user's rules, then the allowlist, then apple intelligence", {
        func classified(_ app: String, url: String? = nil, category: ActivityCategory?, work: Bool?) -> ActivityBlock {
            var b = block(0, 60, app: app, title: "t", url: url)
            b.category = category
            b.aiWork = work
            return b
        }
        var settings = ActivitySettings()
        check(settings.isWork(classified("Xcode", category: .coding, work: true)), "work")
        check(!settings.isWork(classified("Safari", category: .entertainment, work: true)), "entertainment is never work")
        check(!settings.isWork(classified("Safari", category: .research, work: false)), "the model says not work")
        check(settings.isWork(classified("Safari", category: .research, work: nil)), "old answers without the flag count as work")
        check(settings.isWork(classified("Safari", category: nil, work: nil)), "not yet categorised")
        let video = classified("Safari", url: "www.youtube.com/watch", category: .entertainment, work: false)
        check(settings.review(video) == .keep, "non-work is kept by default")
        settings.nonWork = .fold
        check(settings.review(video) == .redact(.other), "folded into other")
        settings.nonWork = .remove
        check(settings.review(video) == .remove, "removed")
        settings.nonWork = .fold
        settings.allowedSites = ["youtube.com"]
        check(settings.isWork(video) && settings.review(video) == .keep, "an allowed website beats the model")
        settings.nonWorkSites = ["youtube.com"]
        check(!settings.isWork(video), "the user's rule beats the allowlist")
        settings.workSites = ["youtube.com"]
        check(!settings.isWork(video), "not work wins when a host is on both lists")
        settings.nonWorkSites = []
        check(settings.isWork(video), "this is work beats the model")
        settings.nonWorkApps = ["Safari"]
        check(settings.isWork(video), "a website rule beats an app rule")
        check(!settings.isWork(classified("Safari", url: "news.se", category: .research, work: true)), "the app rule applies elsewhere")
        check(settings.capture(classified("Safari", url: "news.se", category: nil, work: nil).key) == .redact(.other),
              "a not-work rule folds at capture time, before anything is stored")
        settings.blockedApps = ["Safari"]
        check(settings.capture(classified("Safari", url: "news.se", category: nil, work: nil).key) == .redact(.private), "blocked still wins")
        settings = ActivitySettings()
        settings.excludedCategories = [.chat]
        settings.nonWork = .fold
        check(settings.review(classified("Slack", category: .chat, work: false)) == .redact(.other), "folding beats making private")
        check(settings.review(classified("Slack", category: .chat, work: true)) == .redact(.private), "excluded category")
        settings.removeBlocked = true
        check(settings.review(classified("Slack", category: .chat, work: false)) == .remove, "removing an excluded category beats folding")

        var row = block(0, 10)
        row.key.redaction = .other
        var later = block(15, 30)
        later.key.redaction = .other
        var after = block(200, 210)
        after.key.redaction = .other
        let rows = ActivityLogic.timelineRows([row, later, block(30, 40), after, { var b = after; b.id = 300; b.start = t0.addingTimeInterval(220); b.end = t0.addingTimeInterval(230); return b }()])
        check(rows.map(\.id) == [0, 30, 200] && rows[0].end == t0.addingTimeInterval(30) && rows[2].end == t0.addingTimeInterval(230),
              "consecutive other blocks merge \(rows.map { ($0.id, $0.duration) })")
        var anonymous = row
        anonymous.key.appName = nil
        anonymous.key.appBundle = nil
        check(ActivityLogic.appTotals([anonymous], in: t0..<t0.addingTimeInterval(100)) == [.init(name: "Other", seconds: 10)], "other in the app totals")

        let defaults = UserDefaults(suiteName: "activity-\(UUID().uuidString)")!
        defaults.register(defaults: ActivitySettings.defaults)
        check(ActivitySettings(defaults).nonWork == .keep && ActivitySettings(defaults).workSites.isEmpty, "defaults")
        defaults.set("fold", forKey: ActivitySettings.nonWorkKey)
        defaults.set(["github.com"], forKey: ActivitySettings.workSitesKey)
        defaults.set(["Slack"], forKey: ActivitySettings.workAppsKey)
        defaults.set(["youtube.com"], forKey: ActivitySettings.nonWorkSitesKey)
        defaults.set(["Music"], forKey: ActivitySettings.nonWorkAppsKey)
        let read = ActivitySettings(defaults)
        check(read.nonWork == .fold && read.workSites == ["github.com"] && read.workApps == ["Slack"] && read.nonWorkSites == ["youtube.com"]
              && read.nonWorkApps == ["Music"], "read back")
    }),

    ("the work flag round-trips through the schema mapping, the cache and the blocks", {
        check(ActivityAI.classification(category: "entertainment", description: "Watching", project: "none", work: false, projects: projects).work == false,
              "mapped")
        check(ActivityAI.classification(category: "coding", description: nil, project: nil, projects: projects).work == nil, "absent")
        check(ActivityAI.instructions.contains("work:"), "the model is asked")
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        try store.cacheClassification("k", category: "entertainment", description: nil, project: nil, work: false)
        check(try store.cachedClassification("k")?.work == false, "cached")
        try store.cacheClassification("j", category: "coding", description: nil, project: nil)
        check(try store.cachedClassification("j")?.work == nil, "old style entry")
        var b = block(0, 60, app: "Safari", title: "Video", url: "youtube.com/watch")
        b.id = 0
        let id = try store.saveBlock(b)
        try store.setClassification(ofBlock: id, .init(category: .entertainment, description: "Watching", work: false))
        var saved = try store.blocks(in: t0..<t0.addingTimeInterval(100))[0]
        check(saved.aiWork == false, "stored on the block")
        try store.saveBlock(saved)
        check(try store.blocks(in: t0..<t0.addingTimeInterval(100))[0].aiWork == false, "kept when the block is saved again")

        var settings = ActivitySettings()
        settings.nonWork = .fold
        check(try store.applyRules(settings, to: []) == 0, "no blocks")
        check(try store.applyRules(settings) == 1, "folded")
        saved = try store.blocks(in: t0..<t0.addingTimeInterval(100))[0]
        check(saved.key.redaction == .other && saved.key.appName == nil && saved.key.url == nil && saved.category == nil && saved.duration == 60,
              "only the times are left \(saved)")
    }),

    ("the tracker never stores what the rules leave out", {
        var settings = ActivitySettings()
        settings.appMode = .onlyAllowed
        settings.allowedApps = ["Xcode", "Google Chrome"]
        settings.siteMode = .onlyAllowed
        settings.allowedSites = ["github.com"]
        let other = ActivityLogic.filtered(sample(0, app: "Slack", title: "DM with Anna", repo: "r", ticket: "AB-1"), settings: settings)!
        check(other == ActivitySample(time: t0, redaction: .other), "other keeps only the time \(other)")
        let browser = "com.google.Chrome"
        var site = ActivitySample(time: t0, appBundle: browser, appName: "Google Chrome", windowTitle: "News", url: "news.se/a")
        site.claudePrompt = "x"
        let otherSite = ActivityLogic.filtered(site, settings: settings)!
        check(otherSite == ActivitySample(time: t0, appBundle: browser, appName: "Google Chrome", redaction: .otherSite), "other site \(otherSite)")
        settings.removeBlocked = true
        check(ActivityLogic.filtered(site, settings: settings) == nil, "removed sites are not stored")

        var open: ActivityBlock?
        for s in [sample(0, app: "Slack", title: "a"), sample(5, app: "Mail", title: "b"), sample(10, app: "Xcode")] {
            open = ActivityLogic.collapse(open, with: ActivityLogic.filtered(s, settings: settings)!).open
            if s.appName == "Mail" { check(open?.duration == 10 && open?.key.appName == nil, "other apps collapse into one block") }
        }
        check(open?.key.appName == "Xcode" && open?.start == t0.addingTimeInterval(10), "an allowed app starts its own block")
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

    ("blocks are deleted by id, by range, by host on a day and all at once", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        func add(_ start: TimeInterval, _ end: TimeInterval, url: String? = nil) throws -> Int64 {
            var b = block(start, end, url: url)
            b.id = 0
            b.typedExcerpt = "typed"
            return try store.saveBlock(b)
        }
        func spans() throws -> [String] {
            try store.blocks(in: t0.addingTimeInterval(-100_000)..<t0.addingTimeInterval(100_000)).map {
                "\(Int($0.start.timeIntervalSince(t0)))-\(Int($0.end.timeIntervalSince(t0)))\($0.typedExcerpt == nil ? "" : "t")"
            }
        }
        let a = try add(0, 100)
        let b = try add(100, 200)
        _ = try add(200, 300)
        try store.delete(blockIDs: [a, b])
        check(try spans() == ["200-300t"], "by id \(try spans())")
        try store.delete(blockIDs: [])

        _ = try add(0, 100)
        _ = try add(400, 600)
        try store.delete(from: t0.addingTimeInterval(50), to: t0.addingTimeInterval(250))
        check(try spans() == ["0-50", "250-300", "400-600t"], "cut at the edges, typed text dropped \(try spans())")
        try store.delete(from: t0.addingTimeInterval(450), to: t0.addingTimeInterval(500))
        check(try spans() == ["0-50", "250-300", "400-450", "500-600"], "a spanning block is split \(try spans())")

        try store.deleteAll()
        _ = try add(0, 10, url: "github.com/quiddly-com/finq.api")
        _ = try add(10, 20, url: "github.com")
        _ = try add(20, 30, url: "github.community/x")
        _ = try add(30, 40, url: "docs.github.com/y")
        _ = try add(200_000, 200_010, url: "github.com/z")
        try store.deleteMatching(host: "github.com", on: t0)
        check(try store.blocks(in: t0..<t0.addingTimeInterval(100)).compactMap(\.key.url) == ["github.community/x", "docs.github.com/y"],
              "only the host on that day")
        check(try store.blocks(in: t0.addingTimeInterval(200_000)..<t0.addingTimeInterval(200_100)).count == 1, "other days stay")

        try store.cacheClassification("k", category: "coding", description: nil, project: nil)
        try store.deleteAll()
        check(try store.blocks(in: t0.addingTimeInterval(-1e6)..<t0.addingTimeInterval(1e6)).isEmpty, "all blocks gone")
        check(try store.cachedClassification("k") == nil, "cache cleared")
    }),

    ("excluded categories make blocks private or remove them", {
        var settings = ActivitySettings()
        check(settings.action(for: .entertainment) == .keep && settings.action(for: nil) == .keep, "nothing excluded by default")
        settings.excludedCategories = [.entertainment, .chat]
        check(settings.action(for: .entertainment) == .strip && settings.action(for: .coding) == .keep && settings.action(for: nil) == .keep, "strip")
        settings.removeBlocked = true
        check(settings.action(for: .chat) == .remove, "remove")
        let defaults = UserDefaults(suiteName: "activity-\(UUID().uuidString)")!
        defaults.register(defaults: ActivitySettings.defaults)
        check(ActivitySettings(defaults).excludedCategories.isEmpty && !ActivitySettings(defaults).removeBlocked, "defaults")
        defaults.set(["entertainment", "bogus", "code review"], forKey: ActivitySettings.excludedCategoriesKey)
        check(ActivitySettings(defaults).excludedCategories == [.entertainment, .codeReview], "read back, unknown dropped")

        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        func add(_ start: TimeInterval) throws -> Int64 {
            var b = block(start, start + 10, title: "Secret", url: "example.com/a", repo: "r", branch: "b", ticket: "AB-1",
                          claude: [ClaudeSession(id: "s", folder: "/f", title: "t")])
            b.id = 0
            b.typedExcerpt = "typed"
            return try store.saveBlock(b)
        }
        let kept = try add(0), stripped = try add(10), other = try add(20)
        try store.setClassification(ofBlock: kept, ActivityAI.Classification(category: .coding, description: "Coding"))
        try store.setClassification(ofBlock: stripped, ActivityAI.Classification(category: .entertainment, description: "Video"))
        check(try store.redact(blockIDs: [stripped], as: .private) == 1, "stripped")
        try store.setClassification(ofBlock: other, ActivityAI.Classification(category: .chat, description: "Chat"))
        var blocks = try store.blocks(in: t0..<t0.addingTimeInterval(100))
        check(blocks[0].key.windowTitle == "Secret" && blocks[0].aiDescription == "Coding", "kept")
        let s = blocks[1]
        check(s.key.windowTitle == nil && s.key.url == nil && s.key.repo == nil && s.key.branch == nil && s.key.ticket == nil
              && s.key.claude.isEmpty && s.typedExcerpt == nil && s.aiDescription == nil, "stripped \(s)")
        check(s.key.appName == "Xcode" && s.category == .entertainment && s.duration == 10, "app, times and category stay")
        var rules = ActivitySettings()
        rules.blockedApps = []
        check(try store.applyRules(rules) == 0, "nothing excluded")
        rules.excludedCategories = [.chat]
        check(try store.applyRules(rules) == 1, "existing chat block stripped")
        check(try store.blocks(in: t0..<t0.addingTimeInterval(100))[2].key.windowTitle == nil, "chat stripped")
        check(try store.applyRules(rules) == 0, "a private block is not stripped again")
        rules.excludedCategories = [.entertainment, .chat]
        rules.removeBlocked = true
        check(try store.applyRules(rules) == 2, "removed")
        blocks = try store.blocks(in: t0..<t0.addingTimeInterval(100))
        check(blocks.map(\.id) == [kept], "only the kept block remains")
    }),

    ("the claude session the user is in comes from their newest message and sticks to the block", {
        let a = ClaudeSession(id: "a", folder: "/f", title: "Strawberry kfm tickets"), b = ClaudeSession(id: "b", folder: "/g", title: "Other")
        let now = t0.addingTimeInterval(1000)
        let activity = [ClaudeActivity(session: a, lastUser: now.addingTimeInterval(-30), lastPrompt: "fix it"),
                        ClaudeActivity(session: b, lastUser: now.addingTimeInterval(-10), lastPrompt: nil)]
        check(ActivityLogic.focusedSession(activity, now: now, sticky: "a") == "b", "the newest typed-into session wins")
        let old = [ClaudeActivity(session: a, lastUser: now.addingTimeInterval(-300)), ClaudeActivity(session: b, lastUser: nil)]
        check(ActivityLogic.focusedSession(old, now: now, sticky: "a") == "a", "nothing new: the block keeps its session")
        check(ActivityLogic.focusedSession(old, now: now, sticky: nil) == nil, "nothing to stick to")

        check(ActivityLogic.isClaudeWindow(bundle: "com.anthropic.claudefordesktop", title: "Claude"), "desktop app")
        check(ActivityLogic.isClaudeWindow(bundle: "com.apple.Terminal", title: "\u{2733} Strawberry kfm tickets"), "terminal running claude")
        check(!ActivityLogic.isClaudeWindow(bundle: "com.apple.Terminal", title: "zsh") && !ActivityLogic.isClaudeWindow(bundle: "com.apple.Safari", title: "Claude"), "not claude")

        var focused = sample(0, app: "Claude", title: "Claude", claude: [a, b])
        focused.claudeFocus = "a"
        focused.claudePrompt = "fix it"
        var open = ActivityLogic.collapse(nil, with: focused).open
        var next = sample(5, app: "Claude", title: "Claude", claude: [a])
        next.claudeFocus = "a"
        var result = ActivityLogic.collapse(open, with: next)
        check(result.closed == nil && result.open.key.claude.map(\.id) == ["a", "b"] && result.open.claudePrompt == "fix it",
              "the lane changing does not split the block, its sessions and prompt are kept")
        open = result.open
        next.claudeFocus = "b"
        next.claude = [a, b]
        result = ActivityLogic.collapse(open, with: next)
        check(result.closed != nil && result.open.claudeFocusSession == b, "another session starts a new block")
        check(open.title == "Strawberry kfm tickets" && open.backgroundSessions == [b], "titled by the session, the rest is the lane")
        var withRepo = open
        withRepo.key.repo = "finq.api"
        check(ActivityAI.prompt(for: withRepo, projects: []).contains("Claude Code session: Strawberry kfm tickets\nLast request to Claude: fix it"),
              "prompt names the session")
        check(ActivityAI.cacheKey(open.key).hasSuffix("|strawberry kfm tickets"), "sessions are cached apart")
        var settings = ActivitySettings()
        settings.claude = false
        let off = ActivityLogic.filtered(focused, settings: settings)!
        check(off.claude.isEmpty && off.claudeFocus == nil && off.claudePrompt == nil, "claude off drops the session and prompt")

        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        open.id = try store.saveBlock(open)
        let read = try store.blocks(in: t0..<t0.addingTimeInterval(100)).first
        check(read?.key.claudeFocus == "a" && read?.claudePrompt == "fix it" && read?.key.claude.count == 2, "focus and prompt round-trip")
    }),

    ("the last prompt of a transcript skips tool results, meta entries and reminders", {
        let jsonl = """
        {"type":"user","timestamp":"2026-10-17T10:51:53.123Z","message":{"content":[{"type":"text","text":"<system-reminder>\\nctx\\n</system-reminder>\\nAdd   deleting\\nactivity <b>now</b>"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}
        {"type":"user","timestamp":"2026-10-17T10:52:00.000Z","message":{"content":[{"type":"tool_result","content":"x"}]}}
        {"type":"user","isMeta":true,"timestamp":"2026-10-17T10:52:01.000Z","message":{"content":[{"type":"text","text":"meta"}]}}
        {"type":"user","isSidechain":true,"timestamp":"2026-10-17T10:52:02.000Z","message":{"content":"agent prompt"}}
        {"type":"user","timestamp":"2026-10-17T10:52:03.000Z","message":{"content":"<command-name>/clear</command-name>"}}
        """
        let last = ActivityLogic.lastUserMessage(inJSONL: jsonl)
        check(last?.text == "Add deleting activity <b>now</b>", "cleaned '\(last?.text ?? "")'")
        check(abs((last?.time?.timeIntervalSince1970 ?? 0) - 1_792_234_313.123) < 0.001, "timestamp \(String(describing: last?.time?.timeIntervalSince1970))")
        check(ActivityLogic.lastUserMessage(inJSONL: "{\"type\":\"summary\"}") == nil, "none")
        let long = ActivityLogic.promptExcerpt(String(repeating: "word ", count: 60))!
        check(long.count <= 120 && long.hasSuffix("\u{2026}"), "cut to 120")
        check(ActivityLogic.promptExcerpt("<system-reminder>only</system-reminder>") == nil, "only a reminder")
    }),

    ("a session's folder maps to its repository, a worktree to its parent and own branch", {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("git/quiddly/finq.api")
        let worktree = repo.appendingPathComponent(".claude/worktrees/strawberry-tickets-518556")
        let gitdir = repo.appendingPathComponent(".git/worktrees/strawberry-tickets-518556")
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/NI/QDLY-8700\n".write(to: gitdir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(gitdir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let fromWorktree = ActivityLogic.claudeCheckout(cwd: worktree.appendingPathComponent("src").path)
        check(fromWorktree?.repo == "finq.api" && fromWorktree?.checkout.path == worktree.path, "worktree \(String(describing: fromWorktree))")
        check(fromWorktree.flatMap { ActivityLogic.branch(ofRepository: $0.checkout) } == "NI/QDLY-8700", "the worktree's branch")
        let nested = ActivityLogic.claudeCheckout(cwd: repo.appendingPathComponent("docs/deep").path)
        check(nested?.repo == "finq.api" && nested.flatMap { ActivityLogic.branch(ofRepository: $0.checkout) } == "main", "nearest repository")
        check(ActivityLogic.claudeCheckout(cwd: "/Users/me/Library/Application Support/Claude/scratch-workspaces/x/scratch") == nil, "scratch")
        check(ActivityLogic.claudeCheckout(cwd: root.appendingPathComponent("plain").path) == nil, "no repository")
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
