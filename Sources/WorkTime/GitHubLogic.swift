import Foundation

enum GitHubKind: String, CaseIterable, Identifiable {
    case created
    case reviewRequested = "review_requested"
    case assigned
    case mentioned
    case reviewed

    /// The tabs of the GitHub page. Reviewed is shown as Reviewing, joined with the review requests and the watched pull requests.
    static let pageKinds: [GitHubKind] = [.created, .reviewed, .reviewRequested, .assigned, .mentioned]
    static let phoneKinds: [GitHubKind] = [.created, .reviewRequested, .assigned, .mentioned]

    var id: String { rawValue }

    var tabTitle: String {
        switch self {
        case .created: return "Created"
        case .reviewRequested: return "Review requested"
        case .assigned: return "Assigned"
        case .mentioned: return "Mentioned"
        case .reviewed: return "Reviewing"
        }
    }

    var noun: String { tabTitle.lowercased() }

    fileprivate var qualifier: String {
        switch self {
        case .created: return "author:@me"
        case .reviewRequested: return "review-requested:@me"
        case .assigned: return "assignee:@me"
        case .mentioned: return "mentions:@me"
        case .reviewed: return "reviewed-by:@me -author:@me"
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
    var mergeable = GitHubPRDetail.Mergeable.unknown
    var mergeState = GitHubPRDetail.MergeState.unknown

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
        mergeable mergeStateStatus
        lastComment: comments(last: 1) { nodes { author { login __typename } createdAt } }
        reviews { totalCount }
        latestReviews(first: 10) { nodes { author { login __typename } state submittedAt } }
        reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
        reviewThreads(first: \(threadPageSize)) {
          totalCount
          nodes { isResolved comments(last: 1) { nodes { author { login __typename } createdAt } } }
        }
        """

    private static func fields(discussion: Bool) -> String {
        """
        number title url isDraft state merged updatedAt reviewDecision additions deletions
        repository { nameWithOwner }
        author { login __typename }
        comments { totalCount }
        labels(first: 5) { nodes { name } }
        commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
        \(discussion ? discussionFields : "")
        """
    }

    /// The search with the discussion fields, or without them for the closed and merged pull requests, which need no attention.
    static func query(discussion: Bool) -> String {
        """
        query($q: String!, $first: Int!) {
          rateLimit { cost remaining }
          viewer { login }
          search(query: $q, type: ISSUE, first: $first) {
            nodes {
              ... on PullRequest {
                \(fields(discussion: discussion))
              }
            }
          }
        }
        """
    }

    /// The watched pull requests by number, one alias each, with the same fields as the open searches.
    static func watchedQuery(_ targets: [GitHubLink.Target]) -> String {
        let pulls = targets.enumerated().map { index, target in
            let (owner, name) = repoName(target.repo)
            return "w\(index): repository(owner: \"\(owner)\", name: \"\(name)\") { pullRequest(number: \(target.number)) { \(fields(discussion: true)) } }"
        }
        return "query {\n  rateLimit { cost remaining }\n  viewer { login }\n" + pulls.joined(separator: "\n") + "\n}"
    }

    static func watchedArguments(_ targets: [GitHubLink.Target]) -> [String] {
        ["api", "graphql", "-f", "query=\(watchedQuery(targets))"]
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
            let mergeable: String?
            let mergeStateStatus: String?
        }
        struct Search: Decodable { let nodes: [Node?]? }
        struct Viewer: Decodable { let login: String? }
        struct Cost: Decodable { let cost: Int?; let remaining: Int? }
        struct Payload: Decodable { let search: Search?; let viewer: Viewer?; let rateLimit: Cost? }
        struct Failure: Decodable { let message: String? }
        let data: Payload?
        let errors: [Failure]?
    }

    private struct WatchedResponse: Decodable {
        struct Repository: Decodable { let pullRequest: Response.Node? }
        let data: [String: Repository?]?
    }

    /// The watched pull requests in the order they were asked for. Ones that are gone or out of reach are left out.
    static func parseWatched(_ data: Data) throws -> [GitHubPR] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let aliases = (try? JSONDecoder().decode(WatchedResponse.self, from: data))?.data else {
            throw GitHubError.failed("unexpected response")
        }
        let me = response.data?.viewer?.login ?? ""
        return aliases.compactMap { key, repository -> (Int, GitHubPR)? in
            guard key.hasPrefix("w"), let index = Int(key.dropFirst()), let node = repository?.pullRequest,
                  let pr = pullRequest(node, me: me) else { return nil }
            return (index, pr)
        }.sorted { $0.0 < $1.0 }.map(\.1)
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
                        labels: node.labels?.nodes?.compactMap { $0?.name } ?? [], activity: activity(node, me: me),
                        mergeable: GitHubPRDetail.Mergeable(rawValue: node.mergeable?.lowercased() ?? "") ?? .unknown,
                        mergeState: GitHubPRDetail.MergeState(rawValue: node.mergeStateStatus ?? "") ?? .unknown)
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
        var status = GitHubStatusTab.all
        var author: String?
        var draft: Bool?
        var checks: GitHubPR.Checks?
        var review: GitHubPR.Review?
        var waitingOnMe: Bool?

        /// How many of the filters behind the Filters menu differ from their defaults.
        var refinements: Int {
            [state != .open, repo != nil, sort != .updated, hideBotOnly, author != nil, draft != nil, checks != nil, review != nil,
             waitingOnMe != nil].filter { $0 }.count + quick.count
        }

        var withoutRefinements: Filter { Filter(query: query, status: status) }
    }

    /// The pull requests that pass the filter, in the order of its sort. Mergeable keeps those ready to merge. As a reviewer the
    /// status is mine in the review, and those waiting on me come first.
    static func filter(_ prs: [GitHubPR], _ filter: Filter, mergeable: Bool = false, reviewer: Bool = false) -> [GitHubPR] {
        let words = filter.query.lowercased().split(separator: " ").map(String.init)
        let quick = filter.quick
        let passing = prs.filter { pr in
            guard filter.state.includes(pr.state), matchesRepo(pr.repo, filter.repo), matchesAuthor(pr, filter.author),
                  filter.draft.map({ $0 == pr.isDraft }) ?? true, filter.checks.map({ $0 == pr.checks }) ?? true,
                  filter.review.map({ $0 == pr.review }) ?? true, filter.status.includes(pr, reviewer: reviewer) else { return false }
            if mergeable && !isMergeable(pr) { return false }
            if !quick.isEmpty || filter.hideBotOnly || filter.waitingOnMe != nil {
                let signals = signals(pr)
                guard quick.allSatisfy(signals.matches), !(filter.hideBotOnly && signals.botOnly),
                      filter.waitingOnMe.map({ $0 == signals.waitingOnMe }) ?? true else { return false }
            }
            let haystack = "\(pr.repo) #\(pr.number) \(pr.repo)#\(pr.number) \(pr.title) \(pr.author ?? "") \(pr.labels.joined(separator: " "))".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        let shown = sorted(passing, by: filter.sort)
        guard reviewer else { return shown }
        let mine = shown.filter { status($0, reviewer: true) == .myTurn }
        return mine + shown.filter { status($0, reviewer: true) != .myTurn }
    }

    /// A wanted repository is `owner/name` or a bare name of any owner, several comma-separated, ignoring case.
    static func matchesRepo(_ repo: String, _ wanted: String?) -> Bool {
        let names = (wanted ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let full = repo.lowercased()
        return names.isEmpty || names.contains { $0.contains("/") ? $0 == full : $0 == repoName(full).name }
    }

    /// A login ignoring case, or `me` for the signed-in user.
    static func matchesAuthor(_ pr: GitHubPR, _ wanted: String?) -> Bool {
        guard let wanted, !wanted.isEmpty else { return true }
        let login = wanted.lowercased() == "me" ? pr.activity?.me : wanted
        return login.map { !$0.isEmpty && pr.author?.lowercased() == $0.lowercased() } ?? false
    }

    /// The signed-in user's login as the cached discussions know it.
    static func me(in prs: [GitHubKind: [GitHubPR]]) -> String? {
        prs.values.joined().lazy.compactMap { $0.activity?.me }.first { !$0.isEmpty }
    }

    /// Every cached pull request once, whichever lists it is in.
    static func unique(_ prs: [GitHubKind: [GitHubPR]]) -> [GitHubPR] {
        var seen = Set<String>()
        return GitHubKind.allCases.flatMap { prs[$0] ?? [] }.filter { seen.insert($0.url).inserted }
    }

    /// How many pull requests each status tab would show with the rest of the filter.
    static func statusCounts(_ prs: [GitHubPR], _ filter: Filter, mergeable: Bool = false, reviewer: Bool = false) -> [GitHubStatusTab: Int] {
        Dictionary(uniqueKeysWithValues: GitHubStatusTab.allCases.map { tab in
            var tabbed = filter
            tabbed.status = tab
            return (tab, Self.filter(prs, tabbed, mergeable: mergeable, reviewer: reviewer).count)
        })
    }

    static let notchLimit = 30

    /// Open, not a draft, approved or needing no review, checks passing or absent, and no conflict or branch rule in the way.
    static func isMergeable(_ pr: GitHubPR) -> Bool {
        pr.state == .open && !pr.isDraft && pr.mergeable == .mergeable && (pr.review == nil || pr.review == .approved)
            && (pr.checks == .passed || pr.checks == .none) && [.clean, .hasHooks, .unknown].contains(pr.mergeState)
    }

    /// The first few open pull requests, those waiting on me first, then by last update.
    static func waitingFirst(_ prs: [GitHubPR], status: GitHubStatusTab = .all) -> [GitHubPR] {
        let waiting = filter(prs, Filter(quick: [.waitingOnMe], status: status))
        let rest = filter(prs, Filter(status: status)).filter { !waiting.contains($0) }
        return Array((waiting + rest).prefix(notchLimit))
    }

    /// Open pull requests asking for my review, newest first, in the repository and search of the filter.
    static func reviewQueue(_ prs: [GitHubPR], _ filter: Filter = Filter(), limit: Int? = nil) -> [GitHubPR] {
        let open = Self.filter(prs, Filter(repo: filter.repo, query: filter.query))
        return limit.map { Array(open.prefix($0)) } ?? open
    }

    // MARK: Reviewing

    static let reviewingTabs: [GitHubStatusTab] = [.all, .myTurn, .waiting, .approved]

    /// Open pull requests by others that ask for my review or that I reviewed, each once, those waiting on me first, then by last update.
    static func reviewing(_ prs: [GitHubKind: [GitHubPR]], status tab: GitHubStatusTab = .all) -> [GitHubPR] {
        filter(reviewingRows(prs).reviewing, Filter(status: tab), reviewer: true)
    }

    /// Pull requests by others that ask for my review or that I reviewed, each once, and apart from them the ones I watch.
    static func reviewingRows(_ prs: [GitHubKind: [GitHubPR]], watched: [GitHubPR] = []) -> (reviewing: [GitHubPR], watching: [GitHubPR]) {
        var seen = Set<String>()
        let others = { (pr: GitHubPR) in pr.author != pr.activity?.me && seen.insert(pr.url).inserted }
        let reviewing = ((prs[.reviewRequested] ?? []) + (prs[.reviewed] ?? [])).filter(others)
        return (reviewing, watched.filter(others))
    }

    static func status(_ pr: GitHubPR, reviewer: Bool) -> GitHubStatus? {
        reviewer ? (pr.state == .open ? reviewStatus(pr) : nil) : status(pr)
    }

    // MARK: Watching

    static let watchLimit = 30
    /// How long a merged or closed watched pull request stays before it is dropped.
    static let watchGrace: TimeInterval = 3 * 86_400

    static func watching(_ url: String, in urls: [String]) -> [String] {
        Array(([url] + urls.filter { $0 != url }).prefix(watchLimit))
    }

    /// The watched addresses less those whose pull request was merged or closed more than the grace period ago.
    static func keptWatches(_ urls: [String], fetched: [GitHubPR], now: Date) -> [String] {
        let done = Set(fetched.filter { $0.state != .open && now.timeIntervalSince($0.updated) > watchGrace }.map(\.url))
        return urls.filter { !done.contains($0) }
    }

    static func reviewingCounts(_ prs: [GitHubKind: [GitHubPR]]) -> [GitHubStatusTab: Int] {
        Dictionary(uniqueKeysWithValues: reviewingTabs.map { ($0, reviewing(prs, status: $0).count) })
    }

    /// Where someone else's pull request stands in my review: my turn when a review is asked of me or the author pushed or
    /// replied since my last one, approved when my latest review approves, otherwise waiting on the author.
    static func reviewStatus(_ pr: GitHubPR) -> GitHubStatus {
        guard let activity = pr.activity else { return .myTurn }
        if signals(pr).waitingOnMe { return .myTurn }
        let latest = activity.reviews.filter { $0.actor.login == activity.me }.max { $0.date < $1.date }
        return latest?.state == "APPROVED" ? .approved : .waiting
    }

    // MARK: Status

    /// Where an open pull request stands, checked in this order: on hold, draft, my turn, approved, waiting.
    static func status(_ pr: GitHubPR) -> GitHubStatus? {
        guard pr.state == .open else { return nil }
        if pr.labels.contains(where: isHoldLabel) { return .onHold }
        if pr.isDraft { return .draft }
        if isMyTurn(pr) { return .myTurn }
        return pr.review == .approved ? .approved : .waiting
    }

    static func isHoldLabel(_ label: String) -> Bool {
        label.lowercased().split { !$0.isLetter }.contains("hold")
    }

    /// Someone else's pull request is my turn when it waits on me. My own is when a person commented or asked for changes
    /// since my last push and I have not asked them to look again.
    static func isMyTurn(_ pr: GitHubPR) -> Bool {
        guard let activity = pr.activity else { return pr.review == .changesRequested }
        guard pr.author == activity.me else { return signals(pr).waitingOnMe }
        let pushed = activity.lastCommit ?? .distantPast
        return activity.reviews.contains {
            $0.actor.login != activity.me && !$0.actor.isBot && feedbackStates.contains($0.state) && $0.date > pushed
                && !activity.requested.contains($0.actor.login)
        }
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
