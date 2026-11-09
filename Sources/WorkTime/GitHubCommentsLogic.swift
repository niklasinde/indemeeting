import Foundation

struct GitHubCommentsFilter: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case unresolved = "Unresolved"
        case all = "All"
        case mine = "Mine"
        case new = "New"

        var id: String { rawValue }
    }

    var scope = Scope.all
    var hideBots = false
    var query = ""
}

struct GitHubFileThreads: Equatable, Identifiable {
    let path: String
    let threads: [GitHubThread]

    var id: String { path }
    var directory: String { GitHubLogic.pathParts(path).directory }
    var name: String { GitHubLogic.pathParts(path).name }
}

extension GitHubLogic {
    static func pathParts(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    // MARK: Diff

    /// The last `count` lines of a diff hunk without its `@@` header, each told apart by its first character.
    static func diffLines(_ hunk: String, last count: Int = 8) -> [GitHubDiffLine] {
        let lines = hunk.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .filter { !$0.hasPrefix("@@") && !$0.hasPrefix("\\") }
        return lines.suffix(count).map { line in
            switch line.first {
            case "+": return GitHubDiffLine(kind: .added, text: String(line.dropFirst()))
            case "-": return GitHubDiffLine(kind: .removed, text: String(line.dropFirst()))
            case " ": return GitHubDiffLine(kind: .context, text: String(line.dropFirst()))
            default: return GitHubDiffLine(kind: .context, text: line)
            }
        }
    }

    /// The lines a suggestion replaces: the last of the diff, as many as the thread's range covers.
    static func suggestionBefore(_ thread: GitHubThread) -> [GitHubDiffLine] {
        guard !thread.isOutdated else { return [] }
        let span = thread.line.flatMap { line in thread.startLine.map { max(line - $0 + 1, 1) } } ?? 1
        return Array(thread.diff.suffix(span))
    }

    // MARK: Locations

    /// `path:line`, or the path alone for a comment on the whole file.
    static func location(_ thread: GitHubThread) -> String {
        guard let line = thread.line ?? thread.originalLine, !thread.isFile else { return thread.path }
        return "\(thread.path):\(line)"
    }

    static func badge(_ thread: GitHubThread) -> String? {
        if thread.isOutdated { return "outdated" }
        return thread.line == nil || thread.isFile ? "file-level" : nil
    }

    /// The one line a resolved thread is folded into.
    static func resolvedLine(_ thread: GitHubThread) -> String {
        let first = thread.comments.first.flatMap { firstWords($0) } ?? ""
        return (["Resolved" + (thread.resolvedBy.map { " by \($0)" } ?? ""), location(thread), first.isEmpty ? nil : first]
            .compactMap { $0 }).joined(separator: " \u{00B7} ")
    }

    static func firstWords(_ comment: GitHubComment, limit: Int = 70) -> String {
        let plain = comment.parts.compactMap { part -> String? in
            switch part {
            case .markdown(let text): return text
            case .suggestion: return "Suggestion"
            case .details(let summary, _): return summary
            }
        }.joined(separator: " ")
        let line = plain.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*_ `-")) }.first { !$0.isEmpty } ?? ""
        return ActivityLogic.truncate(line, to: limit)
    }

    // MARK: Counts

    static func commentsSummary(_ comments: GitHubComments) -> String {
        func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
        return [count(comments.threads.count, "thread"), "\(comments.unresolved) unresolved", count(comments.commentCount, "comment")]
            .joined(separator: " \u{00B7} ")
    }

    /// `50 of 94 threads` while more is to load.
    static func commentsProgress(_ comments: GitHubComments) -> String? {
        guard comments.hasMore else { return nil }
        return comments.threadTotal > comments.threads.count ? "\(comments.threads.count) of \(comments.threadTotal) threads" : "More comments"
    }

    // MARK: New

    /// Comments by others after this date are new: your last commit, review or reply, as the list works it out.
    static func feedbackCutoff(_ pr: GitHubPR) -> Date? {
        guard pr.state == .open, let activity = pr.activity else { return nil }
        let me = activity.me
        let mine = pr.author == me
        let reviews = activity.reviews.map { GitHubActivity.Event(actor: $0.actor, date: $0.date) }
        let dates = ([mine ? activity.lastCommit : nil, activity.lastComment.flatMap { $0.actor.login == me ? $0.date : nil }]
                     + (activity.open + reviews).map { $0.actor.login == me ? $0.date : nil }).compactMap { $0 }
        return dates.max() ?? (mine ? .distantPast : nil)
    }

    static func isNew(_ comment: GitHubComment, me: String, after cutoff: Date?) -> Bool {
        guard let cutoff, let created = comment.created else { return false }
        return comment.author.login != me && created > cutoff
    }

    // MARK: Filtering

    private static func matches(_ comment: GitHubComment, _ words: [String], path: String = "") -> Bool {
        let text = (path + " " + comment.author.login + " " + comment.body).lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    private static func words(_ query: String) -> [String] { query.lowercased().split(separator: " ").map(String.init) }

    static func visibleThreads(_ comments: GitHubComments, _ filter: GitHubCommentsFilter, after cutoff: Date?) -> [GitHubThread] {
        let words = words(filter.query)
        let me = comments.me
        return comments.threads.filter { thread in
            switch filter.scope {
            case .unresolved: if thread.isResolved { return false }
            case .mine: if me.isEmpty || !thread.comments.contains(where: { $0.author.login == me }) { return false }
            case .new: if !thread.comments.contains(where: { isNew($0, me: me, after: cutoff) }) { return false }
            case .all: break
            }
            if filter.hideBots && thread.comments.allSatisfy({ $0.author.isBot }) { return false }
            return words.isEmpty || words.allSatisfy { word in
                thread.path.lowercased().contains(word) || thread.comments.contains { matches($0, [word]) }
            }
        }
    }

    /// The conversation under the filter; resolving does not apply to it, so it is left out of the unresolved view.
    static func visibleConversation(_ comments: GitHubComments, _ filter: GitHubCommentsFilter, after cutoff: Date?) -> [GitHubComment] {
        if filter.scope == .unresolved { return [] }
        let words = words(filter.query)
        return comments.conversation.filter { comment in
            switch filter.scope {
            case .mine: if comments.me.isEmpty || comment.author.login != comments.me { return false }
            case .new: if !isNew(comment, me: comments.me, after: cutoff) { return false }
            default: break
            }
            return (!filter.hideBots || !comment.author.isBot) && matches(comment, words)
        }
    }

    /// Threads by file, files in path order, threads by line.
    static func groupedByFile(_ threads: [GitHubThread]) -> [GitHubFileThreads] {
        func position(_ thread: GitHubThread) -> Int { thread.line ?? thread.originalLine ?? .max }
        return Dictionary(grouping: threads, by: \.path).map { path, threads in
            GitHubFileThreads(path: path, threads: threads.sorted {
                (position($0), $0.comments.first?.created ?? .distantFuture, $0.id) < (position($1), $1.comments.first?.created ?? .distantFuture, $1.id)
            })
        }.sorted { $0.path.lowercased() < $1.path.lowercased() }
    }

    /// The scope a page opens with: the unresolved threads when there are any.
    static func defaultScope(_ comments: GitHubComments) -> GitHubCommentsFilter.Scope { comments.unresolved > 0 ? .unresolved : .all }

    // MARK: Bodies

    /// The parts of a comment: collapsible `<details>` with their summary, `suggestion` fences, and the rest as cleaned Markdown.
    static func commentParts(_ body: String) -> [GitHubCommentPart] {
        let text = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        return detailParts(text)
    }

    private static let detailsTag = "</?details\\b[^>]*>"

    private static func detailParts(_ text: String) -> [GitHubCommentPart] {
        var parts: [GitHubCommentPart] = []
        var rest = text
        while let open = rest.range(of: "<details\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            parts += suggestionParts(String(rest[..<open.lowerBound]))
            var depth = 1
            var cursor = open.upperBound
            var inner = rest[open.upperBound...]
            var end = rest.endIndex
            while let token = rest.range(of: detailsTag, options: [.regularExpression, .caseInsensitive], range: cursor..<rest.endIndex) {
                depth += rest[token].hasPrefix("</") ? -1 : 1
                cursor = token.upperBound
                if depth == 0 {
                    inner = rest[open.upperBound..<token.lowerBound]
                    end = token.upperBound
                    break
                }
            }
            var content = String(inner)
            var summary = "Details"
            if let range = content.range(of: "<summary\\b[^>]*>([\\s\\S]*?)</summary>", options: [.regularExpression, .caseInsensitive]) {
                let plain = content[range].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !plain.isEmpty { summary = plain }
                content.removeSubrange(range)
            }
            parts.append(.details(summary: summary, parts: detailParts(content)))
            rest = String(rest[end...])
        }
        return parts + suggestionParts(rest)
    }

    private static func suggestionParts(_ text: String) -> [GitHubCommentPart] {
        var parts: [GitHubCommentPart] = []
        var markdown: [String] = []
        var suggestion: [String]?
        func flush() {
            let cleaned = cleanBody(markdown.joined(separator: "\n"))
            if !cleaned.isEmpty { parts.append(.markdown(cleaned)) }
            markdown = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if suggestion != nil, trimmed.hasPrefix("```") {
                parts.append(.suggestion(suggestion?.joined(separator: "\n") ?? ""))
                suggestion = nil
            } else if suggestion != nil {
                suggestion?.append(line)
            } else if trimmed.hasPrefix("```suggestion") {
                flush()
                suggestion = []
            } else {
                markdown.append(line)
            }
        }
        if let suggestion { parts.append(.suggestion(suggestion.joined(separator: "\n"))) }
        flush()
        return parts
    }

    /// The start of a long bot comment, up to a few paragraphs of its opening text; nil when it is short enough to show whole.
    static func digest(_ parts: [GitHubCommentPart], body: String, limit: Int = 260) -> String? {
        let hasDetails = parts.contains { if case .details = $0 { return true } else { return false } }
        guard hasDetails || body.count > 700 else { return nil }
        guard case .markdown(let text)? = parts.first else { return "" }
        var kept: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            kept.append(paragraph)
            if kept.joined(separator: "\n\n").count >= limit || kept.count == 3 { break }
        }
        return ChatLogic.trim(kept.joined(separator: "\n\n"), maxCharacters: 500, marker: "\n\u{2026}")
    }
}
