import AppKit
import SwiftUI

/// The cached pull requests, the filters of the view and the periodic fetch through the `gh` CLI. Off until turned on.
@MainActor
final class GitHubModel: ObservableObject {
    static let shared = GitHubModel()
    static let enabledKey = "githubEnabled"
    static let intervalKey = "githubRefreshMinutes"
    static let selectionKey = "githubSelectedPR"
    static let intervals = [1, 5, 10, 15, 30, 60]

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var prs: [GitHubKind: [GitHubPR]] = [:]
    @Published private(set) var directory = TicketDirectory()
    @Published private(set) var error: GitHubError?
    @Published private(set) var refreshing = false
    @Published private(set) var fetched: Date?
    @Published private(set) var cachedCount = 0
    @Published var kind = GitHubKind.created
    @Published var filter = GitHubLogic.Filter()
    @Published private(set) var page: GitHubDetailModel?
    @Published private(set) var selectedURL = UserDefaults.standard.string(forKey: selectionKey)

    var store: MeetingStore?
    private var loop: Task<Void, Never>?
    private let settle = Debouncer()
    private var prefetching = Set<String>()

    var interval: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.intervalKey)
        return Self.intervals.contains(stored) ? stored : 5
    }

    var visible: [GitHubPR] { GitHubLogic.filter(prs[kind] ?? [], filter) }
    var repos: [String] { GitHubLogic.repos(in: prs[kind] ?? []) }
    var isCapped: Bool { GitHubLogic.isCapped(prs[kind] ?? [], state: filter.state) }
    var showsList: Bool { enabled && (error == nil || hasData) }
    var hasData: Bool { prs.values.contains { !$0.isEmpty } }
    var menuSummary: String? { enabled && fetched != nil ? GitHubLogic.menuSummary(prs) : nil }

    func start() {
        loadCache()
        guard enabled else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(self.interval) * 60 * 1_000_000_000)
            }
        }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        enabled = on
        loop?.cancel()
        loop = nil
        if on { start() } else { error = nil }
    }

    func setInterval(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: Self.intervalKey)
        if enabled { start() }
    }

    func refresh() async {
        guard enabled, !refreshing else { return }
        refreshing = true
        let cli = GitHubLogic.findCLI()
        let fetch = await Task.detached { GitHubClient.fetchAll(cli: cli) }.value
        guard enabled else { return refreshing = false }
        error = fetch.error
        if !fetch.prs.isEmpty {
            prs.merge(fetch.prs) { $1 }
            fetched = Date()
            try? store?.saveGitHubPRs(fetch.prs)
        }
        refreshing = false
    }

    func loadCache() {
        prs = (try? store?.githubPRs()) ?? [:]
        fetched = (try? store?.githubFetched()) ?? nil
        directory = (try? store?.ticketDirectory()) ?? TicketDirectory()
        cachedCount = Set(prs.values.flatMap { $0.map(\.url) }).count
    }

    func clearCache() {
        _ = try? store?.clearGitHubCache()
        loadCache()
    }

    /// Shows the pull request on the right at once, from the cache. The fetch waits until the selection has settled, so holding
    /// an arrow key does not fire a query per row.
    func select(_ pr: GitHubPR?) {
        guard pr?.url != selectedURL || (pr != nil && page == nil) else { return }
        page?.stop()
        settle.cancel()
        selectedURL = pr?.url
        UserDefaults.standard.set(pr?.url, forKey: Self.selectionKey)
        page = pr.map { GitHubDetailModel(pr: $0, store: store) }
        guard page != nil else { return }
        settle.schedule(after: GitHubSelection.settleDelay) { [weak self] in
            MainActor.assumeIsolated { self?.settled() }
        }
    }

    func step(_ direction: GitHubSelection.Direction) {
        select(GitHubSelection.step(direction, from: selectedURL, in: visible))
    }

    /// Keeps the selection through a change of tab, filter, sort or refresh while its pull request is listed; otherwise clears it.
    func reconcile() {
        guard hasData else { return }
        guard let url = GitHubSelection.preserved(selectedURL, in: visible) else { return select(nil) }
        if page == nil { select(visible.first { $0.url == url }) }
    }

    private func settled() {
        page?.start()
        prefetchNeighbours()
    }

    private func prefetchNeighbours() {
        let fetched = (try? store?.githubDetailFetched()) ?? [:]
        let slots = GitHubSelection.prefetchSlots - prefetching.count
        let targets = GitHubSelection.prefetchTargets(selected: selectedURL, in: visible, fetched: fetched, now: Date(),
                                                      excluding: prefetching, slots: slots)
        let cli = GitHubLogic.findCLI()
        for pr in targets {
            prefetching.insert(pr.url)
            Task(priority: .utility) { [weak self] in
                let result = await Task.detached(priority: .utility) { GitHubClient.fetchDetail(cli: cli, repo: pr.repo, number: pr.number) }.value
                guard let self else { return }
                if case .success(let fetched) = result { try? self.store?.saveGitHubDetail(pr.url, json: fetched.json) }
                self.prefetching.remove(pr.url)
            }
        }
    }

    func ask(about pr: GitHubPR) {
        ChatWindow.shared.show(scope: .general)
        ChatWindow.shared.model?.draft = "What should I know about \(pr.repo) #\(pr.number), \"\(pr.title)\"? \(pr.url)"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    #if DEBUG
    /// Shows made-up state, for the previews.
    func showSample(enabled: Bool = true, prs: [GitHubKind: [GitHubPR]], directory: TicketDirectory = TicketDirectory(),
                    error: GitHubError? = nil, fetched: Date? = Date()) {
        self.enabled = enabled
        self.prs = prs
        self.directory = directory
        self.error = error
        self.fetched = fetched
        kind = .created
        filter = GitHubLogic.Filter()
        page = nil
        selectedURL = nil
    }

    func showSample(selecting pr: GitHubPR?, detail: GitHubPRDetail?) {
        page = pr.map { GitHubDetailModel(pr: $0, sample: detail) }
        selectedURL = pr?.url
    }
    #endif
}
