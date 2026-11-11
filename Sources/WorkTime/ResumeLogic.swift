import Foundation

/// What the user works on: a repository and branch, else a Jira ticket. Two keys are the same context when their ids match,
/// so a ticket read from a window title does not make a branch a new context.
struct ResumeContextKey: Hashable, Sendable {
    var repo: String?
    var branch: String?
    var ticket: String?

    var id: String {
        if let repo, let branch { return "\(repo)@\(branch)" }
        return ticket ?? ""
    }

    var title: String {
        if let repo, let branch { return "\(repo) \u{00B7} \(branch)" }
        return ticket ?? ""
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The context of a block, nil for one that is not on a branch or ticket.
    static func of(_ key: ActivityKey) -> ResumeContextKey? {
        guard !key.idle, key.redaction == nil else { return nil }
        let ticket = ActivityLogic.ticket(of: key)
        if let repo = key.repo, let branch = key.branch { return ResumeContextKey(repo: repo, branch: branch, ticket: ticket) }
        return ticket.map { ResumeContextKey(ticket: $0) }
    }

    /// Blocks on the same branch, or anywhere on the same ticket (its Jira page, its pull request).
    func matches(_ key: ActivityKey) -> Bool {
        guard !key.idle else { return false }
        if let repo, let branch, key.repo == repo, key.branch == branch { return true }
        return ticket != nil && ActivityLogic.ticket(of: key) == ticket
    }
}

struct ResumeSettings: Equatable {
    static let enabledKey = "resumeCardEnabled"
    static let gapKey = "resumeCardGapHours"
    static let gapChoices: [Double] = [1, 2, 4, 8, 24]
    static let defaults: [String: Any] = [enabledKey: true, gapKey: 2.0]
    /// How long the user has to stay in a context before it counts as switched to.
    static let steady: TimeInterval = 30

    var enabled = true
    var gap: TimeInterval = 7200

    init(enabled: Bool = true, gap: TimeInterval = 7200) {
        self.enabled = enabled
        self.gap = gap
    }

    init(_ defaults: UserDefaults) {
        defaults.register(defaults: Self.defaults)
        enabled = defaults.bool(forKey: Self.enabledKey)
        gap = max(defaults.double(forKey: Self.gapKey), 0.25) * 3600
    }
}

/// Watches the context of each sample and says when the user has settled in one they came back to: after `steady` seconds in
/// it, once per arrival. Samples without a context (another app, away) leave the candidate alone, so a glance at Slack is
/// not a switch; coming back after `gap` without any other context in between is.
struct ResumeTrigger: Equatable {
    var current: ResumeContextKey?
    private(set) var candidate: ResumeContextKey?
    private(set) var since = Date.distantPast
    private var fired = true
    private var returning = false
    private var lastSeen: [String: Date] = [:]

    init() {}

    /// The context to announce with the time the user entered it, when this sample settles one.
    mutating func observe(_ key: ResumeContextKey?, at now: Date, steady: TimeInterval = ResumeSettings.steady,
                          gap: TimeInterval) -> (key: ResumeContextKey, entered: Date)? {
        guard let key else { return nil }
        let seen = lastSeen[key.id]
        lastSeen[key.id] = now
        let cameBack = seen.map { now.timeIntervalSince($0) >= gap } ?? false
        if key != candidate || cameBack {
            candidate = key
            since = now
            fired = false
            returning = cameBack
        }
        guard !fired, now.timeIntervalSince(since) >= steady else { return nil }
        fired = true
        defer { current = key }
        return key != current || returning ? (key, since) : nil
    }
}

struct ResumePrompt: Equatable, Sendable {
    var session: String
    var text: String
    var date: Date?
}

/// The user's last stretch of time in a context.
struct ResumeVisit: Equatable, Sendable {
    var start: Date
    var end: Date
    var active: TimeInterval
    var sessions: [ClaudeSession] = []
    var prompts: [String] = []
}

struct ResumeComment: Equatable, Sendable {
    var author: String
    var text: String
    var date: Date?
}

struct ResumePR: Equatable, Sendable {
    var url: String
    var repo: String
    var number: Int
    var title: String
    var state: GitHubPR.State
    var checks: GitHubPR.Checks
    var review: GitHubPR.Review?
    var unresolved: Int?
    var newCommits: [String] = []
    var newComments: [ResumeComment] = []
    var finishedChecks: [String] = []
    /// When nothing more than the list row is cached.
    var listOnly = false

    var hasChanges: Bool { !newCommits.isEmpty || !newComments.isEmpty || !finishedChecks.isEmpty }
}

struct ResumeTicket: Equatable, Sendable {
    var key: String
    var summary: String
    var status: String
    var assignee: String?
    var url: String?
    var changes: [String] = []
    var newComments: [ResumeComment] = []
}

struct ResumeMention: Equatable, Sendable {
    var meeting: Int64
    var title: String
    var date: Date
    var line: String
}

struct ResumeAgent: Equatable, Sendable {
    var key: String
    var title: String
    var prURL: String?
    var jiraKey: String?
    var status: String
    var lastPrompt: String?
    var lastResult: String?
}

struct ResumeCard: Equatable, Sendable {
    var key: ResumeContextKey
    var entered: Date
    var visit: ResumeVisit?
    var prompts: [ResumePrompt] = []
    var pr: ResumePR?
    var ticket: ResumeTicket?
    var meetings: [ResumeMention] = []
    var agent: ResumeAgent?

    var gap: TimeInterval? { visit.map { entered.timeIntervalSince($0.end) } }
}

enum ResumeLogic {
    static let lookbackDays = 30
    /// Meetings this long before a visit started still count as around it.
    static let meetingLead: TimeInterval = 12 * 3600
    /// Blocks closer than this belong to the same visit.
    static let visitGap: TimeInterval = 1800

    /// The latest visit to `key` before `before`: its matching blocks, merged while less than `visitGap` apart.
    static func lastVisit(_ blocks: [ActivityBlock], key: ResumeContextKey, before: Date, mergeGap: TimeInterval = visitGap) -> ResumeVisit? {
        let matching = blocks.filter { $0.start < before && key.matches($0.key) }
            .map { block -> ActivityBlock in
                var block = block
                block.end = min(block.end, before)
                return block
            }
            .sorted { $0.start < $1.start }
        guard var index = matching.indices.last else { return nil }
        var start = matching[index].start
        while index > 0, start.timeIntervalSince(matching[index - 1].end) < mergeGap {
            index -= 1
            start = min(start, matching[index].start)
        }
        let visit = Array(matching[index...])
        var sessions: [ClaudeSession] = []
        for session in visit.reversed().compactMap(\.claudeFocusSession) where !sessions.contains(where: { $0.id == session.id }) {
            sessions.append(session)
        }
        var prompts: [String] = []
        for prompt in visit.reversed().compactMap(\.claudePrompt) where !prompt.isEmpty && !prompts.contains(prompt) { prompts.append(prompt) }
        return ResumeVisit(start: start, end: visit.map(\.end).max() ?? start, active: visit.reduce(0) { $0 + $1.duration },
                           sessions: sessions, prompts: prompts)
    }

    static func shouldShow(_ visit: ResumeVisit?, entered: Date, gap: TimeInterval) -> Bool {
        visit.map { entered.timeIntervalSince($0.end) >= gap } ?? false
    }

    /// The latest context the user was in before `now`, for "where was I" without arguments.
    static func latestContext(_ blocks: [ActivityBlock]) -> ResumeContextKey? {
        blocks.sorted { $0.end > $1.end }.lazy.compactMap { ResumeContextKey.of($0.key) }.first
    }

    /// A context from what an agent asked about: a branch (with its repository, else the latest one it was on), a repository
    /// (its latest branch), or a ticket.
    static func context(repo: String?, branch: String?, ticket: String?, blocks: [ActivityBlock]) -> ResumeContextKey? {
        let repo = repo.map(repoName), latest = blocks.sorted { $0.end > $1.end }
        if let branch {
            let owner = repo ?? latest.first { $0.key.branch == branch }?.key.repo
            guard let owner else { return ticket.map { ResumeContextKey(ticket: $0) } }
            return ResumeContextKey(repo: owner, branch: branch, ticket: ticket ?? ActivityLogic.ticket(in: branch))
        }
        if let repo {
            guard let block = latest.first(where: { $0.key.repo == repo && $0.key.branch != nil }) else { return nil }
            return ResumeContextKey(repo: repo, branch: block.key.branch, ticket: ActivityLogic.ticket(of: block.key))
        }
        return ticket.map { ResumeContextKey(ticket: $0) }
    }

    /// `finq.api` from `quiddly-com/finq.api` or a GitHub url.
    static func repoName(_ text: String) -> String {
        text.split(separator: "/").last.map(String.init) ?? text
    }

    // MARK: Claude

    /// The prompts the user typed in a transcript up to `until`, newest first.
    static func prompts(inJSONL jsonl: String, until: Date, limit: Int = 2) -> [(time: Date?, text: String)] {
        var found: [(time: Date?, text: String)] = []
        for line in jsonl.split(whereSeparator: \.isNewline).reversed() where found.count < limit {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "user", object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let text = ActivityLogic.userText(message["content"]).flatMap({ ActivityLogic.promptExcerpt($0, limit: 200) }) else { continue }
            let time = (object["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
            if let time, time > until { continue }
            found.append((time, text))
        }
        return found
    }

    // MARK: GitHub

    /// The pull request of a context: the one whose head is the branch, else one in the repository titled with its ticket.
    static func pullRequest(for key: ResumeContextKey, in prs: [GitHubPR], head: (String) -> String?) -> GitHubPR? {
        let candidates = prs.filter { key.repo == nil || repoName($0.repo) == key.repo }.sorted { $0.updated > $1.updated }
        if let branch = key.branch, let pr = candidates.first(where: { head($0.url) == branch }) { return pr }
        guard let ticket = key.ticket else { return nil }
        return candidates.first { $0.ticket == ticket || ActivityLogic.ticket(in: $0.title) == ticket }
    }

    /// What happened on a pull request since `since`: commits, comments from others and checks that finished.
    static func changes(_ pr: GitHubPR, detail: GitHubPRDetail?, comments: GitHubComments?, since: Date) -> ResumePR {
        var result = ResumePR(url: pr.url, repo: pr.repo, number: pr.number, title: pr.title, state: pr.state, checks: detail?.rollup ?? pr.checks,
                              review: detail?.review ?? pr.review, unresolved: comments?.unresolved)
        let me = comments?.me ?? pr.activity?.me ?? ""
        if let detail {
            result.newCommits = detail.commits.filter { ($0.date ?? .distantPast) > since }.map(\.headline)
            result.finishedChecks = detail.checks.filter { ($0.completed ?? .distantPast) > since }
                .sorted { $0.status.rawValue < $1.status.rawValue }
                .map { "\($0.name) \(checkWord($0.status))" }
        } else if let last = pr.activity?.lastCommit, last > since {
            result.newCommits = ["New commits"]
        }
        if let comments {
            let all = comments.threads.flatMap(\.comments) + comments.conversation
            result.newComments = all.filter { ($0.created ?? .distantPast) > since && $0.author.login != me && !$0.author.isBot }
                .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
                .map { ResumeComment(author: $0.author.login, text: oneLine($0.body), date: $0.created) }
        } else if let activity = pr.activity {
            let events = (activity.open + [activity.lastComment].compactMap { $0 }).filter { $0.date > since && $0.actor.login != me && !$0.actor.isBot }
            result.newComments = events.map { ResumeComment(author: $0.actor.login, text: "commented", date: $0.date) }
        }
        result.listOnly = detail == nil
        return result
    }

    static func checkWord(_ status: GitHubPRDetail.CheckStatus) -> String {
        switch status {
        case .failed: "failed"
        case .running: "running"
        case .pending: "pending"
        case .cancelled: "cancelled"
        case .passed: "passed"
        case .skipped: "skipped"
        }
    }

    // MARK: Jira

    static func issuePath(_ key: String) -> String { JiraLogic.issuePath(key) + "&expand=changelog" }

    struct JiraChange: Equatable {
        var author: String
        var date: Date
        var field: String
        var from: String?
        var to: String?
    }

    /// Status and assignee changes in an issue's `changelog`.
    static func parseChangelog(_ data: Data, fields: Set<String> = ["status", "assignee"]) -> [JiraChange] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let histories = (object["changelog"] as? [String: Any])?["histories"] as? [[String: Any]] else { return [] }
        return histories.flatMap { history -> [JiraChange] in
            guard let date = (history["created"] as? String).flatMap(JiraLogic.date) else { return [] }
            let author = (history["author"] as? [String: Any])?["displayName"] as? String ?? "Someone"
            return (history["items"] as? [[String: Any]] ?? []).compactMap { item in
                guard let field = item["field"] as? String, fields.contains(field) else { return nil }
                return JiraChange(author: author, date: date, field: field, from: item["fromString"] as? String, to: item["toString"] as? String)
            }
        }
    }

    static func ticket(_ issue: JiraIssue, changes: [JiraChange], since: Date, url: String?) -> ResumeTicket {
        let lines = changes.filter { $0.date > since }.sorted { $0.date < $1.date }.map { change in
            "\(change.field.capitalized): \(change.from ?? "none") \u{2192} \(change.to ?? "none") (\(change.author))"
        }
        let comments = issue.comments.filter { ($0.created ?? .distantPast) > since }
            .map { ResumeComment(author: $0.author, text: oneLine($0.body), date: $0.created) }
        return ResumeTicket(key: issue.key, summary: issue.summary, status: issue.status, assignee: issue.assignee, url: url,
                            changes: lines, newComments: comments.reversed())
    }

    // MARK: Meetings

    /// The first line of a meeting's text that names the ticket, else the pull request, else the repository.
    static func mentionLine(in text: String, ticket: String?, prNumber: Int?, repo: String?) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for pattern in mentionPatterns(ticket: ticket, prNumber: prNumber, repo: repo) {
            if let line = lines.first(where: { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }) {
                return ActivityLogic.truncate(line, to: 200)
            }
        }
        return nil
    }

    /// `QDLY-1234` also as said aloud (`QDLY 1234`), a pull request as `#12`, `PR 12` or `pull request 12`, and the repository as
    /// a word.
    static func mentionPatterns(ticket: String?, prNumber: Int?, repo: String?) -> [String] {
        var patterns: [String] = []
        if let ticket, let dash = ticket.firstIndex(of: "-") {
            patterns.append("\\b\(NSRegularExpression.escapedPattern(for: String(ticket[..<dash])))[- ]?\(ticket[ticket.index(after: dash)...])\\b")
        }
        if let prNumber { patterns.append("(#|\\bPR ?|\\bpull request )\(prNumber)\\b") }
        if let repo, repo.count >= 3 { patterns.append("(^|[^\\w.-])\(NSRegularExpression.escapedPattern(for: repo))($|[^\\w-])") }
        return patterns
    }

    /// Search words for the meeting index: the ticket key, then the repository.
    static func meetingQueries(ticket: String?, repo: String?) -> [String] {
        [ticket, repo].compactMap { $0 }
    }

    // MARK: Agents

    static func agent(in agents: [AgentState], prURL: String?, ticket: String?) -> ResumeAgent? {
        let found = agents.first { prURL != nil && $0.prURL == prURL } ?? agents.first { ticket != nil && $0.jiraKey == ticket }
        return found.map {
            ResumeAgent(key: $0.key, title: $0.title, prURL: $0.prURL, jiraKey: $0.jiraKey, status: $0.status.rawValue.replacingOccurrences(of: "_", with: " "),
                        lastPrompt: $0.lastPrompt.map { oneLine($0) }, lastResult: $0.lastResult.map { oneLine($0) })
        }
    }

    // MARK: Text

    static func oneLine(_ text: String, limit: Int = 200) -> String {
        ActivityLogic.truncate(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces), to: limit)
    }

    /// "Last here Tue 14:10–16:40 · 1h 52m active · 5 h ago".
    static func visitLine(_ visit: ResumeVisit, now: Date) -> String {
        let day = Calendar.current.isDate(visit.start, inSameDayAs: now) ? "today" : visit.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let times = "\(visit.start.formatted(date: .omitted, time: .shortened))\u{2013}\(visit.end.formatted(date: .omitted, time: .shortened))"
        return "Last here \(day) \(times) \u{00B7} \(ActivityLogic.hoursText(visit.active)) active \u{00B7} \(ClaudePlugin.ago(visit.end, now: now))"
    }

    static func markdown(_ card: ResumeCard, now: Date) -> String {
        var out = "# \(card.key.title)\n\n" + (card.visit.map { visitLine($0, now: now) } ?? "No tracked time here in the last \(lookbackDays) days.") + "\n"
        let prompts = card.prompts.map { "- \($0.session): \($0.text)" } + (card.visit?.prompts ?? []).filter { prompt in
            !card.prompts.contains { $0.text.hasPrefix(prompt.prefix(60)) }
        }.map { "- \($0)" }
        if !prompts.isEmpty { out += "\n## Last Claude prompts\n" + prompts.joined(separator: "\n") + "\n" }
        if let pr = card.pr {
            out += "\n## Pull request \(pr.repo)#\(pr.number): \(pr.title)\n\(pr.url)\n"
            out += "- \(pr.state.rawValue), checks \(pr.checks.rawValue)" + (pr.review.map { ", review \($0.rawValue)" } ?? "")
                + (pr.unresolved.map { ", \($0) unresolved threads" } ?? "") + "\n"
            if !pr.newCommits.isEmpty { out += "- New commits since: " + pr.newCommits.prefix(5).joined(separator: "; ") + "\n" }
            if !pr.finishedChecks.isEmpty { out += "- Checks finished since: " + pr.finishedChecks.prefix(8).joined(separator: ", ") + "\n" }
            out += pr.newComments.prefix(5).map { "- \($0.author): \($0.text)\n" }.joined()
            if !pr.hasChanges { out += "- Nothing new since then" + (pr.listOnly ? " in the cached list (detail not fetched)" : "") + "\n" }
        }
        if let ticket = card.ticket {
            out += "\n## Jira \(ticket.key): \(ticket.summary)\n" + (ticket.url.map { "\($0)\n" } ?? "")
            out += "- \(ticket.status)" + (ticket.assignee.map { ", assigned to \($0)" } ?? ", unassigned") + "\n"
            out += ticket.changes.map { "- \($0)\n" }.joined() + ticket.newComments.prefix(5).map { "- \($0.author): \($0.text)\n" }.joined()
            if ticket.changes.isEmpty && ticket.newComments.isEmpty { out += "- No status, assignee or comment changes since then\n" }
        }
        if !card.meetings.isEmpty {
            out += "\n## Meetings that mentioned it\n" + card.meetings.map {
                "- \(ActivityLogic.dateText($0.date)) \($0.title) (meeting id \($0.meeting)): \($0.line)"
            }.joined(separator: "\n") + "\n"
        }
        if let agent = card.agent {
            out += "\n## Agent \(agent.title)\n- \(agent.status)" + (agent.lastResult.map { "\n- Last result: \($0)" } ?? "") + "\n"
        }
        return out
    }
}
