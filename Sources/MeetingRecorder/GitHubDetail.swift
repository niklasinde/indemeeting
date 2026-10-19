import Foundation

struct GitHubPRDetail: Equatable {
    enum Mergeable: String { case mergeable, conflicting, unknown }
    enum ReviewState: Int { case changesRequested, pending, commented, approved, dismissed }
    enum Change: String { case added, modified, removed, renamed, copied, changed }
    enum CheckStatus: Int { case failed, running, pending, cancelled, passed, skipped }

    struct Reviewer: Equatable {
        let name: String
        var isTeam = false
        var state: ReviewState
    }

    struct Commit: Equatable {
        let oid: String
        let headline: String
        let author: String?
        let date: Date?
        let url: String?
        var checks = GitHubPR.Checks.none

        var shortOid: String { String(oid.prefix(7)) }
    }

    struct File: Equatable {
        let path: String
        let additions: Int
        let deletions: Int
        let change: Change

        var directory: String { path.contains("/") ? String(path[...path.lastIndex(of: "/")!]) : "" }
        var name: String { String(path.dropFirst(directory.count)) }
    }

    struct Check: Equatable {
        let name: String
        var workflow: String?
        let status: CheckStatus
        var started: Date?
        var completed: Date?
        var url: String?

        var duration: TimeInterval? {
            guard let started, let completed, completed >= started else { return nil }
            return completed.timeIntervalSince(started)
        }
    }

    let url: String
    let repo: String
    let number: Int
    var title: String
    var body = ""
    var author: String?
    var state = GitHubPR.State.open
    var isDraft = false
    var mergeable = Mergeable.unknown
    var review: GitHubPR.Review?
    var base = ""
    var head = ""
    var created: Date?
    var updated: Date?
    var additions = 0
    var deletions = 0
    var changedFiles = 0
    var labels: [String] = []
    var assignees: [String] = []
    var reviewers: [Reviewer] = []
    var commits: [Commit] = []
    var commitCount = 0
    var files: [File] = []
    var fileCount = 0
    var checks: [Check] = []
    var checkCount = 0
    var rollup = GitHubPR.Checks.none

    var hasRunningChecks: Bool { checks.contains { $0.status == .running || $0.status == .pending } }
    var ticket: String? { ActivityLogic.ticket(in: title, head) }
}

extension GitHubLogic {
    static let detailQuery = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              number title body url isDraft state merged mergeable reviewDecision baseRefName headRefName createdAt updatedAt
              additions deletions changedFiles
              author { login }
              labels(first: 20) { nodes { name } }
              assignees(first: 10) { nodes { login } }
              reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
              latestReviews(first: 20) { nodes { author { login } state } }
              commits(first: 100) {
                totalCount
                nodes { commit { oid messageHeadline committedDate url authors(first: 1) { nodes { user { login } name } } statusCheckRollup { state } } }
              }
              files(first: 100) { totalCount nodes { path additions deletions changeType } }
              lastCommit: commits(last: 1) {
                nodes { commit { statusCheckRollup { state contexts(first: 100) { totalCount nodes {
                  __typename
                  ... on CheckRun { name status conclusion startedAt completedAt detailsUrl checkSuite { workflowRun { workflow { name } } } }
                  ... on StatusContext { context state targetUrl }
                } } } } }
              }
            }
          }
        }
        """

    static func detailArguments(repo: String, number: Int) -> [String] {
        let parts = repoName(repo)
        return ["api", "graphql", "-f", "query=\(detailQuery)", "-f", "owner=\(parts.owner)", "-f", "name=\(parts.name)", "-F", "number=\(number)"]
    }

    /// `owner/repo#12`, as typed on the command line.
    static func reference(_ text: String) -> (repo: String, number: Int)? {
        let parts = text.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, let number = Int(parts[1]), parts[0].split(separator: "/").count == 2 else { return nil }
        return (parts[0], number)
    }

    private struct DetailResponse: Decodable {
        struct Login: Decodable { let login: String? }
        struct Names<Item: Decodable>: Decodable { let totalCount: Int?; let nodes: [Item?]? }
        struct Label: Decodable { let name: String? }
        struct Request: Decodable {
            struct Reviewer: Decodable { let login: String?; let name: String? }
            let requestedReviewer: Reviewer?
        }
        struct Review: Decodable { let author: Login?; let state: String? }
        struct CommitNode: Decodable {
            struct Commit: Decodable {
                struct Author: Decodable { let user: Login?; let name: String? }
                struct Rollup: Decodable { let state: String? }
                let oid: String?
                let messageHeadline: String?
                let committedDate: String?
                let url: String?
                let authors: Names<Author>?
                let statusCheckRollup: Rollup?
            }
            let commit: Commit?
        }
        struct FileNode: Decodable { let path: String?; let additions: Int?; let deletions: Int?; let changeType: String? }
        struct LastCommit: Decodable {
            struct Node: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable { let state: String?; let contexts: Names<Context>? }
                    let statusCheckRollup: Rollup?
                }
                let commit: Commit?
            }
            let nodes: [Node?]?
        }
        struct Context: Decodable {
            struct Suite: Decodable {
                struct Run: Decodable { struct Workflow: Decodable { let name: String? }; let workflow: Workflow? }
                let workflowRun: Run?
            }
            let __typename: String?
            let name: String?
            let status: String?
            let conclusion: String?
            let startedAt: String?
            let completedAt: String?
            let detailsUrl: String?
            let checkSuite: Suite?
            let context: String?
            let state: String?
            let targetUrl: String?
        }
        struct PullRequest: Decodable {
            let number: Int?
            let title: String?
            let body: String?
            let url: String?
            let isDraft: Bool?
            let state: String?
            let merged: Bool?
            let mergeable: String?
            let reviewDecision: String?
            let baseRefName: String?
            let headRefName: String?
            let createdAt: String?
            let updatedAt: String?
            let additions: Int?
            let deletions: Int?
            let changedFiles: Int?
            let author: Login?
            let labels: Names<Label>?
            let assignees: Names<Login>?
            let reviewRequests: Names<Request>?
            let latestReviews: Names<Review>?
            let commits: Names<CommitNode>?
            let files: Names<FileNode>?
            let lastCommit: LastCommit?
        }
        struct Repository: Decodable { let pullRequest: PullRequest? }
        struct Payload: Decodable { let repository: Repository? }
        struct Failure: Decodable { let message: String? }
        let data: Payload?
        let errors: [Failure]?
    }

    /// The detail of one pull request from the GraphQL response of `detailQuery`.
    static func parseDetail(_ data: Data) throws -> GitHubPRDetail {
        let response: DetailResponse
        do { response = try JSONDecoder().decode(DetailResponse.self, from: data) } catch { throw GitHubError.failed("unexpected response") }
        guard let node = response.data?.repository?.pullRequest, let url = node.url, let number = node.number, let title = node.title else {
            throw GitHubError.classify(response.errors?.compactMap(\.message).joined(separator: "\n") ?? "pull request not found")
        }
        let rollup = node.lastCommit?.nodes?.compactMap { $0 }.last?.commit?.statusCheckRollup
        let contexts = rollup?.contexts
        let checks = (contexts?.nodes ?? []).compactMap { $0.flatMap(check) }.sorted { ($0.status.rawValue, $0.name) < ($1.status.rawValue, $1.name) }
        let commits = (node.commits?.nodes ?? []).compactMap { $0?.commit }.map { commit in
            let author = commit.authors?.nodes?.compactMap { $0 }.first
            return GitHubPRDetail.Commit(oid: commit.oid ?? "", headline: commit.messageHeadline ?? "", author: author?.user?.login ?? author?.name,
                                         date: date(commit.committedDate), url: commit.url, checks: Self.checks(commit.statusCheckRollup?.state))
        }
        return GitHubPRDetail(
            url: url, repo: repository(of: url), number: number, title: title, body: node.body ?? "", author: node.author?.login,
            state: node.merged == true ? .merged : node.state == "CLOSED" ? .closed : .open, isDraft: node.isDraft ?? false,
            mergeable: GitHubPRDetail.Mergeable(rawValue: node.mergeable?.lowercased() ?? "") ?? .unknown,
            review: node.reviewDecision.flatMap(review), base: node.baseRefName ?? "", head: node.headRefName ?? "",
            created: date(node.createdAt), updated: date(node.updatedAt), additions: node.additions ?? 0, deletions: node.deletions ?? 0,
            changedFiles: node.changedFiles ?? 0, labels: (node.labels?.nodes ?? []).compactMap { $0?.name },
            assignees: (node.assignees?.nodes ?? []).compactMap { $0?.login }, reviewers: reviewers(node),
            commits: commits, commitCount: node.commits?.totalCount ?? commits.count,
            files: (node.files?.nodes ?? []).compactMap { $0.flatMap(file) }, fileCount: node.files?.totalCount ?? node.changedFiles ?? 0,
            checks: checks, checkCount: contexts?.totalCount ?? checks.count, rollup: Self.checks(rollup?.state))
    }

    /// `acme/api` from `https://github.com/acme/api/pull/7`.
    static func repository(of url: String) -> String {
        let parts = address(url).split(separator: "/")
        return parts.count >= 3 ? "\(parts[1])/\(parts[2])" : ""
    }

    private static func date(_ text: String?) -> Date? { text.flatMap { ISO8601DateFormatter().date(from: $0) } }

    private static func reviewers(_ node: DetailResponse.PullRequest) -> [GitHubPRDetail.Reviewer] {
        let requested = (node.reviewRequests?.nodes ?? []).compactMap { $0?.requestedReviewer }.compactMap { reviewer in
            reviewer.login.map { GitHubPRDetail.Reviewer(name: $0, state: .pending) }
                ?? reviewer.name.map { GitHubPRDetail.Reviewer(name: $0, isTeam: true, state: .pending) }
        }
        let asked = Set(requested.map(\.name))
        let reviewed = (node.latestReviews?.nodes ?? []).compactMap { review -> GitHubPRDetail.Reviewer? in
            guard let name = review?.author?.login ?? (review == nil ? nil : "ghost"), !asked.contains(name) else { return nil }
            return GitHubPRDetail.Reviewer(name: name, state: reviewState(review?.state))
        }
        return (requested + reviewed).sorted { ($0.state.rawValue, $0.name.lowercased()) < ($1.state.rawValue, $1.name.lowercased()) }
    }

    static func reviewState(_ state: String?) -> GitHubPRDetail.ReviewState {
        switch state {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "DISMISSED": return .dismissed
        case "PENDING": return .pending
        default: return .commented
        }
    }

    private static func file(_ node: DetailResponse.FileNode) -> GitHubPRDetail.File? {
        node.path.map { GitHubPRDetail.File(path: $0, additions: node.additions ?? 0, deletions: node.deletions ?? 0,
                                            change: node.changeType == "DELETED" ? .removed : GitHubPRDetail.Change(rawValue: node.changeType?.lowercased() ?? "") ?? .changed) }
    }

    private static func check(_ node: DetailResponse.Context) -> GitHubPRDetail.Check? {
        if node.__typename == "StatusContext" {
            guard let name = node.context else { return nil }
            return GitHubPRDetail.Check(name: name, status: checkStatus(context: node.state), url: node.targetUrl)
        }
        guard let name = node.name else { return nil }
        return GitHubPRDetail.Check(name: name, workflow: node.checkSuite?.workflowRun?.workflow?.name,
                                    status: checkStatus(status: node.status, conclusion: node.conclusion),
                                    started: date(node.startedAt), completed: date(node.completedAt), url: node.detailsUrl)
    }

    static func checkStatus(status: String?, conclusion: String?) -> GitHubPRDetail.CheckStatus {
        guard status == "COMPLETED" else { return status == "IN_PROGRESS" ? .running : .pending }
        switch conclusion {
        case "SUCCESS", "NEUTRAL": return .passed
        case "SKIPPED", "STALE": return .skipped
        case "CANCELLED": return .cancelled
        default: return .failed
        }
    }

    static func checkStatus(context state: String?) -> GitHubPRDetail.CheckStatus {
        switch state {
        case "SUCCESS": return .passed
        case "FAILURE", "ERROR": return .failed
        default: return .pending
        }
    }

    /// `5 passed · 1 failed · 1 running`, failures first; `No checks` when there are none.
    static func checkSummary(_ checks: [GitHubPRDetail.Check]) -> String {
        let names: [(GitHubPRDetail.CheckStatus, String)] = [(.failed, "failed"), (.running, "running"), (.pending, "pending"),
                                                             (.cancelled, "cancelled"), (.passed, "passed"), (.skipped, "skipped")]
        let parts = names.compactMap { status, name -> String? in
            let count = checks.filter { $0.status == status }.count
            return count > 0 ? "\(count) \(name)" : nil
        }
        return parts.isEmpty ? "No checks" : parts.joined(separator: " \u{00B7} ")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.filter { $0.isLetter || $0.isNumber }.prefix(2))
        return String(letters).uppercased()
    }

    static func files(_ files: [GitHubPRDetail.File], matching query: String) -> [GitHubPRDetail.File] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return files.filter { file in words.allSatisfy { file.path.lowercased().contains($0) } }
    }

    /// The pull request description with what GitHub hides or cannot show here made plain: comments dropped, `<img>` tags
    /// as Markdown images, other tags removed.
    static func cleanBody(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = replacing(in: text, pattern: "<img\\b[^>]*>") { tag in
            guard let source = attribute("src", in: tag) else { return "" }
            return "![\(attribute("alt", in: tag) ?? "")](\(source))"
        }
        text = text.replacingOccurrences(of: "</?(details|summary|p|br|div|b|i|em|strong|sub|sup|kbd|center|picture|source)\\b[^>]*>",
                                         with: "\n", options: [.regularExpression, .caseInsensitive])
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
        return String(tag[range].dropFirst(name.count + 2).dropLast())
    }

    private static func replacing(in text: String, pattern: String, with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }

    /// Whether a long description starts collapsed.
    static func isLong(_ body: String) -> Bool { body.count > 1200 || body.split(separator: "\n").count > 24 }

    /// The first part of a long description, cut at a line.
    static func preview(_ body: String) -> String {
        ChatLogic.trim(body, maxCharacters: 700, marker: "\n\u{2026}")
    }

    static func countNote(shown: Int, total: Int, noun: String) -> String? {
        total > shown ? "Showing the first \(shown) of \(total) \(noun)" : nil
    }
}

extension GitHubLogic {
    /// A Markdown table as plain text with the columns padded to the widest cell, the first row separated by a rule.
    static func alignedTable(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        let lines = rows.map { row in
            (0..<columns).map { column in
                let cell = column < row.count ? row[column] : ""
                return cell + String(repeating: " ", count: widths[column] - cell.count)
            }.joined(separator: "  ")
        }
        guard lines.count > 1 else { return lines.joined(separator: "\n") }
        return ([lines[0], widths.map { String(repeating: "\u{2500}", count: $0) }.joined(separator: "  ")] + lines.dropFirst()).joined(separator: "\n")
    }
}

extension GitHubLogic {
    static func stateText(_ detail: GitHubPRDetail) -> String {
        detail.isDraft && detail.state == .open ? "Draft" : detail.state.rawValue.capitalized
    }

    static func mergeText(_ mergeable: GitHubPRDetail.Mergeable) -> String? {
        switch mergeable {
        case .mergeable: return "No conflicts"
        case .conflicting: return "Has conflicts"
        case .unknown: return nil
        }
    }

    static func reviewText(_ state: GitHubPRDetail.ReviewState) -> String {
        switch state {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .commented: return "Commented"
        case .pending: return "Pending"
        case .dismissed: return "Dismissed"
        }
    }

    static func reviewText(_ review: GitHubPR.Review) -> String {
        switch review {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .required: return "Review required"
        }
    }

    /// The debug summary printed by `--github-pr`.
    static func summary(_ detail: GitHubPRDetail, now: Date) -> String {
        func ago(_ date: Date?) -> String { date.map { updatedText($0, now: now) } ?? "unknown" }
        var lines = ["\(detail.repo) #\(detail.number) [\(stateText(detail))] \(detail.title)",
                     "by \(detail.author ?? "ghost"), \(detail.head) \u{2192} \(detail.base), created \(ago(detail.created)), updated \(ago(detail.updated))",
                     "\(changesText(additions: detail.additions, deletions: detail.deletions)) in \(detail.changedFiles) files, "
                     + [mergeText(detail.mergeable), detail.review.map(reviewText)].compactMap { $0 }.joined(separator: ", "),
                     "labels: \(detail.labels.joined(separator: ", ")); assignees: \(detail.assignees.joined(separator: ", "))",
                     "reviewers: " + detail.reviewers.map { "\($0.name)\($0.isTeam ? " (team)" : "") \(reviewText($0.state))" }.joined(separator: ", "),
                     "ticket: \(detail.ticket ?? "none"); description: \(detail.body.count) characters, \(ChatLogic.blocks(cleanBody(detail.body)).count) blocks",
                     "checks (\(detail.rollup.rawValue)): \(checkSummary(detail.checks))"]
        lines += detail.checks.prefix(8).map { check in
            "  \(check.status) \(check.workflow.map { "\($0) / " } ?? "")\(check.name)" + (check.duration.map { " \(durationText($0))" } ?? "")
        }
        lines.append("commits: \(detail.commitCount)" + (countNote(shown: detail.commits.count, total: detail.commitCount, noun: "commits").map { " (\($0.lowercased()))" } ?? ""))
        lines += detail.commits.prefix(3).map { "  \($0.shortOid) \($0.headline) (\($0.author ?? "unknown"), checks \($0.checks.rawValue))" }
        lines.append("files: \(detail.fileCount)" + (countNote(shown: detail.files.count, total: detail.fileCount, noun: "files").map { " (\($0.lowercased()))" } ?? ""))
        lines += detail.files.prefix(5).map { "  \($0.change) \($0.path) \(changesText(additions: $0.additions, deletions: $0.deletions))" }
        return lines.joined(separator: "\n")
    }
}
