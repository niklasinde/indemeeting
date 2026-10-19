import Foundation

extension MeetingStore {
    static let githubDidChange = Notification.Name("GitHubCacheDidChange")

    func githubPRs() throws -> [GitHubKind: [GitHubPR]] {
        try read {
            let rows = try db.query("""
                SELECT kind, url, number, title, repo, is_draft, state, updated, review, checks, author, additions, deletions, comments, labels
                FROM github_prs ORDER BY position
                """, []) { row -> (GitHubKind, GitHubPR)? in
                guard let kind = GitHubKind(rawValue: row.string(0)) else { return nil }
                return (kind, GitHubPR(url: row.string(1), number: Int(row.int64(2)), title: row.string(3), repo: row.string(4),
                                       isDraft: row.bool(5), state: GitHubPR.State(rawValue: row.string(6)) ?? .open,
                                       updated: Date(timeIntervalSince1970: row.double(7)),
                                       review: row.optionalString(8).flatMap(GitHubPR.Review.init(rawValue:)),
                                       checks: GitHubPR.Checks(rawValue: row.string(9)) ?? .none, author: row.optionalString(10),
                                       additions: Int(row.int64(11)), deletions: Int(row.int64(12)), comments: Int(row.int64(13)),
                                       labels: row.string(14).split(separator: "\n").map(String.init)))
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
                            author, additions, deletions, comments, labels, fetched)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [kind.rawValue, pr.url, position, pr.number, pr.title, pr.repo, pr.isDraft, pr.state.rawValue,
                              pr.updated.timeIntervalSince1970, pr.review?.rawValue, pr.checks.rawValue, pr.author, pr.additions,
                              pr.deletions, pr.comments, pr.labels.joined(separator: "\n"), fetched.timeIntervalSince1970])
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
            return count
        }
    }
}
