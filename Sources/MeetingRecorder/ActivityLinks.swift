import Foundation

/// A page on GitHub (also GitHub Enterprise on `github.*`), GitLab (`gitlab.com` and self-hosted `gitlab.*`) or
/// Bitbucket, from a cleaned `host/path` address.
struct CodeHostLink: Equatable {
    enum Kind: Equatable {
        case repository
        case pullRequest(String)
        case mergeRequest(String)
        case issue(String)
        case commit(String)
    }

    let host: String
    let owner: String
    let repo: String
    let kind: Kind

    /// `quiddly-com/finq.api · PR #2094`, `· MR !12`, `· Issue #12` or `· commit 6253f44`.
    var label: String {
        let base = "\(owner)/\(repo)"
        switch kind {
        case .repository: return base
        case .pullRequest(let number): return "\(base) \u{00B7} PR #\(number)"
        case .mergeRequest(let number): return "\(base) \u{00B7} MR !\(number)"
        case .issue(let number): return "\(base) \u{00B7} Issue #\(number)"
        case .commit(let sha): return "\(base) \u{00B7} commit \(sha.prefix(7))"
        }
    }

    var promptText: String {
        switch kind {
        case .repository: return "\(owner)/\(repo)"
        case .pullRequest(let number), .mergeRequest(let number): return "\(owner)/\(repo), pull request \(number)"
        case .issue(let number): return "\(owner)/\(repo), issue \(number)"
        case .commit(let sha): return "\(owner)/\(repo), commit \(sha.prefix(7))"
        }
    }

    private static let githubReserved: Set<String> = [
        "login", "logout", "session", "sessions", "auth", "password_reset", "join", "signup", "settings", "notifications", "orgs", "organizations", "marketplace", "explore", "topics",
        "sponsors", "features", "pulls", "issues", "search", "new", "apps", "codespaces", "users", "enterprise", "enterprises", "about",
        "pricing", "site", "collections", "trending", "dashboard", "account", "copilot", "security", "readme", "stars", "watching",
    ]
    private static let bitbucketReserved: Set<String> = ["account", "dashboard", "workspace", "repo", "product", "site", "socialauth"]

    static func parse(_ url: String?) -> CodeHostLink? {
        guard let url else { return nil }
        let parts = url.split(separator: "/").map(String.init)
        guard let host = parts.first?.lowercased(), parts.count >= 3 else { return nil }
        let path = Array(parts.dropFirst())
        if host == "github.com" || host.hasPrefix("github.") { return github(host, path) }
        if host == "gitlab.com" || host.hasPrefix("gitlab.") { return gitlab(host, path) }
        if host == "bitbucket.org" { return bitbucket(host, path) }
        return nil
    }

    private static func github(_ host: String, _ path: [String]) -> CodeHostLink? {
        guard !githubReserved.contains(path[0].lowercased()) else { return nil }
        let rest = Array(path.dropFirst(2))
        let kind: Kind
        switch (rest.first, number(rest, at: 1)) {
        case ("pull", let number?): kind = .pullRequest(number)
        case ("issues", let number?): kind = .issue(number)
        case ("commit", _) where rest.count > 1: kind = .commit(rest[1])
        default: kind = .repository
        }
        return CodeHostLink(host: host, owner: path[0], repo: path[1], kind: kind)
    }

    /// Groups nest (`group/sub/project`); the project's own pages are under `/-/`.
    private static func gitlab(_ host: String, _ path: [String]) -> CodeHostLink? {
        guard !["users", "explore", "dashboard", "help", "-"].contains(path[0].lowercased()) else { return nil }
        let dash = path.firstIndex(of: "-")
        let marker = dash ?? 2
        guard marker >= 2 else { return nil }
        let rest = Array(path[(dash.map { $0 + 1 } ?? 2)...])
        let kind: Kind
        switch (rest.first, number(rest, at: 1)) {
        case ("merge_requests", let number?): kind = .mergeRequest(number)
        case ("issues", let number?): kind = .issue(number)
        case ("commit", _) where rest.count > 1: kind = .commit(rest[1])
        default: kind = .repository
        }
        return CodeHostLink(host: host, owner: path[..<(marker - 1)].joined(separator: "/"), repo: path[marker - 1], kind: kind)
    }

    private static func bitbucket(_ host: String, _ path: [String]) -> CodeHostLink? {
        guard !bitbucketReserved.contains(path[0].lowercased()) else { return nil }
        let rest = Array(path.dropFirst(2))
        let kind: Kind
        switch (rest.first, number(rest, at: 1)) {
        case ("pull-requests", let number?): kind = .pullRequest(number)
        case ("issues", let number?): kind = .issue(number)
        case ("commits", _) where rest.count > 1: kind = .commit(rest[1])
        default: kind = .repository
        }
        return CodeHostLink(host: host, owner: path[0], repo: path[1], kind: kind)
    }

    private static func number(_ parts: [String], at index: Int) -> String? {
        index < parts.count && !parts[index].isEmpty && parts[index].allSatisfy(\.isNumber) ? parts[index] : nil
    }
}

/// A Jira page on `*.atlassian.net`: an issue (`/browse/KEY-1`) or a project (`/jira/software/projects/KEY/...`).
struct JiraLink: Equatable {
    let site: String
    let prefix: String
    let ticket: String?

    static func parse(_ url: String?) -> JiraLink? {
        guard let url else { return nil }
        let parts = url.split(separator: "/").map(String.init)
        guard let site = parts.first?.lowercased(), site.hasSuffix(".atlassian.net") else { return nil }
        if let browse = parts.firstIndex(of: "browse"), browse + 1 < parts.count, let ticket = ActivityLogic.ticket(in: parts[browse + 1]) {
            return JiraLink(site: site, prefix: ActivityLogic.ticketPrefix(ticket), ticket: ticket)
        }
        if let projects = parts.firstIndex(of: "projects"), projects + 1 < parts.count,
           parts[projects + 1].range(of: "^[A-Z][A-Z0-9]{1,9}$", options: .regularExpression) != nil {
            let ticket = ActivityLogic.ticket(in: parts[(projects + 2)...].joined(separator: "/"))
            return JiraLink(site: site, prefix: parts[projects + 1], ticket: ticket)
        }
        return nil
    }
}

/// What has been learned about tickets from the pages seen: their titles, and the Jira site of each prefix.
struct TicketDirectory: Equatable {
    var titles: [String: String] = [:]
    var sites: [String: String] = [:]

    func url(for ticket: String) -> URL? {
        sites[ActivityLogic.ticketPrefix(ticket)].flatMap { URL(string: "https://\($0)/browse/\(ticket)") }
    }

    /// `QDLY-8315 · Add Strawbay (kfm-api)…`, or the key alone when no title is known.
    func label(_ ticket: String, limit: Int = 60) -> String {
        titles[ticket].map { "\(ticket) \u{00B7} \(ActivityLogic.truncate($0, to: limit))" } ?? ticket
    }

    /// A Markdown link to the ticket when its site is known.
    func markdown(_ ticket: String) -> String {
        let text = label(ticket, limit: 80)
        return url(for: ticket).map { "[\(text)](\($0.absoluteString))" } ?? text
    }
}

/// The branches of the repositories under `~/git`, for linking a ticket seen in the browser to the branch it is worked on.
struct BranchIndex: Equatable {
    var branches: [String: [String]] = [:]

    /// A branch whose name contains the ticket key as a whole key (`QDLY-83` is not in `QDLY-8315`): in the given
    /// repository when it is known, else in any; the shortest name wins, then the first by name.
    func branch(for ticket: String, repo: String?) -> (repo: String, branch: String)? {
        let candidates = repo.map { [($0, branches[$0] ?? [])] } ?? branches.map { ($0.key, $0.value) }
        return candidates.flatMap { repo, names in names.filter { Self.contains($0, ticket) }.map { (repo: repo, branch: $0) } }
            .min { ($0.branch.count, $0.repo, $0.branch) < ($1.branch.count, $1.repo, $1.branch) }
    }

    private static func contains(_ branch: String, _ ticket: String) -> Bool {
        var search = branch.startIndex..<branch.endIndex
        while let range = branch.range(of: ticket, options: .caseInsensitive, range: search) {
            let before = range.lowerBound == branch.startIndex ? nil : branch[branch.index(before: range.lowerBound)]
            let after = range.upperBound == branch.endIndex ? nil : branch[range.upperBound]
            if !(before.map { $0.isLetter || $0.isNumber } ?? false), !(after?.isNumber ?? false) { return true }
            search = range.upperBound..<branch.endIndex
        }
        return false
    }

    /// The local branches of each repository folder, keyed by its name: loose refs, `packed-refs` and what its
    /// worktrees have checked out. Nothing is run; the files are read.
    static func scan(_ repositories: [URL], fileManager: FileManager = .default) -> BranchIndex {
        var index = BranchIndex()
        for repo in repositories {
            guard let git = gitFolder(of: repo, fileManager: fileManager) else { continue }
            let common = commonFolder(git, fileManager: fileManager)
            var names = Set(looseRefs(common.appendingPathComponent("refs/heads"), fileManager: fileManager))
            if let packed = try? String(contentsOf: common.appendingPathComponent("packed-refs"), encoding: .utf8) {
                names.formUnion(packedBranches(packed))
            }
            let worktrees = (try? fileManager.contentsOfDirectory(at: common.appendingPathComponent("worktrees"), includingPropertiesForKeys: nil)) ?? []
            names.formUnion(([git] + worktrees).compactMap(headBranch))
            index.branches[repo.lastPathComponent] = names.union(index.branches[repo.lastPathComponent] ?? []).sorted()
        }
        return index
    }

    static func packedBranches(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1].hasPrefix("refs/heads/") else { return nil }
            return String(parts[1].dropFirst("refs/heads/".count))
        }
    }

    /// The branch checked out in a git folder; nil when its HEAD is detached.
    private static func headBranch(_ git: URL) -> String? {
        guard let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8), head.hasPrefix("ref: refs/heads/") else { return nil }
        return ActivityLogic.branch(fromHEAD: head)
    }

    private static func gitFolder(of repo: URL, fileManager: FileManager) -> URL? {
        let git = repo.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: git.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return git }
        guard let pointer = try? String(contentsOf: git, encoding: .utf8),
              let line = pointer.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appendingPathComponent(path)
    }

    /// A worktree's git folder points at the shared one through its `commondir` file.
    private static func commonFolder(_ git: URL, fileManager: FileManager) -> URL {
        guard let common = try? String(contentsOf: git.appendingPathComponent("commondir"), encoding: .utf8) else { return git }
        let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : git.appendingPathComponent(path).standardizedFileURL
    }

    private static func looseRefs(_ folder: URL, fileManager: FileManager) -> [String] {
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = folder.standardizedFileURL.path + "/"
        return enumerator.compactMap { item in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            let path = url.standardizedFileURL.path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
        }
    }
}

extension ActivityLogic {
    static func ticketPrefix(_ ticket: String) -> String {
        ticket.firstIndex(of: "-").map { String(ticket[..<$0]) } ?? ticket
    }

    /// Fills what a block's address says about its repository: the repository and its owner from a code host, and a
    /// local branch for a ticket seen in the browser. Only empty fields are filled.
    static func linked(_ key: ActivityKey, branches: BranchIndex = BranchIndex()) -> ActivityKey {
        var key = key
        if let link = CodeHostLink.parse(key.url) {
            if key.repo == nil { key.repo = link.repo }
            if key.owner == nil { key.owner = link.owner }
        }
        if key.url != nil, key.branch == nil, let ticket = key.ticket, let found = branches.branch(for: ticket, repo: key.repo) {
            key.branch = found.branch
            if key.repo == nil { key.repo = found.repo }
        }
        return key
    }

    /// The page title without the browser's own suffix (` - Google Chrome – Profile`).
    static func pageTitle(_ windowTitle: String) -> String {
        windowTitle.replacingOccurrences(of: "\\s[-\u{2013}\u{2014}]\\s(Google Chrome|Brave|Microsoft Edge|Mozilla Firefox|Firefox|Safari|Arc|Chromium|Opera|Vivaldi)(\\s[-\u{2013}\u{2014}]\\s.*)?$",
                                         with: "", options: .regularExpression)
    }

    /// A ticket's title from a Jira issue page (`[QDLY-1] Title - Jira`, `QDLY-1: Title - Jira`) or a pull request
    /// whose title starts with the key (`QDLY-1: Title by me · Pull Request #12 · owner/repo`). A title left over from
    /// another page is not taken: the Jira issue in the address, or the pull request number, has to agree.
    static func ticketTitle(windowTitle: String?, url: String?) -> (ticket: String, title: String)? {
        guard let windowTitle else { return nil }
        let page = pageTitle(windowTitle)
        let keyed = "^\\[?([A-Z][A-Z0-9]{1,9}-[0-9]{1,6})\\]?:?\\s+(.+?)"
        if let jira = JiraLink.parse(url), let match = groups(page, keyed + "\\s[-\u{2013}]\\s(Jira|JIRA)$") {
            guard jira.ticket == nil || jira.ticket == match[0] else { return nil }
            return (match[0], match[1])
        }
        if let link = CodeHostLink.parse(url), case .pullRequest(let number) = link.kind,
           let match = groups(page, keyed + "(\\sby\\s\\S+)?\\s\u{00B7}\\sPull Request #\(number)\\b.*$") {
            return (match[0], match[1])
        }
        return nil
    }

    private static func groups(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    /// A short label for an address: a code-host page as `owner/repo · PR #1`; otherwise long hashes are cut to seven
    /// characters and a long address loses its middle.
    static func urlLabel(_ url: String, limit: Int = 60) -> String {
        if let link = CodeHostLink.parse(url) { return link.label }
        let short = url.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            part.count >= 16 && part.allSatisfy({ $0.isHexDigit }) ? part.prefix(7) + "\u{2026}" : String(part)
        }.joined(separator: "/")
        guard short.count > limit else { return short }
        let head = limit * 3 / 5
        return short.prefix(head) + "\u{2026}" + short.suffix(limit - head - 1)
    }
}
