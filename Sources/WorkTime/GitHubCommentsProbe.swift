import Foundation

/// `--github-pr-comments <owner/repo#n>`: fetches every page of a pull request's comments and prints the parsed structure and
/// what it cost. Reads GitHub, writes nothing.
enum GitHubCommentsProbe {
    static func runFromCommandLine(_ reference: String) -> Never {
        guard let target = GitHubLogic.reference(reference), let cli = GitHubLogic.findCLI() else {
            FileHandle.standardError.write(Data("Usage: --github-pr-comments owner/repo#number (needs gh)\n".utf8))
            exit(2)
        }
        var merged: GitHubComments?
        var bytes = 0
        var pages = 0
        let started = Date()
        while pages < 20 {
            switch GitHubClient.fetchComments(cli: cli, repo: target.repo, number: target.number, after: merged?.cursors) {
            case .success(let fetched):
                bytes += fetched.json.count
                pages += 1
                merged = merged?.appending(fetched.page) ?? fetched.page
            case .failure(let error):
                FileHandle.standardError.write(Data("Failed: \(error.message)\n".utf8))
                exit(1)
            }
            if merged?.hasMore != true { break }
        }
        guard let comments = merged else { exit(1) }
        print("\(reference): \(pages) page\(pages == 1 ? "" : "s"), \(bytes) bytes, \(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
              + "cost \(comments.cost) points, \(comments.remaining.map(String.init) ?? "?") left, still more: \(comments.hasMore)")
        print(report(comments))
        exit(0)
    }

    static func report(_ comments: GitHubComments) -> String {
        let all = comments.threads.flatMap(\.comments) + comments.conversation
        let bots = all.filter { $0.author.isBot }.count
        let filter = GitHubCommentsFilter(scope: .unresolved)
        var lines = [GitHubLogic.commentsSummary(comments) + " (total threads \(comments.threadTotal))",
                     "files with threads: \(GitHubLogic.groupedByFile(comments.threads).count); resolved \(comments.threads.filter(\.isResolved).count), "
                     + "outdated \(comments.threads.filter(\.isOutdated).count), file-level \(comments.threads.filter { GitHubLogic.badge($0) == "file-level" }.count), "
                     + "with a diff \(comments.threads.filter { !$0.diff.isEmpty }.count)",
                     "conversation: \(comments.conversation.count) (reviews with text \(comments.conversation.filter { $0.review != nil }.count)); "
                     + "bots \(bots) of \(all.count) comments (\(all.isEmpty ? 0 : bots * 100 / all.count)%), collapsed bot comments \(all.filter { $0.digest != nil }.count)",
                     "suggestions: \(all.filter { $0.parts.contains { if case .suggestion = $0 { return true } else { return false } } }.count); "
                     + "unresolved view shows \(GitHubLogic.visibleThreads(comments, filter, after: nil).count) threads"]
        for thread in comments.threads.prefix(3) {
            lines.append("  \(GitHubLogic.location(thread))\(GitHubLogic.badge(thread).map { " [\($0)]" } ?? "")\(thread.isResolved ? " [resolved]" : ""): "
                         + thread.comments.map { "\($0.author.login)\($0.author.isBot ? "*" : "")" }.joined(separator: ", ")
                         + " \u{2014} " + (thread.comments.first.map { GitHubLogic.firstWords($0, limit: 60) } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}
