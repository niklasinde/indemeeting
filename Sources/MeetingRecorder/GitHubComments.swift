import Foundation

struct GitHubDiffLine: Equatable {
    enum Kind: Equatable { case added, removed, context }
    let kind: Kind
    let text: String
}

/// A comment body made plain: Markdown with the HTML GitHub hides cleaned away, `suggestion` fences and `<details>` as parts of their own.
enum GitHubCommentPart: Equatable {
    case markdown(String)
    case suggestion(String)
    case details(summary: String, parts: [GitHubCommentPart])
}

struct GitHubComment: Equatable, Identifiable {
    let id: String
    var author: GitHubActivity.Actor
    var body: String
    var parts: [GitHubCommentPart]
    /// The start of a long bot comment, shown instead of the whole of it until asked for.
    var digest: String?
    var created: Date?
    var url: String?
    var review: GitHubPRDetail.ReviewState?
}

struct GitHubThread: Equatable, Identifiable {
    let id: String
    let path: String
    var line: Int?
    var originalLine: Int?
    var startLine: Int?
    var isResolved = false
    var isOutdated = false
    var isFile = false
    var resolvedBy: String?
    /// The last lines of the first comment's diff hunk.
    var diff: [GitHubDiffLine] = []
    var comments: [GitHubComment] = []
    var commentCount = 0

    var url: String? { comments.first?.url }
}

/// The discussion on a pull request as far as it is fetched: review threads, and the conversation of comments and review summaries.
struct GitHubComments: Equatable {
    struct Cursor: Equatable {
        var after: String?
        var more = false
    }

    struct Cursors: Equatable {
        var threads = Cursor()
        var comments = Cursor()
        var reviews = Cursor()

        var hasMore: Bool { threads.more || comments.more || reviews.more }

        func advanced(by next: Cursors) -> Cursors {
            func step(_ old: Cursor, _ new: Cursor) -> Cursor { Cursor(after: new.after ?? old.after, more: new.more) }
            return Cursors(threads: step(threads, next.threads), comments: step(comments, next.comments), reviews: step(reviews, next.reviews))
        }
    }

    var me = ""
    var headOid: String?
    var threads: [GitHubThread] = []
    var threadTotal = 0
    /// Comments on the pull request and review summaries with a text, oldest first.
    var conversation: [GitHubComment] = []
    var cursors = Cursors()
    /// GraphQL points the fetched pages cost, and what was left of the hourly allowance after the last one.
    var cost = 0
    var remaining: Int?

    var hasMore: Bool { cursors.hasMore }
    var unresolved: Int { threads.filter { !$0.isResolved }.count }
    var commentCount: Int { threads.reduce(0) { $0 + $1.comments.count } + conversation.count }
    var isEmpty: Bool { threads.isEmpty && conversation.isEmpty && !hasMore }

    func appending(_ next: GitHubComments) -> GitHubComments {
        var merged = self
        let known = Set(threads.map(\.id))
        merged.threads += next.threads.filter { !known.contains($0.id) }
        let seen = Set(conversation.map(\.id))
        merged.conversation = GitHubLogic.chronological(conversation + next.conversation.filter { !seen.contains($0.id) })
        merged.threadTotal = next.threadTotal
        merged.cursors = cursors.advanced(by: next.cursors)
        merged.headOid = next.headOid ?? headOid
        merged.me = next.me.isEmpty ? me : next.me
        merged.cost += next.cost
        merged.remaining = next.remaining ?? remaining
        return merged
    }
}

extension GitHubLogic {
    static let commentsPageSize = 50

    /// The threads, the comments and the review summaries of a pull request, a page of each. The diff hunk, the bulk of the
    /// payload, is asked for on the first comment of a thread only.
    static let commentsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $threads: String, $comments: String, $reviews: String) {
          rateLimit { cost remaining }
          viewer { login }
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              headRefOid
              comments(first: \(commentsPageSize), after: $comments) {
                totalCount pageInfo { hasNextPage endCursor }
                nodes { id author { login __typename } body createdAt url }
              }
              reviews(first: \(commentsPageSize), after: $reviews) {
                totalCount pageInfo { hasNextPage endCursor }
                nodes { id author { login __typename } body state submittedAt url }
              }
              reviewThreads(first: \(commentsPageSize), after: $threads) {
                totalCount pageInfo { hasNextPage endCursor }
                nodes {
                  id isResolved isOutdated path line originalLine startLine subjectType resolvedBy { login }
                  head: comments(first: 1) { nodes { diffHunk } }
                  comments(first: \(commentsPageSize)) {
                    totalCount
                    nodes { id author { login __typename } body createdAt url pullRequestReview { state } }
                  }
                }
              }
            }
          }
        }
        """

    /// The request for the page after `cursors`, or the first page.
    static func commentsArguments(repo: String, number: Int, after cursors: GitHubComments.Cursors? = nil) -> [String] {
        let parts = repoName(repo)
        let named = [("threads", cursors?.threads.after), ("comments", cursors?.comments.after), ("reviews", cursors?.reviews.after)]
        return ["api", "graphql", "-f", "query=\(commentsQuery)", "-f", "owner=\(parts.owner)", "-f", "name=\(parts.name)", "-F", "number=\(number)"]
            + named.flatMap { name, cursor in cursor.map { ["-f", "\(name)=\($0)"] } ?? [] }
    }

    /// What is cached for a pull request: the responses of the pages fetched so far as one JSON array, with `page` added.
    static func commentsCache(_ cache: Data?, adding page: Data) -> Data {
        var bytes = Array(cache ?? Data("[".utf8))
        while let last = bytes.last, last == UInt8(ascii: "]") || last == 0x0A || last == 0x20 { bytes.removeLast() }
        if bytes.count > 1 { bytes.append(UInt8(ascii: ",")) }
        return Data(bytes + Array(page) + [UInt8(ascii: "]")])
    }

    private struct CommentsResponse: Decodable {
        struct Named: Decodable { let login: String?; let __typename: String? }
        struct PageInfo: Decodable { let hasNextPage: Bool?; let endCursor: String? }
        struct Connection<Item: Decodable>: Decodable { let totalCount: Int?; let pageInfo: PageInfo?; let nodes: [Item?]? }
        struct Node: Decodable {
            struct Review: Decodable { let state: String? }
            let id: String?
            let author: Named?
            let body: String?
            let state: String?
            let createdAt: String?
            let submittedAt: String?
            let url: String?
            let pullRequestReview: Review?
        }
        struct Hunk: Decodable { let diffHunk: String? }
        struct Thread: Decodable {
            struct Resolver: Decodable { let login: String? }
            let id: String?
            let isResolved: Bool?
            let isOutdated: Bool?
            let path: String?
            let line: Int?
            let originalLine: Int?
            let startLine: Int?
            let subjectType: String?
            let resolvedBy: Resolver?
            let head: Connection<Hunk>?
            let comments: Connection<Node>?
        }
        struct PullRequest: Decodable {
            let headRefOid: String?
            let comments: Connection<Node>?
            let reviews: Connection<Node>?
            let reviewThreads: Connection<Thread>?
        }
        struct Repository: Decodable { let pullRequest: PullRequest? }
        struct Viewer: Decodable { let login: String? }
        struct Cost: Decodable { let cost: Int?; let remaining: Int? }
        struct Payload: Decodable { let repository: Repository?; let viewer: Viewer?; let rateLimit: Cost? }
        struct Failure: Decodable { let message: String? }
        let data: Payload?
        let errors: [Failure]?
    }

    /// The discussion from one response, or from the array of responses `commentsCache` makes.
    static func parseComments(_ data: Data) throws -> GitHubComments {
        let responses: [CommentsResponse]
        do {
            let isArray = data.first { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 } == UInt8(ascii: "[")
            responses = isArray ? try JSONDecoder().decode([CommentsResponse].self, from: data) : [try JSONDecoder().decode(CommentsResponse.self, from: data)]
        } catch { throw GitHubError.failed("unexpected response") }
        let pages = try responses.map(commentsPage)
        guard let first = pages.first else { throw GitHubError.failed("no data") }
        return pages.dropFirst().reduce(first) { $0.appending($1) }
    }

    private static func commentsPage(_ response: CommentsResponse) throws -> GitHubComments {
        guard let node = response.data?.repository?.pullRequest else {
            throw GitHubError.classify(response.errors?.compactMap(\.message).joined(separator: "\n") ?? "pull request not found")
        }
        func cursor(_ connection: CommentsResponse.Connection<some Decodable>?) -> GitHubComments.Cursor {
            GitHubComments.Cursor(after: connection?.pageInfo?.endCursor, more: connection?.pageInfo?.hasNextPage ?? false)
        }
        let issue = (node.comments?.nodes ?? []).compactMap { $0.flatMap { comment($0, review: nil) } }
        let summaries = (node.reviews?.nodes ?? []).compactMap { review -> GitHubComment? in
            guard let review, review.state != "PENDING", !(review.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return comment(review, review: reviewState(review.state), date: review.submittedAt)
        }
        return GitHubComments(me: response.data?.viewer?.login ?? "", headOid: node.headRefOid,
                              threads: (node.reviewThreads?.nodes ?? []).compactMap { $0.flatMap(thread) },
                              threadTotal: node.reviewThreads?.totalCount ?? 0, conversation: chronological(issue + summaries),
                              cursors: .init(threads: cursor(node.reviewThreads), comments: cursor(node.comments), reviews: cursor(node.reviews)),
                              cost: response.data?.rateLimit?.cost ?? 0, remaining: response.data?.rateLimit?.remaining)
    }

    private static func comment(_ node: CommentsResponse.Node, review: GitHubPRDetail.ReviewState?, date text: String? = nil) -> GitHubComment? {
        guard let id = node.id else { return nil }
        let body = (node.body ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        let login = node.author?.login ?? "ghost"
        let author = GitHubActivity.Actor(login: login, isBot: isBot(login: login, typename: node.author?.__typename))
        let parts = commentParts(body)
        return GitHubComment(id: id, author: author, body: body, parts: parts, digest: author.isBot ? digest(parts, body: body) : nil,
                             created: date(text ?? node.createdAt), url: node.url,
                             review: review ?? node.pullRequestReview?.state.map(reviewState))
    }

    private static func thread(_ node: CommentsResponse.Thread) -> GitHubThread? {
        let comments = (node.comments?.nodes ?? []).compactMap { $0.flatMap { comment($0, review: nil) } }
        guard let id = node.id, let path = node.path, !comments.isEmpty else { return nil }
        let hunk = node.head?.nodes?.compactMap { $0?.diffHunk }.first ?? ""
        return GitHubThread(id: id, path: path, line: node.line, originalLine: node.originalLine, startLine: node.startLine,
                            isResolved: node.isResolved ?? false, isOutdated: node.isOutdated ?? false, isFile: node.subjectType == "FILE",
                            resolvedBy: node.resolvedBy?.login, diff: diffLines(hunk), comments: comments,
                            commentCount: node.comments?.totalCount ?? comments.count)
    }

    static func chronological(_ comments: [GitHubComment]) -> [GitHubComment] {
        comments.sorted { ($0.created ?? .distantFuture, $0.id) < ($1.created ?? .distantFuture, $1.id) }
    }

    private static let botNames = ["copilot", "coderabbit", "github-actions", "snyk", "dependabot", "sonarcloud", "sonarqube", "renovate"]

    /// A bot by its account type, by the `[bot]` GitHub puts after app accounts or by the names of the usual reviewers.
    static func isBot(login: String, typename: String?) -> Bool {
        let lowered = login.lowercased()
        return typename == "Bot" || lowered.hasSuffix("[bot]") || botNames.contains { lowered.contains($0) }
    }
}
