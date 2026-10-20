import Foundation

extension MeetingStore {
    static let githubDidChange = Notification.Name("GitHubCacheDidChange")

    func githubPRs() throws -> [GitHubKind: [GitHubPR]] {
        try read {
            let rows = try db.query("""
                SELECT kind, url, number, title, repo, is_draft, state, updated, review, checks, author, additions, deletions, comments, labels, discussion
                FROM github_prs ORDER BY position
                """, []) { row -> (GitHubKind, GitHubPR)? in
                guard let kind = GitHubKind(rawValue: row.string(0)) else { return nil }
                return (kind, GitHubPR(url: row.string(1), number: Int(row.int64(2)), title: row.string(3), repo: row.string(4),
                                       isDraft: row.bool(5), state: GitHubPR.State(rawValue: row.string(6)) ?? .open,
                                       updated: Date(timeIntervalSince1970: row.double(7)),
                                       review: row.optionalString(8).flatMap(GitHubPR.Review.init(rawValue:)),
                                       checks: GitHubPR.Checks(rawValue: row.string(9)) ?? .none, author: row.optionalString(10),
                                       additions: Int(row.int64(11)), deletions: Int(row.int64(12)), comments: Int(row.int64(13)),
                                       labels: row.string(14).split(separator: "\n").map(String.init),
                                       activity: row.optionalString(15).flatMap { try? JSONDecoder().decode(GitHubActivity.self, from: Data($0.utf8)) }))
            }
            return Dictionary(grouping: rows.compactMap { $0 }, by: \.0).mapValues { $0.map(\.1) }
        }
    }

    /// Replaces the cached pull requests of each kind given; the other kinds keep theirs.
    func saveGitHubPRs(_ prs: [GitHubKind: [GitHubPR]], fetched: Date = Date()) throws {
        try write(notify: Self.githubDidChange) {
            for (kind, rows) in prs {
                try db.run("DELETE FROM github_prs WHERE kind = ?", [kind.rawValue])
                for (position, pr) in rows.enumerated() {
                    try db.run("""
                        INSERT OR REPLACE INTO github_prs (kind, url, position, number, title, repo, is_draft, state, updated, review, checks,
                            author, additions, deletions, comments, labels, fetched, discussion)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [kind.rawValue, pr.url, position, pr.number, pr.title, pr.repo, pr.isDraft, pr.state.rawValue,
                              pr.updated.timeIntervalSince1970, pr.review?.rawValue, pr.checks.rawValue, pr.author, pr.additions,
                              pr.deletions, pr.comments, pr.labels.joined(separator: "\n"), fetched.timeIntervalSince1970,
                              pr.activity.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }])
                }
            }
        }
    }

    func githubFetched() throws -> Date? {
        try read {
            try db.query("SELECT max(fetched) FROM github_prs") { $0.optionalDouble(0) }.first.flatMap { $0 }
                .map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Titles of the cached pull requests by address without the scheme, for the timeline.
    func githubTitles() throws -> [String: String] {
        try read {
            Dictionary(try db.query("SELECT url, title FROM github_prs", []) { ($0.string(0), $0.string(1)) }
                .map { (GitHubLogic.address($0.0), $0.1) }) { $1 }
        }
    }

    /// Empties the cache and returns how many pull requests it held.
    func clearGitHubCache() throws -> Int {
        try write(notify: Self.githubDidChange) {
            let count = try db.query("SELECT count(DISTINCT url) FROM github_prs") { Int($0.int64(0)) }.first ?? 0
            try db.run("DELETE FROM github_prs")
            try db.run("DELETE FROM github_pr_details")
            try db.run("DELETE FROM github_pr_reviews")
            try db.run("DELETE FROM github_pr_comments")
            return count
        }
    }

    /// The last fetched response for a pull request, parsed.
    func githubDetail(_ url: String) throws -> GitHubPRDetail? {
        try read {
            try db.query("SELECT json FROM github_pr_details WHERE url = ?", [url]) { $0.optionalData(0) }.first.flatMap { $0 }
                .flatMap { try? GitHubLogic.parseDetail($0) }
        }
    }

    /// When each pull request's detail was last fetched.
    func githubDetailFetched() throws -> [String: Date] {
        try read {
            Dictionary(try db.query("SELECT url, fetched FROM github_pr_details", []) { ($0.string(0), Date(timeIntervalSince1970: $0.double(1))) }) { $1 }
        }
    }

    func saveGitHubDetail(_ url: String, json: Data, fetched: Date = Date()) throws {
        try write(notify: Self.githubDidChange) {
            let head = (try? GitHubLogic.parseDetail(json))?.headOid
            try db.run("INSERT OR REPLACE INTO github_pr_details (url, json, fetched, head_sha) VALUES (?, ?, ?, ?)",
                       [url, json, fetched.timeIntervalSince1970, head])
        }
    }

    /// The cached comments of a pull request, parsed, with the responses they were parsed from.
    func githubComments(_ url: String) throws -> (comments: GitHubComments, json: Data)? {
        try read {
            try db.query("SELECT json FROM github_pr_comments WHERE url = ?", [url]) { $0.optionalData(0) }.first.flatMap { $0 }
                .flatMap { json in (try? GitHubLogic.parseComments(json)).map { ($0, json) } }
        }
    }

    func saveGitHubComments(_ url: String, json: Data, headSHA: String?, fetched: Date = Date()) throws {
        try write(notify: Self.githubDidChange) {
            try db.run("INSERT OR REPLACE INTO github_pr_comments (url, json, head_sha, fetched) VALUES (?, ?, ?, ?)",
                       [url, json, headSHA, fetched.timeIntervalSince1970])
        }
    }

    func githubReview(_ url: String) throws -> GitHubReview? {
        try read { try db.query(Self.reviewSelect + " WHERE url = ?", [url], Self.review).first.flatMap { $0 } }
    }

    func githubReviews() throws -> [GitHubReview] {
        try read { try db.query(Self.reviewSelect, [], Self.review).compactMap { $0 } }
    }

    func saveGitHubReview(_ review: GitHubReview) throws {
        try write(notify: Self.githubDidChange) {
            try db.run("INSERT OR REPLACE INTO github_pr_reviews (url, head_sha, preset, text, created, duration, cost) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       [review.url, review.headSHA, review.preset.rawValue, review.text, review.created.timeIntervalSince1970,
                        review.duration, review.cost])
        }
    }

    /// Whether each reviewed pull request has had new commits since, by address: the head of the review against the newest one fetched.
    func githubReviewOutdated() throws -> [String: Bool] {
        try read {
            Dictionary(try db.query("""
                SELECT r.url, r.head_sha, d.head_sha FROM github_pr_reviews r LEFT JOIN github_pr_details d ON d.url = r.url
                """, []) { ($0.string(0), GitHubClaude.isOutdated(reviewed: $0.optionalString(1), current: $0.optionalString(2))) }) { $1 }
        }
    }

    private static let reviewSelect = "SELECT url, head_sha, preset, text, created, duration, cost FROM github_pr_reviews"

    private static func review(_ row: SQLRow) -> GitHubReview? {
        GitHubClaude.Preset(rawValue: row.string(2)).map {
            GitHubReview(url: row.string(0), headSHA: row.optionalString(1), preset: $0, text: row.string(3),
                         created: Date(timeIntervalSince1970: row.double(4)), duration: row.double(5), cost: row.optionalDouble(6))
        }
    }
}
