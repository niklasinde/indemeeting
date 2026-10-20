import SwiftUI

/// One open pull request page: the cached detail at once, then the fetch, and a refresh every 30 seconds while a check is running.
@MainActor
final class GitHubDetailModel: ObservableObject {
    static let pollSeconds: UInt64 = 30

    let pr: GitHubPR
    @Published private(set) var detail: GitHubPRDetail?
    @Published private(set) var error: GitHubError?
    @Published private(set) var loading = false
    /// Set when the list's chip or the toolbar asks for the comments; the page scrolls to them and clears it.
    @Published var scrollPending = false
    let comments: GitHubCommentsModel
    private let store: MeetingStore?
    private var poll: Task<Void, Never>?

    init(pr: GitHubPR, store: MeetingStore?) {
        self.pr = pr
        self.store = store
        comments = GitHubCommentsModel(pr: pr, store: store)
        detail = (try? store?.githubDetail(pr.url)) ?? nil
    }

    func start() {
        comments.start()
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                guard self.detail?.hasRunningChecks == true else { return }
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            }
        }
    }

    /// Scrolls to the comments, with the filter of a preset when one is given, and fetches them.
    func showComments(_ scope: GitHubCommentsFilter.Scope? = nil) {
        scope.map(comments.show)
        comments.start()
        scrollPending = true
    }

    func stop() {
        comments.stop()
        poll?.cancel()
        poll = nil
    }

    /// Shows the result of an action until the fetch that follows it.
    func apply(_ patch: GitHubActions.Patch) {
        guard var shown = detail else { return }
        patch.state.map { shown.state = $0 }
        patch.review.map { shown.review = $0 }
        detail = shown
    }

    private func refresh() async {
        loading = true
        let cli = GitHubLogic.findCLI(), repo = pr.repo, number = pr.number
        let result = await Task.detached { GitHubClient.fetchDetail(cli: cli, repo: repo, number: number) }.value
        switch result {
        case .success(let fetched):
            detail = fetched.detail
            error = nil
            try? store?.saveGitHubDetail(pr.url, json: fetched.json)
        case .failure(let failure):
            error = failure
        }
        loading = false
    }

    #if DEBUG
    init(pr: GitHubPR, sample: GitHubPRDetail?, comments: GitHubComments? = nil) {
        self.pr = pr
        store = nil
        self.comments = GitHubCommentsModel(pr: pr, sample: comments)
        detail = sample
    }
    #endif
}
