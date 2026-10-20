import AppKit
import SwiftUI

/// What a confirmation sheet edits and shows: the request as it will run, and the state it will run against, fetched again when
/// the sheet opens so a pull request that was merged meanwhile is caught before the click.
@MainActor
final class GitHubActionDraft: ObservableObject, Identifiable {
    let id = UUID()
    let pr: GitHubPR
    @Published var request: GitHubActionRequest
    @Published private(set) var target: GitHubActionTarget
    @Published private(set) var checking = true
    @Published private(set) var note: String?
    @Published fileprivate(set) var running = false

    init(_ action: GitHubAction, pr: GitHubPR, detail: GitHubPRDetail?) {
        self.pr = pr
        request = GitHubActionRequest(action, pr: pr)
        target = GitHubActionTarget(pr: pr, detail: detail)
        adoptMergeMethod()
    }

    var confirmation: GitHubActionConfirmation { GitHubActions.confirmation(for: request, target: target) }

    private func adoptMergeMethod() {
        request.method = GitHubMergeMethod.choose(request.method, from: target.mergeMethods)
    }

    func refresh() async {
        let cli = GitHubLogic.findCLI(), repo = pr.repo, number = pr.number, needsViewer = target.viewer == nil
        let (result, viewer) = await Task.detached {
            (GitHubClient.fetchDetail(cli: cli, repo: repo, number: number), needsViewer ? GitHubActionRunner.viewer(cli: cli) : nil)
        }.value
        switch result {
        case .success(let fetched):
            target = GitHubActionTarget(pr: pr, detail: fetched.detail, viewer: viewer ?? target.viewer)
            adoptMergeMethod()
        case .failure(let error):
            note = "Could not check the current state (\(error.message)). The last fetched state is shown."
        }
        checking = false
    }

    #if DEBUG
    init(request: GitHubActionRequest, pr: GitHubPR, target: GitHubActionTarget, checking: Bool = false, running: Bool = false) {
        self.pr = pr
        self.request = request
        self.target = target
        self.checking = checking
        self.running = running
        adoptMergeMethod()
    }
    #endif
}

/// Closing or reopening several pull requests: the list, the text for all of them, and the result of each as the run goes.
@MainActor
final class GitHubBulkDraft: ObservableObject, Identifiable {
    struct Item: Identifiable {
        let pr: GitHubPR
        var outcome: GitHubBulk.Outcome?
        var id: String { pr.url }
    }

    let id = UUID()
    let action: GitHubAction
    let offersBranchDelete: Bool
    @Published var comment = ""
    @Published var deleteBranch = false
    @Published private(set) var items: [Item]
    @Published fileprivate(set) var running = false
    @Published fileprivate(set) var finished = false
    let stop = StopFlag()

    init(_ action: GitHubAction, prs: [GitHubPR], offersBranchDelete: Bool) {
        self.action = action
        self.offersBranchDelete = offersBranchDelete
        items = prs.map { pr in
            Item(pr: pr, outcome: GitHubBulkDraft.eligible(action, pr) ? nil : .skipped("Already \(pr.state.rawValue)"))
        }
    }

    private static func eligible(_ action: GitHubAction, _ pr: GitHubPR) -> Bool {
        action == .reopen ? pr.state == .closed : pr.state == .open
    }

    var requests: [GitHubActionRequest] {
        items.filter { $0.outcome == nil }.map {
            GitHubActionRequest(action, pr: $0.pr).with(comment: comment, deleteBranch: action == .close && deleteBranch)
        }
    }

    var done: Int { items.filter { $0.outcome != nil }.count }
    var summary: String? { finished ? GitHubBulk.summary(action, items.compactMap(\.outcome)) : nil }

    fileprivate func set(_ outcome: GitHubBulk.Outcome, for url: String) {
        if let index = items.firstIndex(where: { $0.pr.url == url }) { items[index].outcome = outcome }
    }

    #if DEBUG
    func showSample(outcomes: [GitHubBulk.Outcome?], running: Bool, finished: Bool) {
        for (index, outcome) in outcomes.enumerated() where items.indices.contains(index) { items[index].outcome = outcome }
        self.running = running
        self.finished = finished
    }
    #endif
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// The one place that writes to GitHub, and only for a click on a button in a sheet or a banner. Off until turned on in Settings.
/// Nothing else holds a reference to it: not the chat, the MCP server, the phone API, the terminal or Claude (a test reads the sources).
@MainActor
final class GitHubActionsModel: ObservableObject {
    static let shared = GitHubActionsModel()

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var isError = false
        var reopen: [GitHubActionRequest] = []
        var details: String?
    }

    indirect enum Sheet: Identifiable {
        case explain(next: Sheet)
        case single(GitHubActionDraft)
        case bulk(GitHubBulkDraft)

        var id: UUID {
            switch self {
            case .explain(let next): return next.id
            case .single(let draft): return draft.id
            case .bulk(let draft): return draft.id
            }
        }
    }

    @Published private(set) var enabled = GitHubActions.isEnabled()
    @Published var sheet: Sheet?
    @Published private(set) var banner: Banner?
    @Published private(set) var records: [GitHubActionRecord] = []

    private var store: MeetingStore? { GitHubModel.shared.store }

    func setEnabled(_ on: Bool) {
        GitHubActions.setEnabled(on)
        enabled = on
        if !on { sheet = nil }
    }

    // MARK: Opening a sheet

    func begin(_ action: GitHubAction, _ pr: GitHubPR, detail: GitHubPRDetail? = nil) {
        guard enabled else { return }
        let draft = GitHubActionDraft(action, pr: pr, detail: detail)
        present(.single(draft))
        Task { await draft.refresh() }
    }

    func beginBulk(_ action: GitHubAction, _ prs: [GitHubPR]) {
        guard enabled, !prs.isEmpty else { return }
        let deletable = prs.allSatisfy { GitHubActions.branchDeletable(head: store?.githubHeadBranch($0.url), base: nil) }
        present(.bulk(GitHubBulkDraft(action, prs: prs, offersBranchDelete: action == .close && deletable)))
    }

    private func present(_ sheet: Sheet) {
        self.sheet = GitHubActions.isExplained() ? sheet : .explain(next: sheet)
    }

    func continueAfterExplanation() {
        guard case .explain(let next) = sheet else { return }
        GitHubActions.setExplained()
        sheet = next
    }

    func dismissSheet() {
        if case .bulk(let draft) = sheet, draft.running { return }
        sheet = nil
    }

    func dismissBanner() { banner = nil }

    // MARK: Running

    func confirm(_ draft: GitHubActionDraft) {
        guard enabled, !draft.running, !draft.checking, draft.confirmation.canConfirm else { return }
        draft.running = true
        let request = draft.request
        Task {
            let outcomes = await execute([request], stop: StopFlag()) { _, _ in }
            sheet = nil
            show(outcomes[0], for: request)
            afterActions()
        }
    }

    func confirm(_ draft: GitHubBulkDraft) {
        guard enabled, !draft.running, !draft.finished else { return }
        let requests = draft.requests
        guard !requests.isEmpty else { return draft.finished = true }
        draft.running = true
        Task {
            var undone: [GitHubActionRequest] = []
            _ = await execute(requests, stop: draft.stop) { index, outcome in
                draft.set(outcome, for: requests[index].url)
                if outcome == .done { undone.append(requests[index]) }
            }
            draft.running = false
            draft.finished = true
            let failed = draft.items.contains { if case .failed = $0.outcome { return true } else { return false } }
            banner = Banner(text: draft.summary ?? "", isError: failed, reopen: draft.action == .close ? undone.map(reopening) : [])
            expireBanner()
            afterActions()
        }
    }

    /// The Reopen of a banner or of the log: undoes a close you just confirmed, so it does not ask again.
    func reopen(_ requests: [GitHubActionRequest]) {
        guard enabled, !requests.isEmpty else { return }
        banner = nil
        Task {
            let outcomes = await execute(requests, stop: StopFlag()) { _, _ in }
            banner = requests.count == 1 ? bannerFor(outcomes[0], requests[0]) : Banner(text: GitHubBulk.summary(.reopen, outcomes),
                                                                                       isError: outcomes.contains { $0 != .done })
            expireBanner()
            afterActions()
        }
    }

    func reopening(_ request: GitHubActionRequest) -> GitHubActionRequest {
        GitHubActionRequest(.reopen, repo: request.repo, number: request.number, title: request.title, url: request.url)
    }

    func reopening(_ record: GitHubActionRecord) -> GitHubActionRequest {
        GitHubActionRequest(.reopen, repo: record.repo, number: record.number, title: record.title,
                            url: "https://\(GitHubLogic.host)/\(record.repo)/pull/\(record.number)")
    }

    private func execute(_ requests: [GitHubActionRequest], stop: StopFlag,
                         report: @escaping @MainActor (Int, GitHubBulk.Outcome) -> Void) async -> [GitHubBulk.Outcome] {
        let cli = GitHubLogic.findCLI()
        return await Task.detached { [weak self] in
            GitHubBulk.run(requests, stop: { stop.isSet }, pause: { Thread.sleep(forTimeInterval: GitHubActions.pauseBetweenBatchItems) },
                           perform: { request in
                let result = GitHubActionRunner.perform(request, cli: cli)
                DispatchQueue.main.sync { MainActor.assumeIsolated { self?.settle(request, result) } }
                return result
            }, report: { index, outcome in
                DispatchQueue.main.async { MainActor.assumeIsolated { report(index, outcome) } }
            })
        }.value
    }

    /// Writes the audit row and, when it worked, lets the lists show the new state before GitHub's search does.
    private func settle(_ request: GitHubActionRequest, _ result: Result<String, GitHubActionError>) {
        var error: String?
        if case .failure(let failure) = result { error = failure.message }
        let record = GitHubActionRecord(at: Date(), request: request, succeeded: error == nil, error: error)
        _ = try? store?.saveGitHubAction(record)
        loadRecords()
        if case .success = result { GitHubModel.shared.applied(request) }
    }

    private func show(_ outcome: GitHubBulk.Outcome, for request: GitHubActionRequest) {
        banner = bannerFor(outcome, request)
        expireBanner()
    }

    private func bannerFor(_ outcome: GitHubBulk.Outcome, _ request: GitHubActionRequest) -> Banner {
        switch outcome {
        case .done:
            return Banner(text: GitHubActions.successText(request), reopen: request.action == .close ? [reopening(request)] : [])
        case .failed(let error):
            return Banner(text: GitHubActions.failureText(request, error), isError: true, details: GitHubActions.commandLine(request))
        case .skipped(let reason):
            return Banner(text: "\(request.action.title) of \(request.shortReference) was not tried. \(reason)", isError: true)
        }
    }

    /// A success fades after the time to change your mind; an error stays until dismissed.
    private func expireBanner() {
        guard let current = banner, !current.isError else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(GitHubActions.reopenWindow * 1_000_000_000))
            if banner?.id == current.id { banner = nil }
        }
    }

    private func afterActions() {
        GitHubModel.shared.refreshAfterAction()
    }

    // MARK: Log

    func loadRecords() {
        records = (try? store?.githubActions()) ?? []
    }

    func clearRecords() {
        try? store?.clearGitHubActions()
        loadRecords()
    }

    var reopenable: Set<Int64> { GitHubActionRecord.reopenable(records, now: Date()) }

    #if DEBUG
    func showSample(enabled: Bool = true, records: [GitHubActionRecord] = [], banner: Banner? = nil) {
        self.enabled = enabled
        self.records = records
        self.banner = banner
    }
    #endif
}
