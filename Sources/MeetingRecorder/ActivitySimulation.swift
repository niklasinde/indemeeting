#if DEBUG
import AppKit
import Foundation

/// Debug builds only: `--simulate-activity <samples.json>` feeds samples through the tracker into the data directory's
/// database and prints the blocks of that day, so the capture pipeline can be checked without Accessibility access.
/// Each sample is `{"offset": seconds, "app": ..., "bundle": ..., "title": ..., "url": ..., "repo": ..., "branch": ...,
/// "claude": [{"id": ..., "folder": ..., "title": ...}], "idle": false}`; offsets count from the first sample's time,
/// which is now minus the span.
enum ActivitySimulation {
    @MainActor
    static func run(_ file: URL) -> Never {
        let store = MeetingStore.openDefault()
        do {
            if let error = store.openError { throw error }
            let samples = try decode(try Data(contentsOf: file))
            let tracker = ActivityTracker(store: store)
            UserDefaults.standard.set(true, forKey: ActivitySettings.enabledKey)
            samples.forEach { tracker.ingest($0) }
            tracker.flush()
            let day = ActivityLogic.day(containing: samples.first?.time ?? Date())
            let blocks = try store.blocks(in: day)
            for block in blocks {
                let key = block.key
                let fields = [key.appName, key.windowTitle, key.url, key.repo.map { "repo \($0)" }, key.branch.map { "branch \($0)" },
                              key.ticket, key.claude.isEmpty ? nil : "claude " + key.claude.map(\.title).joined(separator: ", ")]
                print("\(block.start.formatted(date: .omitted, time: .standard))  \(Int(block.duration))s  "
                      + (key.idle ? "away" : fields.compactMap { $0 }.joined(separator: " | ")))
            }
            print("\(blocks.count) blocks")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> [ActivitySample] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SQLiteError(message: "expected a JSON array of samples")
        }
        let span = items.compactMap { $0["offset"] as? Double }.max() ?? 0
        let start = now.addingTimeInterval(-span - ActivitySettings.interval)
        return items.map { item in
            let claude = (item["claude"] as? [[String: String]] ?? []).compactMap { session in
                session["id"].map { ClaudeSession(id: $0, folder: session["folder"] ?? "", title: session["title"] ?? "") }
            }
            return ActivitySample(time: start.addingTimeInterval(item["offset"] as? Double ?? 0), appBundle: item["bundle"] as? String,
                                  appName: item["app"] as? String, windowTitle: item["title"] as? String, url: item["url"] as? String,
                                  repo: item["repo"] as? String, branch: item["branch"] as? String,
                                  ticket: item["ticket"] as? String ?? ActivityLogic.ticket(in: item["branch"] as? String, item["title"] as? String),
                                  claude: claude, idle: item["idle"] as? Bool ?? false)
        }
    }
}

/// A week of made-up activity for the previews.
enum SampleActivity {
    static func write(to store: MeetingStore, now: Date) throws {
        let quiddly = try store.addProject("Quiddly")
        let inde = try store.addProject("Inde")
        try store.addRule(project: quiddly.id, field: .repo, pattern: "finq.api")
        try store.addRule(project: quiddly.id, field: .ticket, pattern: "QDLY")
        try store.addRule(project: quiddly.id, field: .host, pattern: "quiddly.atlassian.net")
        try store.addRule(project: inde.id, field: .repo, pattern: "indemeeting")
        let calendar = Calendar.current
        let claude = ClaudeSession(id: "31f99ea7", folder: "/Users/niklasinde/git/inde/indemeeting", title: "Activity tracking inside MeetingRecorder")
        let api = ClaudeSession(id: "a92d893c", folder: "/Users/niklasinde/git/quiddly/finq.api", title: "Fix the ISD-13089 reminder fee rounding")
        func block(_ dayOffset: Int, _ from: Double, _ to: Double, app: (String, String), title: String? = nil, url: String? = nil,
                   repo: String? = nil, branch: String? = nil, claude: [ClaudeSession] = [], idle: Bool = false,
                   category: ActivityCategory? = nil, description: String? = nil, excerpt: String? = nil, guess: Int64? = nil,
                   focus: ClaudeSession? = nil, prompt: String? = nil, redaction: ActivityRedaction? = nil) throws {
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: dayOffset, to: now)!)
            let anonymous = idle || redaction == .other
            let key = ActivityLogic.linked(ActivityKey(appBundle: anonymous ? nil : app.0, appName: anonymous ? nil : app.1, windowTitle: title, url: url, repo: repo,
                                  branch: branch, ticket: ActivityLogic.ticket(in: branch, title, url), claude: claude, idle: idle,
                                  claudeFocus: focus?.id, redaction: redaction))
            try store.saveBlock(ActivityBlock(id: 0, start: day.addingTimeInterval(from * 3600), end: day.addingTimeInterval(to * 3600),
                                              key: key, projectID: nil, typedExcerpt: excerpt, category: category, aiDescription: description,
                                              aiProjectID: guess, claudePrompt: prompt))
        }
        let xcode = ("com.apple.dt.Xcode", "Xcode")
        let pycharm = ("com.jetbrains.pycharm", "PyCharm")
        let safari = ("com.apple.Safari", "Safari")
        let slack = ("com.tinyspeck.slackmacgap", "Slack")
        let terminal = ("com.apple.Terminal", "Terminal")
        let claudeApp = ("com.anthropic.claudefordesktop", "Claude")
        for dayOffset in [-4, -3, -2, -1, 0] {
            try block(dayOffset, 8.5, 9.0, app: slack, title: "general (Quiddly) \u{2014} Slack", category: .chat, description: "Chatting in the Quiddly general channel",
                      excerpt: "Jag tittar p\u{00E5} avrundningen i p\u{00E5}minnelseavgifterna efter standup", guess: quiddly.id)
            try block(dayOffset, 9.0, 9.25, app: safari, url: "quiddly.atlassian.net/browse/QDLY-8296", category: .planning, description: "Reading the QDLY-8296 ticket")
            try block(dayOffset, 9.25, 10.75, app: pycharm, title: "finq.api \u{2013} reminder_fees.py", repo: "finq.api", branch: "NI/QDLY-8296",
                      claude: [api], category: .coding, description: "Editing reminder fee rounding")
            try block(dayOffset, 10.75, 11.0, app: terminal, title: "finq.api \u{2014} pytest \u{2014} 80\u{00D7}24", repo: "finq.api", branch: "NI/QDLY-8296",
                      category: .coding, description: "Running the test suite")
            try block(dayOffset, 11.0, 12.0, app: safari, url: "github.com/quiddly-com/finq.api/pull/1966", claude: [api], category: .codeReview,
                      description: "Reviewing the reminder fee pull request", guess: quiddly.id)
            try block(dayOffset, 12.0, 12.75, app: slack, idle: true)
            try block(dayOffset, 12.75, 15.5, app: xcode, title: "ActivityView.swift \u{2014} indemeeting", repo: "indemeeting", branch: "main",
                      claude: [claude], category: .coding, description: "Building the activity day view")
            try block(dayOffset, 15.5, 16.0, app: claudeApp, title: "Claude", repo: "indemeeting", branch: "main", claude: [claude, api],
                      focus: claude, prompt: "Add deleting activity: a Delete item in the block popover and a context menu on each row")
            if dayOffset.isMultiple(of: 2) { try block(dayOffset, 16.0, 16.5, app: safari, url: "developer.apple.com/documentation/swiftui/layout") }
        }
        try block(0, 16.5, 17.0, app: slack, title: "niklas \u{2014} Slack")
        try block(0, 17.0, 17.25, app: safari, redaction: .other)
        try block(0, 17.25, 17.5, app: slack, redaction: .other)
        try block(0, 17.5, 17.75, app: safari, redaction: .otherSite)
    }
}
#endif
