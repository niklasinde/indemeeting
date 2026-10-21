import Foundation

enum GitHubKind: String, CaseIterable, Identifiable {
    case created
    case reviewRequested = "review_requested"
    case assigned
    case mentioned

    var id: String { rawValue }

    var tabTitle: String {
        switch self {
        case .created: return "Created"
        case .reviewRequested: return "Review requested"
        case .assigned: return "Assigned"
        case .mentioned: return "Mentioned"
        }
    }

    var noun: String { tabTitle.lowercased() }

    fileprivate var qualifier: String {
        switch self {
        case .created: return "author:@me"
        case .reviewRequested: return "review-requested:@me"
        case .assigned: return "assignee:@me"
        case .mentioned: return "mentions:@me"
        }
    }
}

struct GitHubPR: Equatable, Identifiable {
    enum State: String { case open, merged, closed }
    enum Checks: String { case passed, failed, running, none }
    enum Review: String { case approved, changesRequested = "changes_requested", required }

    var id: String { url }
    let url: String
    let number: Int
    let title: String
    let repo: String
    var isDraft = false
    var state = State.open
    var updated: Date
    var review: Review?
    var checks = Checks.none
    var author: String?
    var additions = 0
    var deletions = 0
    var comments = 0
    var labels: [String] = []
    var activity: GitHubActivity?

    var ticket: String? {
        ActivityLogic.ticket(in: title).flatMap { title.hasPrefix($0) ? $0 : nil }
    }

    var copyText: String { title }
}

enum GitHubError: Error, Equatable {
    case cliMissing
    case notLoggedIn
    case rateLimited
    case sso(String)
    case offline
    case failed(String)

    static let installCommand = "brew install gh"
    static let loginCommand = "gh auth login"

    var message: String {
        switch self {
        case .cliMissing: return "The GitHub CLI is not installed. Install it, then sign in."
        case .notLoggedIn: return "The GitHub CLI is not signed in. Run the command below in a terminal, then refresh."
        case .rateLimited: return "GitHub's rate limit is reached. Showing the last fetched pull requests; try again in a few minutes."
        case .sso(let detail): return "An organisation requires you to authorise the GitHub CLI for SAML single sign-on. \(detail)"
        case .offline: return "GitHub cannot be reached. Showing the last fetched pull requests."
        case .failed(let detail): return "GitHub returned an error: \(detail)"
        }
    }

    /// The command to run in a terminal, when there is one.
    var command: String? {
        switch self {
        case .cliMissing: return Self.installCommand
        case .notLoggedIn: return Self.loginCommand
        default: return nil
        }
    }

    /// Reads what `gh` printed on stderr.
    static func classify(_ stderr: String) -> GitHubError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { lowered.contains($0) } }
        if has("rate limit", "abuse detection") { return .rateLimited }
        if has("saml", "single sign-on") { return .sso(text.split(separator: "\n").last.map(String.init) ?? "") }
        if has("not logged in", "gh auth login", "bad credentials", "http 401", "requires authentication", "no oauth token") { return .notLoggedIn }
        if has("error connecting", "no such host", "could not resolve", "network is unreachable", "timeout", "timed out",
               "connection refused", "internet connection appears to be offline") { return .offline }
        return .failed(ActivityLogic.truncate(text.split(separator: "\n").first.map(String.init) ?? "unknown error", to: 160))
    }
}

enum GitHubLogic {
    static let pageSize = 50
    static let closedPageSize = 30
    static let host = "github.com"
    /// The UserDefaults key of the GitHub switch in Settings.
    static let enabledKey = "githubEnabled"

    struct Search: Equatable {
        let kind: GitHubKind
        let terms: String
        let limit: Int
        var discussion = true
    }

    /// Open pull requests for every tab; the ones you created also come with the latest closed and merged.
    static func searches(for kind: GitHubKind) -> [Search] {
        func terms(_ state: String) -> String { "\(kind.qualifier) is:pr is:\(state) archived:false sort:updated-desc" }
        let open = Search(kind: kind, terms: terms("open"), limit: pageSize)
        return kind == .created ? [open, Search(kind: kind, terms: terms("closed"), limit: closedPageSize, discussion: false)] : [open]
    }

    /// Review threads looked at per pull request. The query's cost is mostly this times the page size.
    static let threadPageSize = 20

    private static let discussionFields = """
        lastComment: comments(last: 1) { nodes { author { login __typename } createdAt } }
        reviews { totalCount }
        latestReviews(first: 10) { nodes { author { login __typename } state submittedAt } }
        reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
        reviewThreads(first: \(threadPageSize)) {
          totalCount
          nodes { isResolved comments(last: 1) { nodes { author { login __typename } createdAt } } }
        }
        """

    /// The search with the discussion fields, or without them for the closed and merged pull requests, which need no attention.
    static func query(discussion: Bool) -> String {
        """
        query($q: String!, $first: Int!) {
          rateLimit { cost remaining }
          viewer { login }
          search(query: $q, type: ISSUE, first: $first) {
            nodes {
              ... on PullRequest {
                number title url isDraft state merged updatedAt reviewDecision additions deletions
                repository { nameWithOwner }
                author { login __typename }
                comments { totalCount }
                labels(first: 5) { nodes { name } }
                commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
                \(discussion ? discussionFields : "")
              }
            }
          }
        }
        """
    }

    static func arguments(for search: Search) -> [String] {
        ["api", "graphql", "-f", "query=\(query(discussion: search.discussion))", "-f", "q=\(search.terms)", "-F", "first=\(search.limit)"]
    }

    static let authArguments = ["auth", "status", "--hostname", host]

    // MARK: Parsing

    private struct Response: Decodable {
        struct Node: Decodable {
            struct Named: Decodable { let login: String?; let __typename: String? }
            struct Stamped: Decodable { let author: Named?; let createdAt: String? }
            struct Items<Item: Decodable>: Decodable { let totalCount: Int?; let nodes: [Item?]? }
            struct LatestReview: Decodable { let author: Named?; let state: String?; let submittedAt: String? }
            struct Request: Decodable { let requestedReviewer: Named? }
            struct Thread: Decodable { let isResolved: Bool?; let comments: Items<Stamped>? }
            struct Repository: Decodable { let nameWithOwner: String? }
            struct Count: Decodable { let totalCount: Int? }
            struct Labels: Decodable {
                struct Label: Decodable { let name: String }
                let nodes: [Label?]?
            }
            struct Commits: Decodable {
                struct Item: Decodable {
                    struct Commit: Decodable {
                        struct Rollup: Decodable { let state: String? }
                        let committedDate: String?
                        let statusCheckRollup: Rollup?
                    }
                    let commit: Commit?
                }
                let nodes: [Item?]?
            }
            let number: Int?
            let title: String?
            let url: String?
            let isDraft: Bool?
            let state: String?
            let merged: Bool?
            let updatedAt: String?
            let reviewDecision: String?
            let additions: Int?
            let deletions: Int?
            let repository: Repository?
            let author: Named?
            let comments: Count?
            let labels: Labels?
            let commits: Commits?
            let lastComment: Items<Stamped>?
            let reviews: Items<LatestReview>?
            let latestReviews: Items<LatestReview>?
            let reviewRequests: Items<Request>?
            let reviewThreads: Items<Thread>?
        }
        struct Search: Decodable { let nodes: [Node?]? }
        struct Viewer: Decodable { let login: String? }
        struct Cost: Decodable { let cost: Int?; let remaining: Int? }
        struct Payload: Decodable { let search: Search?; let viewer: Viewer?; let rateLimit: Cost? }
        struct Failure: Decodable { let message: String? }
        let data: Payload?
        let errors: [Failure]?
    }

    struct Page: Equatable {
        var prs: [GitHubPR] = []
        var cost = 0
        var remaining: Int?
    }

    /// The pull requests in a GraphQL search response. Results that are not pull requests are skipped.
    static func parse(_ data: Data) throws -> [GitHubPR] { try parsePage(data).prs }

    static func parsePage(_ data: Data) throws -> Page {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch {
            throw GitHubError.failed("unexpected response")
        }
        guard let nodes = response.data?.search?.nodes else {
            throw GitHubError.classify(response.errors?.compactMap(\.message).joined(separator: "\n") ?? "no data")
        }
        let me = response.data?.viewer?.login ?? ""
        return Page(prs: nodes.compactMap { $0.flatMap { pullRequest($0, me: me) } }, cost: response.data?.rateLimit?.cost ?? 0,
                    remaining: response.data?.rateLimit?.remaining)
    }

    static func date(_ text: String?) -> Date? { text.flatMap { ISO8601DateFormatter().date(from: $0) } }

    private static func actor(_ named: Response.Node.Named?) -> GitHubActivity.Actor {
        GitHubActivity.Actor(login: named?.login ?? "ghost", isBot: named?.__typename == "Bot")
    }

    private static func event(_ stamped: Response.Node.Stamped?) -> GitHubActivity.Event? {
        stamped.flatMap { stamp in date(stamp.createdAt).map { GitHubActivity.Event(actor: actor(stamp.author), date: $0) } }
    }

    private static func activity(_ node: Response.Node, me: String) -> GitHubActivity {
        let open = (node.reviewThreads?.nodes ?? []).compactMap { $0 }.filter { $0.isResolved == false }
            .compactMap { event($0.comments?.nodes?.compactMap { $0 }.last) }
        let reviews = (node.latestReviews?.nodes ?? []).compactMap { review -> GitHubActivity.Review? in
            guard let review, let state = review.state, let submitted = date(review.submittedAt) else { return nil }
            return GitHubActivity.Review(actor: actor(review.author), state: state, date: submitted)
        }
        return GitHubActivity(me: me, authorIsBot: node.author?.__typename == "Bot", threads: node.reviewThreads?.totalCount ?? 0, open: open,
                              reviews: reviews, reviewCount: node.reviews?.totalCount ?? 0,
                              lastComment: event(node.lastComment?.nodes?.compactMap { $0 }.last),
                              lastCommit: date(node.commits?.nodes?.compactMap { $0 }.last?.commit?.committedDate),
                              requested: (node.reviewRequests?.nodes ?? []).compactMap { $0?.requestedReviewer?.login })
    }

    private static func pullRequest(_ node: Response.Node, me: String) -> GitHubPR? {
        guard let number = node.number, let title = node.title, let url = node.url, let repo = node.repository?.nameWithOwner,
              let updated = date(node.updatedAt) else { return nil }
        let rollup = node.commits?.nodes?.compactMap { $0 }.last?.commit?.statusCheckRollup?.state
        return GitHubPR(url: url, number: number, title: title, repo: repo, isDraft: node.isDraft ?? false,
                        state: node.merged == true ? .merged : node.state == "CLOSED" ? .closed : .open, updated: updated,
                        review: node.reviewDecision.flatMap(review), checks: checks(rollup), author: node.author?.login,
                        additions: node.additions ?? 0, deletions: node.deletions ?? 0, comments: node.comments?.totalCount ?? 0,
                        labels: node.labels?.nodes?.compactMap { $0?.name } ?? [], activity: activity(node, me: me))
    }

    static func review(_ decision: String) -> GitHubPR.Review? {
        switch decision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .required
        default: return nil
        }
    }

    static func checks(_ rollup: String?) -> GitHubPR.Checks {
        switch rollup {
        case "SUCCESS": return .passed
        case "FAILURE", "ERROR": return .failed
        case "PENDING", "EXPECTED": return .running
        default: return .none
        }
    }

    // MARK: Finding the CLI

    /// The PATH first, then where Homebrew and the installers put it.
    static func cliCandidates(path: String?, home: URL) -> [URL] {
        let fromPath = (path ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("gh") }
        let known = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].map { URL(fileURLWithPath: $0) }
            + [home.appendingPathComponent(".local/bin/gh")]
        var seen = Set<String>()
        return (fromPath + known).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func findCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        fileManager: FileManager = .default) -> URL? {
        cliCandidates(path: environment["PATH"], home: home).first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Filtering

    enum StateFilter: String, CaseIterable, Identifiable {
        case open = "Open", merged = "Merged", closed = "Closed", all = "All"

        var id: String { rawValue }

        func includes(_ state: GitHubPR.State) -> Bool {
            switch self {
            case .open: return state == .open
            case .merged: return state == .merged
            case .closed: return state == .closed
            case .all: return true
            }
        }
    }

    struct Filter: Equatable {
        var state = StateFilter.open
        var repo: String?
        var query = ""
        var quick = Set<GitHubQuickFilter>()
        var hideBotOnly = false
        var sort = GitHubSort.updated
    }

    /// The pull requests that pass the filter, in the order of its sort.
    static func filter(_ prs: [GitHubPR], _ filter: Filter) -> [GitHubPR] {
        let words = filter.query.lowercased().split(separator: " ").map(String.init)
        let passing = prs.filter { pr in
            guard filter.state.includes(pr.state), filter.repo == nil || filter.repo == pr.repo else { return false }
            if !filter.quick.isEmpty || filter.hideBotOnly {
                let signals = signals(pr)
                guard filter.quick.allSatisfy(signals.matches), !(filter.hideBotOnly && signals.botOnly) else { return false }
            }
            let haystack = "\(pr.repo) #\(pr.number) \(pr.title) \(pr.author ?? "") \(pr.labels.joined(separator: " "))".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return sorted(passing, by: filter.sort)
    }

    static func repos(in prs: [GitHubPR]) -> [String] {
        Array(Set(prs.map(\.repo))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Text

    static func header(count: Int, kind: GitHubKind, capped: Bool) -> String {
        "\(count)\(capped ? "+" : "") \(kind.noun)"
    }

    /// Whether the open pull requests of a kind fill a whole page, so there may be more.
    static func isCapped(_ prs: [GitHubPR], state: StateFilter) -> Bool {
        state == .open && prs.filter { $0.state == .open }.count >= pageSize
    }

    /// The address as the timeline keeps it: host and path, without scheme.
    static func address(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    static func repoName(_ repo: String) -> (owner: String, name: String) {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : ("", repo)
    }

    static func changesText(additions: Int, deletions: Int) -> String { "+\(additions) \u{2212}\(deletions)" }

    /// What in the menu bar menu says is waiting for you: reviews asked of you and failing checks on your own open pull requests.
    static func menuSummary(_ prs: [GitHubKind: [GitHubPR]]) -> String {
        let reviews = (prs[.reviewRequested] ?? []).filter { $0.state == .open }.count
        let failing = (prs[.created] ?? []).filter { $0.state == .open && $0.checks == .failed }.count
        let feedback = newFeedbackCount(prs[.created] ?? [])
        let parts = [reviews > 0 ? "\(reviews) need\(reviews == 1 ? "s" : "") your review" : nil,
                     failing > 0 ? "\(failing) failing check\(failing == 1 ? "" : "s")" : nil,
                     feedback > 0 ? "\(feedback) with new feedback" : nil].compactMap { $0 }
        return "GitHub: " + (parts.isEmpty ? "nothing waiting for you" : parts.joined(separator: " \u{00B7} "))
    }

    static func updatedText(_ date: Date, now: Date) -> String { ClaudePlugin.ago(date, now: now) }
}
