import Foundation

/// Read-only pull request tools for the MCP server. They read the cache the GitHub view keeps and never run `gh`.
extension MCPServer {
    /// The app's preferences domain. The `--mcp` process starts through a link, so its `Bundle.main` is not the app.
    static let appDomain = "com.niklasinde.MeetingRecorder"
    static let descriptionLimit = 2000

    static func githubSwitchIsOn() -> Bool {
        CFPreferencesCopyAppValue(GitHubLogic.enabledKey as CFString, appDomain as CFString) as? Bool ?? false
    }

    static func githubTools(_ opened: Result<MeetingStore, Error>, enabled: @escaping () -> Bool = githubSwitchIsOn,
                            workspaces: WorkspaceSource = WorkspaceSource(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func answer(_ body: (MeetingStore, [GitHubKind: [GitHubPR]]) throws -> String) throws -> String {
            guard enabled() else { return "GitHub is off in WorkTime settings.\n" }
            let store = try openedStore(opened)
            let prs = try store.githubPRs()
            guard prs.values.contains(where: { !$0.isEmpty }) else {
                return "No GitHub pull requests are cached yet. Open the GitHub view in WorkTime to fetch them.\n"
            }
            return cut(try body(store, prs), at: outputLimit)
        }
        func cachedText(_ store: MeetingStore) throws -> String {
            (try store.githubFetched()).map { "cached \(GitHubLogic.updatedText($0, now: now()))" } ?? "never cached"
        }
        let kinds = GitHubKind.allCases.map(\.rawValue)
        let states = GitHubLogic.StateFilter.allCases.map { $0.rawValue.lowercased() }
        return [
            MCPTool(name: "github_prs",
                    description: "Pull requests from the app's GitHub cache, most recently updated first: repo and number, title, url, author, "
                        + "draft, review decision, checks, unresolved threads, new comments and whether they wait on the user. "
                        + "Optional filters, all combined: repo, author, query, waiting_on_me, draft, checks and review. "
                        + "Read-only; the GitHub view in the app refreshes the cache.",
                    properties: ["kind": ["type": "string", "enum": kinds + ["all"],
                                          "description": "created (default), review_requested, assigned, mentioned, reviewed, or all for every "
                                            + "cached list, each pull request once."],
                                 "state": ["type": "string", "enum": states, "description": "open (default), merged, closed or all."],
                                 "repo": ["type": "string", "description": "owner/repo or a bare repo name of any owner, ignoring case; "
                                            + "several comma-separated."],
                                 "author": ["type": "string", "description": "GitHub login ignoring case, or me for the signed-in user."],
                                 "query": ["type": "string", "description": "Words that must all appear in the title (ticket keys included), "
                                            + "owner/repo#number, author or labels, ignoring case."],
                                 "waiting_on_me": ["type": "boolean", "description": "true for only those waiting on the user, false for none of them."],
                                 "draft": ["type": "boolean", "description": "true for only drafts, false for no drafts."],
                                 "checks": ["type": "string", "enum": Array(checkNames.keys).sorted(), "description": "failing, pending or passing."],
                                 "review": ["type": "string", "enum": Array(reviewNames.keys).sorted(),
                                            "description": "The review decision: approved, changes_requested or review_required."],
                                 "limit": limitSchema("pull requests", 20)]) { args in
                let kindName = args["kind"] as? String ?? GitHubKind.created.rawValue
                let kind = GitHubKind(rawValue: kindName)
                guard kind != nil || kindName == "all" else {
                    throw MCPToolError("kind must be one of \((kinds + ["all"]).joined(separator: ", "))")
                }
                let stateName = args["state"] as? String ?? "open"
                guard let state = GitHubLogic.StateFilter.allCases.first(where: { $0.rawValue.lowercased() == stateName }) else {
                    throw MCPToolError("state must be one of \(states.joined(separator: ", "))")
                }
                var (filter, applied) = try pullRequestFilter(args, state: state)
                let listName = kind?.tabTitle ?? "All lists"
                let matching = applied.isEmpty ? "" : " matching " + applied.joined(separator: ", ")
                return try answer { store, prs in
                    if filter.author?.lowercased() == "me", let me = GitHubLogic.me(in: prs) { filter.author = me }
                    let rows = GitHubLogic.filter(kind.map { prs[$0] ?? [] } ?? GitHubLogic.unique(prs), filter)
                    guard !rows.isEmpty else { return "No \(stateName) pull requests in the \(listName.lowercased()) list\(matching).\n" }
                    let shown = rows.prefix(count(args["limit"], fallback: 20))
                    let cached = try cachedText(store)
                    return "\(([listName, stateName] + applied).joined(separator: ", ")): \(shown.count) of \(rows.count) pull requests, \(cached)\n"
                        + shown.map { pullRequestLine($0, now: now()) }.joined()
                }
            },
            MCPTool(name: "github_pr",
                    description: "One pull request from the GitHub cache as Markdown: state, branches, mergeable state, reviewers and their latest "
                        + "reviews, checks, ticket keys and the description. When its detail was never fetched, only the list fields are given.",
                    properties: ["pr": ["type": "string", "description": "The pull request's GitHub url, or owner/repo#number."]],
                    required: ["pr"]) { args in
                let text = (args["pr"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let url: String
                if text.hasPrefix("https://") {
                    url = text
                } else if let reference = GitHubLogic.reference(text) {
                    url = "https://\(GitHubLogic.host)/\(reference.repo)/pull/\(reference.number)"
                } else {
                    throw MCPToolError("pr is required: a GitHub url or owner/repo#number, not \(text)")
                }
                return try answer { store, prs in
                    let fetched = try store.githubDetailFetched()[url]
                    if let detail = try store.githubDetail(url) {
                        return pullRequestDetail(detail, fetched: fetched, now: now())
                    }
                    guard let row = prs.values.joined().first(where: { $0.url == url }) else {
                        throw MCPToolError("No cached pull request \(text). Open it in the GitHub view in WorkTime to fetch it.")
                    }
                    return "Its detail is not cached; open it in the GitHub view to fetch it. List fields:\n" + pullRequestLine(row, now: now())
                }
            },
            MCPTool(name: "github_needs_attention",
                    description: "Open pull requests that wait on the user (a review asked of them, or the author answered their review) or have "
                        + "new comments from people, most urgent first, with the same fields as github_prs. Read-only.",
                    properties: ["limit": limitSchema("pull requests", 10), "workspace": workspaceProperty]) { args in
                let scope = try workspaces.scope(args)
                return try answer { store, prs in
                    let unique = Workspaces.filter(GitHubLogic.unique(prs), in: scope, file: workspaces.file())
                    let rows = GitHubLogic.sorted(unique.filter { pr in
                        let signals = GitHubLogic.signals(pr)
                        return signals.waitingOnMe || signals.newFeedback > 0
                    }, by: .needsAttention)
                    guard !rows.isEmpty else { return "Nothing waits on you and no open pull request has new comments from people.\n" }
                    let shown = rows.prefix(count(args["limit"]))
                    let cached = try cachedText(store)
                    return "Needs attention: \(shown.count) of \(rows.count) pull requests, \(cached)\n"
                        + shown.map { pullRequestLine($0, now: now()) }.joined()
                }
            },
        ]
    }

    static let checkNames: [String: GitHubPR.Checks] = ["failing": .failed, "pending": .running, "passing": .passed]
    static let reviewNames: [String: GitHubPR.Review] = ["approved": .approved, "changes_requested": .changesRequested,
                                                         "review_required": .required]

    /// The list filter the github_prs arguments ask for, and each filter applied as text for the answer's header.
    static func pullRequestFilter(_ args: [String: Any], state: GitHubLogic.StateFilter) throws -> (GitHubLogic.Filter, [String]) {
        func text(_ key: String) -> String? {
            (args[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func named<Value>(_ key: String, _ names: [String: Value]) throws -> Value? {
            guard let name = text(key) else { return nil }
            guard let value = names[name.lowercased()] else {
                throw MCPToolError("\(key) must be one of \(names.keys.sorted().joined(separator: ", "))")
            }
            return value
        }
        let filter = GitHubLogic.Filter(state: state, repo: text("repo"), query: text("query") ?? "", author: text("author"),
                                        draft: args["draft"] as? Bool, checks: try named("checks", checkNames),
                                        review: try named("review", reviewNames), waitingOnMe: args["waiting_on_me"] as? Bool)
        let applied = [filter.repo.map { "repo \($0)" }, filter.author.map { "author \($0)" },
                       filter.query.isEmpty ? nil : "query \"\(filter.query)\"",
                       filter.waitingOnMe.map { $0 ? "waiting on you" : "not waiting on you" },
                       filter.draft.map { $0 ? "drafts" : "no drafts" },
                       text("checks").map { "checks \($0.lowercased())" }, text("review").map { "review \($0.lowercased())" }]
        return (filter, applied.compactMap { $0 })
    }

    /// One pull request on two lines: the heading with its url, then the facts that matter for the list.
    static func pullRequestLine(_ pr: GitHubPR, now: Date) -> String {
        let signals = GitHubLogic.signals(pr)
        let review = pr.review.map(reviewText)
        let facts = [pr.state == .open ? nil : pr.state.rawValue, pr.isDraft ? "draft" : nil, "by \(pr.author ?? "unknown")",
                     review ?? "no review decision", checksText(pr.checks),
                     signals.unresolved > 0 ? "\(signals.unresolved) unresolved" : nil,
                     signals.newFeedback > 0 ? GitHubLogic.newCommentsText(signals.newFeedback) : nil,
                     signals.waitingOnMe ? "waiting on you" : nil,
                     "updated \(GitHubLogic.updatedText(pr.updated, now: now))"].compactMap { $0 }
        return "- \(pr.repo)#\(pr.number) \(pr.title)\n  \(pr.url)\n  " + facts.joined(separator: " \u{00B7} ") + "\n"
    }

    static func pullRequestDetail(_ detail: GitHubPRDetail, fetched: Date?, now: Date) -> String {
        let failing = detail.checks.filter { $0.status == .failed }.prefix(5).map(\.name)
        let reviewers = detail.reviewers.map { "\($0.name)\($0.isTeam ? " (team)" : ""): \(reviewerText($0.state))" }
        let body = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["# \(detail.repo)#\(detail.number) \(detail.title)", detail.url, "",
                     "- State: " + [detail.state.rawValue, detail.isDraft ? "draft" : nil, detail.author.map { "by \($0)" }]
                        .compactMap { $0 }.joined(separator: ", "),
                     "- Branches: \(detail.head) into \(detail.base)",
                     "- Mergeable: \(detail.mergeable.rawValue), merge state \(detail.mergeState.rawValue.lowercased())",
                     "- Review decision: " + (detail.review.map(reviewText) ?? "none"),
                     "- Checks: " + GitHubLogic.checkSummary(detail.checks) + (failing.isEmpty ? "" : " (failing: \(failing.joined(separator: ", ")))"),
                     "- Changes: " + GitHubLogic.changesText(additions: detail.additions, deletions: detail.deletions)
                        + " in \(detail.changedFiles) files"]
        if !reviewers.isEmpty { lines.append("- Reviewers: " + reviewers.joined(separator: ", ")) }
        let tickets = ticketKeys(detail.title, detail.head, detail.body)
        if !tickets.isEmpty { lines.append("- Ticket keys: " + tickets.joined(separator: ", ")) }
        if !detail.labels.isEmpty { lines.append("- Labels: " + detail.labels.joined(separator: ", ")) }
        if let updated = detail.updated { lines.append("- Updated: \(GitHubLogic.updatedText(updated, now: now))") }
        if let fetched { lines.append("- Detail \(GitHubLogic.updatedText(fetched, now: now))") }
        lines += ["", "## Description", body.isEmpty ? "(none)" : ActivityLogic.truncate(body, to: descriptionLimit)]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Every ticket key in the texts, once each, in the order they appear.
    static func ticketKeys(_ texts: String...) -> [String] {
        var keys: [String] = []
        for text in texts {
            for match in ActivityLogic.ticketPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text), !keys.contains(String(text[range])) else { continue }
                keys.append(String(text[range]))
            }
        }
        return keys
    }

    private static func reviewText(_ review: GitHubPR.Review) -> String {
        switch review {
        case .approved: return "approved"
        case .changesRequested: return "changes requested"
        case .required: return "review required"
        }
    }

    private static func reviewerText(_ state: GitHubPRDetail.ReviewState) -> String {
        switch state {
        case .approved: return "approved"
        case .changesRequested: return "changes requested"
        case .pending: return "review requested"
        case .commented: return "commented"
        case .dismissed: return "dismissed"
        }
    }

    private static func checksText(_ checks: GitHubPR.Checks) -> String {
        switch checks {
        case .passed: return "checks passed"
        case .failed: return "checks failed"
        case .running: return "checks running"
        case .none: return "no checks"
        }
    }
}
