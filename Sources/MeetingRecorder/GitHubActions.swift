import Foundation

enum GitHubMergeMethod: String, CaseIterable, Identifiable {
    case squash, merge, rebase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .squash: return "Squash"
        case .merge: return "Merge commit"
        case .rebase: return "Rebase"
        }
    }

    var flag: String { "--\(rawValue)" }

    /// The methods the repository allows, in the order they are offered.
    static func allowed(squash: Bool?, merge: Bool?, rebase: Bool?) -> [GitHubMergeMethod] {
        [(GitHubMergeMethod.squash, squash), (.merge, merge), (.rebase, rebase)].compactMap { $1 == true ? $0 : nil }
    }

    /// The method asked for when it is allowed, otherwise the first one the repository allows.
    static func choose(_ current: GitHubMergeMethod, from allowed: [GitHubMergeMethod]) -> GitHubMergeMethod {
        allowed.contains(current) ? current : allCases.first { allowed.contains($0) } ?? current
    }
}

enum GitHubAction: String, CaseIterable, Identifiable {
    case approve, requestChanges = "request_changes", comment, merge, close, reopen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        case .comment: return "Comment"
        case .merge: return "Merge"
        case .close: return "Close"
        case .reopen: return "Reopen"
        }
    }

    var confirmTitle: String {
        switch self {
        case .approve: return "Approve pull request"
        case .requestChanges: return "Request changes"
        case .comment: return "Post comment"
        case .merge: return "Merge pull request"
        case .close: return "Close pull request"
        case .reopen: return "Reopen pull request"
        }
    }

    var pastTense: String {
        switch self {
        case .approve: return "Approved"
        case .requestChanges: return "Requested changes on"
        case .comment: return "Commented on"
        case .merge: return "Merged"
        case .close: return "Closed"
        case .reopen: return "Reopened"
        }
    }

    var isReview: Bool { self == .approve || self == .requestChanges || self == .comment }
    var commentRequired: Bool { self == .requestChanges || self == .comment }
    /// Return confirms these; the others need a deliberate click, and Return cancels.
    var returnConfirms: Bool { self == .comment || self == .close || self == .reopen }
}

/// One thing to do to one pull request, with the text the person wrote. It is the only input of the `gh` command line.
struct GitHubActionRequest: Equatable {
    var action: GitHubAction
    let repo: String
    let number: Int
    let title: String
    let url: String
    var comment = ""
    var deleteBranch = false
    var method = GitHubMergeMethod.squash

    init(_ action: GitHubAction, pr: GitHubPR) {
        self.action = action
        repo = pr.repo
        number = pr.number
        title = pr.title
        url = pr.url
    }

    init(_ action: GitHubAction, repo: String, number: Int, title: String, url: String, comment: String = "", deleteBranch: Bool = false) {
        self.action = action
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.comment = comment
        self.deleteBranch = deleteBranch
    }

    func with(comment: String, deleteBranch: Bool) -> GitHubActionRequest {
        var copy = self
        copy.comment = comment
        copy.deleteBranch = deleteBranch
        return copy
    }

    var trimmedComment: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }
    var reference: String { "\(repo) #\(number)" }
    var shortReference: String { "\(GitHubLogic.repoName(repo).name) #\(number)" }
}

/// What is known about a pull request when an action is about to run: the fetched state and who is signed in.
struct GitHubActionTarget: Equatable {
    var author: String?
    var viewer: String?
    var state = GitHubPR.State.open
    var isDraft = false
    var checks = GitHubPR.Checks.none
    var review: GitHubPR.Review?
    var head: String?
    var base: String?
    var mergeable = GitHubPRDetail.Mergeable.unknown
    var mergeState = GitHubPRDetail.MergeState.unknown
    var mergeMethods: [GitHubMergeMethod] = []

    init() {}

    init(pr: GitHubPR, detail: GitHubPRDetail? = nil, viewer: String? = nil) {
        author = detail?.author ?? pr.author
        self.viewer = viewer ?? pr.activity.flatMap { $0.me.isEmpty ? nil : $0.me }
        state = detail?.state ?? pr.state
        isDraft = detail?.isDraft ?? pr.isDraft
        checks = detail.map { $0.rollup == .none ? pr.checks : $0.rollup } ?? pr.checks
        review = detail?.review ?? pr.review
        head = detail.flatMap { $0.head.isEmpty ? nil : $0.head }
        base = detail.flatMap { $0.base.isEmpty ? nil : $0.base }
        mergeable = detail?.mergeable ?? .unknown
        mergeState = detail?.mergeState ?? .unknown
        mergeMethods = detail?.mergeMethods ?? []
    }

    var isOwn: Bool {
        guard let author, let viewer, !author.isEmpty, !viewer.isEmpty else { return false }
        return author.caseInsensitiveCompare(viewer) == .orderedSame
    }
}

enum GitHubActionError: Error, Equatable {
    case cliMissing
    case notLoggedIn
    case missingScope
    case sso
    case branchProtection(String)
    case ownPullRequest
    case alreadyClosed
    case alreadyOpen
    case conflicts
    case methodNotAllowed
    case offline
    case rateLimited
    case failed(String)

    var message: String {
        switch self {
        case .cliMissing: return "The GitHub CLI is not installed. Install it with \(GitHubError.installCommand), then sign in."
        case .notLoggedIn: return "The GitHub CLI is not signed in. Run \(GitHubError.loginCommand) in a terminal, then try again."
        case .missingScope: return "Your GitHub sign-in may not be allowed to do this: it needs the repo scope (gh auth refresh -s repo) and write access to the repository."
        case .sso: return "An organisation requires you to authorise the GitHub CLI for SAML single sign-on before it can change this pull request."
        case .branchProtection(let detail): return "Branch protection stopped this. \(detail)"
        case .ownPullRequest: return "GitHub does not let you review your own pull request."
        case .alreadyClosed: return "The pull request is already closed or merged."
        case .alreadyOpen: return "The pull request is already open."
        case .conflicts: return "The branch has merge conflicts. Resolve them on the branch, then try again."
        case .methodNotAllowed: return "The repository does not allow that merge method. Choose another one and try again."
        case .offline: return "GitHub cannot be reached. Nothing was changed; try again when you are online."
        case .rateLimited: return "GitHub's rate limit is reached. Nothing was changed; try again in a few minutes."
        case .failed(let detail): return "GitHub returned an error: \(detail)"
        }
    }

    /// Reads what `gh` printed on stderr. Specific causes come before the general ones their wording overlaps with.
    static func classify(_ stderr: String) -> GitHubActionError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { lowered.contains($0) } }
        let firstLine = ActivityLogic.truncate(text.split(separator: "\n").first.map(String.init) ?? "unknown error", to: 160)
        if has("rate limit", "abuse detection") { return .rateLimited }
        if has("saml", "single sign-on") { return .sso }
        if has("can not approve your own", "cannot approve your own", "can not request changes on your own",
               "cannot request changes on your own") { return .ownPullRequest }
        if has("already closed", "already merged", "closed pull request", "merged pull request", "pull request is closed",
               "pull request is merged", "can't be reopened", "cannot be reopened") { return .alreadyClosed }
        if has("already open") { return .alreadyOpen }
        if has("merge conflict", "has conflicts", "cleanly created") { return .conflicts }
        if has("merge commits are not allowed", "squash merges are not allowed", "rebase merges are not allowed", "merge method") { return .methodNotAllowed }
        if has("protected branch", "branch protection", "base branch policy", "required status check", "review is required",
               "approving review", "cannot delete branch", "can not delete branch", "merge queue", "not mergeable") { return .branchProtection(firstLine) }
        if has("not logged in", "gh auth login", "bad credentials", "http 401", "requires authentication", "no oauth token") { return .notLoggedIn }
        if has("scope", "resource not accessible", "http 403", "forbidden", "insufficient", "must have push access", "permission") { return .missingScope }
        if has("error connecting", "no such host", "could not resolve", "network is unreachable", "timeout", "timed out",
               "connection refused", "internet connection appears to be offline") { return .offline }
        return .failed(firstLine)
    }

    /// Whether the rest of a batch is pointless once this happened, because it would fail the same way.
    var stopsABatch: Bool {
        switch self {
        case .cliMissing, .notLoggedIn, .missingScope, .rateLimited, .offline: return true
        default: return false
        }
    }
}

/// Everything the confirmation sheet shows, and what it allows. Pure, so it is tested.
struct GitHubActionConfirmation: Equatable {
    enum Tone { case normal, good, warning, bad }

    struct Fact: Equatable {
        let label: String
        let value: String
        var tone = Tone.normal
    }

    let title: String
    let confirmTitle: String
    let reference: String
    let prTitle: String
    struct Warning: Equatable {
        let text: String
        var tone = Tone.warning
    }

    var facts: [Fact] = []
    var warnings: [Warning] = []
    var blocker: String?
    let command: String
    let comment: String
    let commentRequired: Bool
    let needsComment: Bool
    let offersBranchDelete: Bool
    let mergeMethods: [GitHubMergeMethod]
    let commentLabel: String
    /// Return confirms a close; for an approval or a merge the person has to click, and Return cancels.
    let confirmIsDefault: Bool

    var canConfirm: Bool { blocker == nil && !needsComment }
}

enum GitHubActions {
    static let enabledKey = "githubActionsEnabled"
    static let explainedKey = "githubActionsExplained"
    static let disabledHelp = "Turn on \u{201C}Allow actions on GitHub\u{201D} in Settings \u{2192} GitHub first."
    static let settingNote = "Runs gh on your behalf. Every action, merging included, asks you to confirm first."
    static let explanation = "The app can now approve, merge and close pull requests, and comment on them, by running the GitHub CLI (gh) with your own "
        + "sign-in. It never does so by itself, and nothing else in the app can: not Claude, not the terminal here, not the chat, not the "
        + "iPhone. Each action opens a sheet that shows the exact command and waits for your click. Every action is written to a local "
        + "log in Settings \u{2192} GitHub. Approvals cannot be undone from here, and a merge cannot be undone at all: GitHub only lets you revert it "
        + "with a new pull request. Merges never skip branch protection and never wait for automatic merging."
    static let reopenWindow: TimeInterval = 30
    static let undoWindow: TimeInterval = 86_400
    static let overlayLifetime: TimeInterval = 120
    static let recentLimit = 50
    static let pauseBetweenBatchItems: TimeInterval = 1

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }
    static func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) { defaults.set(on, forKey: enabledKey) }
    static func isExplained(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: explainedKey) }
    static func setExplained(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: explainedKey) }

    /// The row menu offers actions only while they are allowed; the page shows them disabled, with `disabledHelp`.
    static func listShowsActions(enabled: Bool) -> Bool { enabled }

    // MARK: Command line

    /// Arguments for `gh`, one entry per word; text the person wrote is a single entry and never part of a shell string.
    static func arguments(_ request: GitHubActionRequest) -> [String] {
        let comment = request.trimmedComment
        let base = ["--repo", request.repo]
        switch request.action {
        case .approve:
            return ["pr", "review", String(request.number)] + base + ["--approve"] + (comment.isEmpty ? [] : ["--body", comment])
        case .requestChanges:
            return ["pr", "review", String(request.number)] + base + ["--request-changes", "--body", comment]
        case .comment:
            return ["pr", "review", String(request.number)] + base + ["--comment", "--body", comment]
        case .merge:
            return ["pr", "merge", String(request.number)] + base + [request.method.flag] + (request.deleteBranch ? ["--delete-branch"] : [])
                + (comment.isEmpty ? [] : ["--body", comment])
        case .close:
            return ["pr", "close", String(request.number)] + base + (comment.isEmpty ? [] : ["--comment", comment])
                + (request.deleteBranch ? ["--delete-branch"] : [])
        case .reopen:
            return ["pr", "reopen", String(request.number)] + base + (comment.isEmpty ? [] : ["--comment", comment])
        }
    }

    /// The same command as a line to read and paste into a terminal.
    static func commandLine(_ request: GitHubActionRequest) -> String {
        (["gh"] + arguments(request).map(GitHubLogic.shellWord)).joined(separator: " ")
    }

    // MARK: Checks before asking

    enum Preflight: Equatable {
        case blocked(String)
        case allowed(warnings: [String])
    }

    static func preflight(_ request: GitHubActionRequest, _ target: GitHubActionTarget) -> Preflight {
        var warnings: [String] = []
        switch request.action {
        case .approve, .requestChanges:
            if target.isOwn { return .blocked("You are the author of this pull request. GitHub does not let you \(request.action == .approve ? "approve" : "request changes on") your own pull request.") }
            if target.state != .open { return .blocked("This pull request is \(target.state.rawValue). Only open pull requests can be reviewed this way.") }
            if target.viewer?.isEmpty ?? true { warnings.append("Could not tell who you are signed in as; GitHub refuses reviews of your own pull request.") }
        case .comment:
            break
        case .merge:
            if target.state != .open { return .blocked("This pull request is already \(target.state.rawValue).") }
            if target.isDraft { return .blocked("A draft pull request cannot be merged. Mark it ready for review first.") }
            if target.mergeable == .conflicting { return .blocked("This pull request has merge conflicts. Resolve them on the branch first.") }
            if target.mergeable == .unknown { return .blocked("GitHub has not said yet whether this pull request can merge. Check again in a moment.") }
            if target.mergeMethods.isEmpty { return .blocked("Could not tell which merge methods this repository allows.") }
            if !target.mergeMethods.contains(request.method) { return .blocked("This repository does not allow \(request.method.title.lowercased()) merges.") }
            if target.mergeState == .blocked { warnings.append("Required reviews or checks are not satisfied yet, so GitHub may refuse the merge.") }
            if target.mergeState == .unstable { warnings.append("Some checks are not passing.") }
            warnings += checkWarnings(target)
        case .close:
            if target.state != .open { return .blocked("This pull request is already \(target.state.rawValue).") }
        case .reopen:
            if target.state == .merged { return .blocked("A merged pull request cannot be reopened.") }
            if target.state == .open { return .blocked("This pull request is already open.") }
        }
        if target.isDraft, request.action.isReview { warnings.append("This pull request is a draft.") }
        if request.action == .approve {
            warnings += checkWarnings(target)
            if target.review == .changesRequested { warnings.append("Changes were requested in an earlier review") }
        }
        return .allowed(warnings: warnings)
    }

    static let checksFailing = "Checks are failing"

    private static func checkWarnings(_ target: GitHubActionTarget) -> [String] {
        var warnings: [String] = []
        if target.checks == .failed { warnings.append(checksFailing) }
        if target.checks == .running { warnings.append("Checks are still running") }
        return warnings
    }

    /// Whether `--delete-branch` is worth offering: not for the branches a repository keeps. An unknown head is offered; GitHub refuses
    /// what it must.
    static func branchDeletable(head: String?, base: String?) -> Bool {
        guard let head, !head.isEmpty else { return true }
        let kept = ["main", "master", "develop", "development", "trunk", "staging", "production"]
        return head != base && !kept.contains(head.lowercased()) && !head.lowercased().hasPrefix("release")
    }

    static func confirmation(for request: GitHubActionRequest, target: GitHubActionTarget) -> GitHubActionConfirmation {
        let merging = request.action == .merge
        var facts = [GitHubActionConfirmation.Fact(label: "Pull request", value: request.reference),
                     GitHubActionConfirmation.Fact(label: "Title", value: request.title)]
        let author = target.author ?? "unknown"
        facts.append(.init(label: "Author", value: target.isOwn ? "\(author) (you)" : author, tone: target.isOwn ? .bad : .normal))
        let state = target.isDraft && target.state == .open ? "Open \u{00B7} draft" : target.state.rawValue.capitalized
        facts.append(.init(label: "State", value: state, tone: target.state == .open ? .normal : .bad))
        if merging {
            facts.append(.init(label: "Base", value: target.base ?? "unknown"))
            facts.append(.init(label: "Conflicts", value: GitHubLogic.mergeText(target.mergeable) ?? "Not known yet",
                               tone: target.mergeable == .conflicting ? .bad : target.mergeable == .mergeable ? .good : .normal))
        }
        if request.action.isReview || merging {
            facts.append(.init(label: "Checks", value: checksText(target.checks), tone: tone(target.checks)))
            let wantsApproval = target.review == .changesRequested || (merging && target.review == .required)
            facts.append(.init(label: "Review", value: target.review.map(GitHubLogic.reviewText) ?? "No decision yet",
                               tone: wantsApproval ? .warning : target.review == .approved ? .good : .normal))
        }
        var confirmation = GitHubActionConfirmation(
            title: request.action.confirmTitle, confirmTitle: request.action.confirmTitle, reference: request.reference, prTitle: request.title,
            facts: facts, command: commandLine(request), comment: request.trimmedComment, commentRequired: request.action.commentRequired,
            needsComment: request.action.commentRequired && request.trimmedComment.isEmpty,
            offersBranchDelete: (request.action == .close || merging) && target.state == .open && branchDeletable(head: target.head, base: target.base),
            mergeMethods: target.mergeMethods, commentLabel: merging ? "Commit body (optional)" : request.action.commentRequired ? "Comment (required)" : "Comment (optional)",
            confirmIsDefault: request.action.returnConfirms)
        switch preflight(request, target) {
        case .blocked(let reason): confirmation.blocker = reason
        case .allowed(let warnings):
            confirmation.warnings = warnings.map { .init(text: $0, tone: $0 == checksFailing ? .bad : .warning) }
        }
        return confirmation
    }

    static func checksText(_ checks: GitHubPR.Checks) -> String {
        switch checks {
        case .passed: return "Passing"
        case .failed: return "Failing"
        case .running: return "Running"
        case .none: return "None"
        }
    }

    private static func tone(_ checks: GitHubPR.Checks) -> GitHubActionConfirmation.Tone {
        switch checks {
        case .passed: return .good
        case .failed: return .bad
        case .running: return .warning
        case .none: return .normal
        }
    }

    // MARK: Result text

    static func successText(_ request: GitHubActionRequest) -> String {
        let base = "\(request.action.pastTense) \(request.shortReference)"
        switch request.action {
        case .approve, .requestChanges: return base + " \u{00B7} Undo isn't possible \u{2014} it can be dismissed on GitHub"
        case .comment: return base + " \u{00B7} The comment can be deleted on GitHub"
        case .merge: return "Merged \(request.shortReference) \u{00B7} GitHub can't undo a merge; you can revert it with a new PR"
        case .close, .reopen: return base
        }
    }

    static func failureText(_ request: GitHubActionRequest, _ error: GitHubActionError) -> String {
        "Could not \(request.action.title.lowercased()) \(request.shortReference). \(error.message)"
    }

    // MARK: Optimistic state

    struct Patch: Equatable {
        var state: GitHubPR.State?
        var review: GitHubPR.Review?
        var expires: Date
    }

    static func patch(for action: GitHubAction, now: Date) -> Patch? {
        let expires = now.addingTimeInterval(overlayLifetime)
        switch action {
        case .approve: return Patch(review: .approved, expires: expires)
        case .requestChanges: return Patch(review: .changesRequested, expires: expires)
        case .merge: return Patch(state: .merged, expires: expires)
        case .close: return Patch(state: .closed, expires: expires)
        case .reopen: return Patch(state: .open, expires: expires)
        case .comment: return nil
        }
    }

    static func apply(_ patch: Patch, to pr: GitHubPR) -> GitHubPR {
        var pr = pr
        if let state = patch.state { pr.state = state }
        if let review = patch.review { pr.review = review }
        return pr
    }

    /// The state changes still waiting for GitHub's search to catch up, laid over a fresh fetch; only the state, since a review
    /// decision depends on what the repository requires.
    static func overlay(_ prs: [GitHubKind: [GitHubPR]], _ patches: [String: Patch], now: Date) -> [GitHubKind: [GitHubPR]] {
        let live = patches.filter { $0.value.expires > now && $0.value.state != nil }
        guard !live.isEmpty else { return prs }
        return prs.mapValues { rows in
            rows.map { pr in live[pr.url].map { apply(Patch(state: $0.state, expires: $0.expires), to: pr) } ?? pr }
        }
    }

    // MARK: Marking several rows

    /// A command-click: adds or removes the row, starting from the selected one when nothing is marked yet.
    static func toggled(_ url: String, in marked: Set<String>, selected: String?) -> Set<String> {
        var marked = marked.isEmpty ? Set([selected].compactMap { $0 }) : marked
        if marked.contains(url) { marked.remove(url) } else { marked.insert(url) }
        return marked
    }

    /// A shift-click: every row between the selected one and the clicked one, added to what is marked.
    static func marked(through url: String, from anchor: String?, in prs: [GitHubPR], adding marked: Set<String>) -> Set<String> {
        guard let to = prs.firstIndex(where: { $0.url == url }) else { return marked }
        let from = prs.firstIndex { $0.url == anchor } ?? to
        return marked.union(prs[min(from, to)...max(from, to)].map(\.url))
    }

    static func pruned(_ marked: Set<String>, in prs: [GitHubPR]) -> Set<String> {
        let listed = Set(prs.map(\.url))
        return marked.intersection(listed)
    }

    /// What a row's menu acts on: all marked rows when it is one of them, otherwise only itself.
    static func targets(for pr: GitHubPR, marked: Set<String>, in prs: [GitHubPR]) -> [GitHubPR] {
        guard marked.count > 1, marked.contains(pr.url) else { return [pr] }
        return prs.filter { marked.contains($0.url) }
    }
}

// MARK: Running

enum GitHubActionRunner {
    /// Runs `gh` once. A failure is classified from stderr and never retried. `gh pr close` and `reopen` answer a pull request
    /// that is already in the wanted state with a warning and exit 0; that is reported as the failure it is.
    nonisolated static func perform(_ request: GitHubActionRequest, cli: URL?) -> Result<String, GitHubActionError> {
        guard let cli else { return .failure(.cliMissing) }
        guard let output = GitHubClient.run(cli, GitHubActions.arguments(request), directory: FileManager.default.temporaryDirectory) else {
            return .failure(.cliMissing)
        }
        if output.status != 0 { return .failure(GitHubActionError.classify(output.stderr)) }
        let lowered = output.stderr.lowercased()
        if request.action == .close, lowered.contains("already closed") || lowered.contains("already merged") { return .failure(.alreadyClosed) }
        if request.action == .reopen, lowered.contains("already open") { return .failure(.alreadyOpen) }
        return .success(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The login `gh` is signed in as, for the check against reviewing your own pull request. Reads only.
    nonisolated static func viewer(cli: URL?) -> String? {
        guard let cli, let output = GitHubClient.run(cli, ["api", "user", "--jq", ".login"]), output.status == 0 else { return nil }
        let login = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }
}

// MARK: Several at once

enum GitHubBulk {
    enum Outcome: Equatable {
        case done
        case failed(GitHubActionError)
        case skipped(String)
    }

    /// One at a time, in order, with a pause between them so GitHub's limit on writes is not hit. A failure of one is kept and the
    /// next goes on, unless it would fail the same way (signed out, rate limited, offline); then the rest is skipped. Never retried.
    static func run(_ requests: [GitHubActionRequest], stop: () -> Bool = { false }, pause: () -> Void = {},
                    perform: (GitHubActionRequest) -> Result<String, GitHubActionError>,
                    report: (Int, Outcome) -> Void = { _, _ in }) -> [Outcome] {
        var outcomes: [Outcome] = []
        var halted: String?
        for (index, request) in requests.enumerated() {
            let outcome: Outcome
            if let halted {
                outcome = .skipped(halted)
            } else if stop() {
                outcome = .skipped("Stopped")
            } else {
                if index > 0 { pause() }
                switch perform(request) {
                case .success: outcome = .done
                case .failure(let error):
                    outcome = .failed(error)
                    if error.stopsABatch { halted = "Not tried after the error above" }
                }
            }
            outcomes.append(outcome)
            report(index, outcome)
        }
        return outcomes
    }

    static func summary(_ action: GitHubAction, _ outcomes: [Outcome]) -> String {
        let done = outcomes.filter { $0 == .done }.count
        let failed = outcomes.filter { if case .failed = $0 { return true } else { return false } }.count
        let skipped = outcomes.count - done - failed
        var text = "\(action.pastTense) \(done) of \(outcomes.count) pull request\(outcomes.count == 1 ? "" : "s")"
        if failed > 0 { text += " \u{00B7} \(failed) failed" }
        if skipped > 0 { text += " \u{00B7} \(skipped) not tried" }
        return text
    }
}

// MARK: Audit

struct GitHubActionRecord: Equatable, Identifiable {
    var id: Int64 = 0
    let at: Date
    let action: GitHubAction
    let repo: String
    let number: Int
    let title: String
    let command: String
    let succeeded: Bool
    var error: String?

    init(id: Int64 = 0, at: Date, request: GitHubActionRequest, succeeded: Bool, error: String? = nil) {
        self.id = id
        self.at = at
        action = request.action
        repo = request.repo
        number = request.number
        title = request.title
        command = GitHubActions.commandLine(request)
        self.succeeded = succeeded
        self.error = error
    }

    init(id: Int64, at: Date, action: GitHubAction, repo: String, number: Int, title: String, command: String, succeeded: Bool, error: String?) {
        self.id = id
        self.at = at
        self.action = action
        self.repo = repo
        self.number = number
        self.title = title
        self.command = command
        self.succeeded = succeeded
        self.error = error
    }

    var reference: String { "\(GitHubLogic.repoName(repo).name) #\(number)" }

    /// The closes that can still be taken back: successful, recent, and not reopened since.
    static func reopenable(_ records: [GitHubActionRecord], now: Date) -> Set<Int64> {
        Set(records.filter { record in
            record.action == .close && record.succeeded && now.timeIntervalSince(record.at) < GitHubActions.undoWindow
                && !records.contains { $0.action == .reopen && $0.succeeded && $0.repo == record.repo && $0.number == record.number && $0.at > record.at }
        }.map(\.id))
    }
}
