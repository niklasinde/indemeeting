import Foundation

/// One changed file with its unified diff, as GitHub's REST API returns it; `patch` is missing for binary or very large files.
struct GitHubFilePatch: Equatable, Identifiable {
    let path: String
    var previousPath: String?
    let change: GitHubPRDetail.Change
    var additions = 0
    var deletions = 0
    var patch: String?

    var id: String { path }
    var title: String { previousPath.map { "\($0) \u{2192} \(path)" } ?? path }
}

/// A line of a rendered diff, with its numbers in the old and the new file.
struct GitHubDiffRow: Equatable {
    enum Kind: Equatable { case hunk, added, removed, context, note }
    let kind: Kind
    var old: Int?
    var new: Int?
    let text: String
}

/// A file's diff rows with their syntax spans, worked out once per patch; `spans` is nil for a language without rules.
struct GitHubDiffRender {
    let rows: [GitHubDiffRow]
    let spans: [[SyntaxSpan]]?
}

/// A diff's files and which of them were open, kept to restore it when it is shown again.
struct GitHubCachedDiff {
    var files: [GitHubFilePatch]
    var expanded: Set<String>
}

/// The values of the most recently stored keys, the oldest dropped past `limit`.
struct RecentCache<Value> {
    let limit: Int
    private(set) var keys: [String] = []
    private var values: [String: Value] = [:]

    init(limit: Int) { self.limit = limit }

    subscript(key: String) -> Value? { values[key] }

    mutating func store(_ value: Value, for key: String) {
        values[key] = value
        keys.removeAll { $0 == key }
        keys.append(key)
        while keys.count > limit { values[keys.removeFirst()] = nil }
    }
}

enum GitHubDiffLogic {
    static let pageSize = 100
    /// GitHub lists at most 3000 files of a pull request.
    static let maxPages = 30
    /// Rows shown of a file before "Show all".
    static let visibleRows = 400
    /// Files open when a pull request or commit is first shown.
    static let initiallyOpen = 5
    /// Pull requests and commits whose files stay in memory.
    static let cachedDiffs = 20

    static func initiallyExpanded(_ paths: [String]) -> Set<String> {
        Set(paths.prefix(initiallyOpen))
    }

    static func filesArguments(repo: String, number: Int, page: Int) -> [String] {
        ["api", "repos/\(repo)/pulls/\(number)/files?per_page=\(pageSize)&page=\(page)"]
    }

    static func commitArguments(repo: String, sha: String) -> [String] {
        ["api", "repos/\(repo)/commits/\(sha)"]
    }

    private struct FileJSON: Decodable {
        let filename: String?
        let previous_filename: String?
        let status: String?
        let additions: Int?
        let deletions: Int?
        let patch: String?
    }

    private struct CommitJSON: Decodable { let files: [FileJSON]? }

    /// A page of `pulls/{n}/files`, or the files of `commits/{sha}`.
    static func parseFiles(_ data: Data) throws -> [GitHubFilePatch] {
        let decoder = JSONDecoder()
        let files = try (try? decoder.decode([FileJSON].self, from: data)) ?? decoder.decode(CommitJSON.self, from: data).files ?? []
        return files.compactMap { file in
            guard let path = file.filename else { return nil }
            return GitHubFilePatch(path: path, previousPath: file.previous_filename.flatMap { $0 == path ? nil : $0 },
                                   change: GitHubPRDetail.Change(rawValue: file.status ?? "") ?? .modified,
                                   additions: file.additions ?? 0, deletions: file.deletions ?? 0, patch: file.patch)
        }
    }

    /// The rows of a unified diff, numbered from each `@@ -a,b +c,d @@` header.
    static func rows(_ patch: String) -> [GitHubDiffRow] {
        var rows: [GitHubDiffRow] = []
        var old = 0, new = 0
        for line in patch.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                let start = hunkStart(line)
                old = start.old
                new = start.new
                rows.append(GitHubDiffRow(kind: .hunk, text: line))
            } else if line.hasPrefix("\\") {
                rows.append(GitHubDiffRow(kind: .note, text: line))
            } else if line.hasPrefix("+") {
                rows.append(GitHubDiffRow(kind: .added, new: new, text: String(line.dropFirst())))
                new += 1
            } else if line.hasPrefix("-") {
                rows.append(GitHubDiffRow(kind: .removed, old: old, text: String(line.dropFirst())))
                old += 1
            } else if !line.isEmpty {
                rows.append(GitHubDiffRow(kind: .context, old: old, new: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            }
        }
        return rows
    }

    static func render(_ patch: String, path: String) -> GitHubDiffRender {
        let rows = Self.rows(patch)
        return GitHubDiffRender(rows: rows, spans: SyntaxLanguage.forPath(path).map { highlight(rows, language: $0) })
    }

    /// Tokenizes the old and the new side apart, so a string opened on a removed line does not run into the added ones.
    static func highlight(_ rows: [GitHubDiffRow], language: SyntaxLanguage) -> [[SyntaxSpan]] {
        var old = SyntaxState.code, new = SyntaxState.code
        return rows.map { row in
            switch row.kind {
            case .hunk:
                old = .code
                new = .code
                return []
            case .note:
                return []
            case .removed:
                return SyntaxLogic.tokenize(row.text, language: language, state: &old)
            case .added:
                return SyntaxLogic.tokenize(row.text, language: language, state: &new)
            case .context:
                let spans = SyntaxLogic.tokenize(row.text, language: language, state: &new)
                old = new
                return spans
            }
        }
    }

    static func hunkStart(_ header: String) -> (old: Int, new: Int) {
        func number(after marker: Character) -> Int {
            guard let range = header.firstIndex(of: marker) else { return 0 }
            return Int(header[header.index(after: range)...].prefix { $0.isNumber }) ?? 0
        }
        return (number(after: "-"), number(after: "+"))
    }

    /// The threads that belong under a row, by its index, and those that cannot be placed: on the whole file, outdated,
    /// or on a line this diff does not show.
    static func placement(_ threads: [GitHubThread], in rows: [GitHubDiffRow]) -> (placed: [Int: [GitHubThread]], unplaced: [GitHubThread]) {
        var placed: [Int: [GitHubThread]] = [:]
        var unplaced: [GitHubThread] = []
        for thread in threads {
            guard !thread.isFile, let line = thread.line,
                  let index = rows.firstIndex(where: { row in
                      thread.isLeft ? row.old == line && row.kind != .added : row.new == line && row.kind != .removed
                  }) else {
                unplaced.append(thread)
                continue
            }
            placed[index, default: []].append(thread)
        }
        return (placed, unplaced)
    }
}
