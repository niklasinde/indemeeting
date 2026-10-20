import SwiftUI

/// The comments of one open pull request page: the cached ones at once, then a fetch of the first page, and further pages on request.
@MainActor
final class GitHubCommentsModel: ObservableObject {
    let pr: GitHubPR
    @Published private(set) var comments: GitHubComments?
    @Published private(set) var error: GitHubError?
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published var filter = GitHubCommentsFilter()
    /// Resolved threads opened, and long bot comments shown whole.
    @Published var expanded = Set<String>()
    private let store: MeetingStore?
    private var cache: Data?
    private var task: Task<Void, Never>?
    private var scopeChosen = false

    init(pr: GitHubPR, store: MeetingStore?) {
        self.pr = pr
        self.store = store
        if let cached = (try? store?.githubComments(pr.url)) ?? nil {
            comments = cached.comments
            cache = cached.json
            chooseDefaultScope()
        }
    }

    var cutoff: Date? { GitHubLogic.feedbackCutoff(pr) }
    var me: String { comments?.me ?? "" }
    var threads: [GitHubThread] { comments.map { GitHubLogic.visibleThreads($0, filter, after: cutoff) } ?? [] }
    var conversation: [GitHubComment] { comments.map { GitHubLogic.visibleConversation($0, filter, after: cutoff) } ?? [] }

    var newCount: Int {
        guard let comments else { return 0 }
        return GitHubLogic.visibleThreads(comments, GitHubCommentsFilter(scope: .new), after: cutoff).count
            + GitHubLogic.visibleConversation(comments, GitHubCommentsFilter(scope: .new), after: cutoff).count
    }

    func choose(_ scope: GitHubCommentsFilter.Scope) {
        scopeChosen = true
        filter.scope = scope
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func start() {
        guard !loading else { return }
        task = Task { [weak self] in await self?.refresh() }
    }

    func stop() {
        task?.cancel()
        task = nil
        loading = false
        loadingMore = false
    }

    /// Fetches the first page again, and as many more as had been loaded, so the list keeps its length.
    private func refresh() async {
        loading = true
        defer { loading = false }
        let keep = comments?.threads.count ?? 0
        var merged: GitHubComments?
        var json: Data?
        while true {
            switch await fetch(after: merged?.cursors) {
            case .success(let fetched):
                merged = merged?.appending(fetched.page) ?? fetched.page
                json = GitHubLogic.commentsCache(json, adding: fetched.json)
            case .failure(let failure):
                if !Task.isCancelled { error = failure }
                return
            }
            guard let current = merged, current.hasMore, current.threads.count < keep else { break }
        }
        guard let merged, let json else { return }
        comments = merged
        cache = json
        error = nil
        save(merged, json)
        chooseDefaultScope()
    }

    func loadMore() {
        guard let current = comments, current.hasMore, !loadingMore else { return }
        loadingMore = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { loadingMore = false }
            switch await fetch(after: current.cursors) {
            case .success(let fetched):
                let merged = current.appending(fetched.page)
                let json = GitHubLogic.commentsCache(cache, adding: fetched.json)
                comments = merged
                cache = json
                error = nil
                save(merged, json)
            case .failure(let failure):
                if !Task.isCancelled { error = failure }
            }
        }
    }

    private func fetch(after cursors: GitHubComments.Cursors?) async -> Result<(page: GitHubComments, json: Data), GitHubError> {
        let cli = GitHubLogic.findCLI(), repo = pr.repo, number = pr.number
        return await Task.detached { GitHubClient.fetchComments(cli: cli, repo: repo, number: number, after: cursors) }.value
    }

    private func save(_ comments: GitHubComments, _ json: Data) {
        try? store?.saveGitHubComments(pr.url, json: json, headSHA: comments.headOid)
    }

    private func chooseDefaultScope() {
        guard !scopeChosen, let comments else { return }
        scopeChosen = true
        filter.scope = GitHubLogic.defaultScope(comments)
    }

    /// Shows the threads of a preset, as the list's chips ask for.
    func show(_ scope: GitHubCommentsFilter.Scope) {
        scopeChosen = true
        filter = GitHubCommentsFilter(scope: scope)
    }

    #if DEBUG
    init(pr: GitHubPR, sample: GitHubComments?, filter: GitHubCommentsFilter = GitHubCommentsFilter(), expanded: Set<String> = []) {
        self.pr = pr
        store = nil
        comments = sample
        self.filter = filter
        self.expanded = expanded
        scopeChosen = true
    }
    #endif
}
