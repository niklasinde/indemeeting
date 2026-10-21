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
                            now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func answer(_ body: (MeetingStore, [GitHubKind: [GitHubPR]]) throws -> String) throws -> String {
            guard enabled() else { return "GitHub is off in Meeting Recorder settings.\n" }
            let store = try openedStore(opened)
            let prs = try store.githubPRs()
            guard prs.values.contains(where: { !$0.isEmpty }) else {
                return "No GitHub pull requests are cached yet. Open the GitHub view in Meeting Recorder to fetch them.\n"
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
                        + "Read-only; the GitHub view in the app refreshes the cache.",
                    properties: ["kind": ["type": "string", "enum": kinds,
                                          "description": "created (default), review_requested, assigned or mentioned."],
                                 "state": ["type": "string", "enum": states, "description": "open (default), merged, closed or all."],
                                 "limit": limitSchema("pull requests", 20)]) { args in
                let kindName = args["kind"] as? String ?? GitHubKind.created.rawValue
                guard let kind = GitHubKind(rawValue: kindName) else { throw MCPToolError("kind must be one of \(kinds.joined(separator: ", "))") }
                let stateName = args["state"] as? String ?? "open"
                guard let state = GitHubLogic.StateFilter.allCases.first(where: { $0.rawValue.lowercased() == stateName }) else {
                    throw MCPToolError("state must be one of \(states.joined(separator: ", "))")
                }
                return try answer { store, prs in
                    let rows = GitHubLogic.filter(prs[kind] ?? [], GitHubLogic.Filter(state: state))
                    guard !rows.isEmpty else { return "No \(stateName) pull requests in the \(kind.tabTitle.lowercased()) list.\n" }
                    let shown = rows.prefix(count(args["limit"], fallback: 20))
                    let cached = try cachedText(store)
                    return "\(kind.tabTitle), \(stateName): \(shown.count) of \(rows.count) pull requests, \(cached)\n"
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
                        throw MCPToolError("No cached pull request \(text). Open it in the GitHub view in Meeting Recorder to fetch it.")
                    }
                    return "Its detail is not cached; open it in the GitHub view to fetch it. List fields:\n" + pullRequestLine(row, now: now())
                }
            },
            MCPTool(name: "github_needs_attention",
                    description: "Open pull requests that wait on the user (a review asked of them, or the author answered their review) or have "
                        + "new comments from people, most urgent first, with the same fields as github_prs. Read-only.",
                    properties: ["limit": limitSchema("pull requests", 10)]) { args in
                try answer { store, prs in
                    let unique = Dictionary(prs.values.joined().map { ($0.url, $0) }) { $1 }.values
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
