import Foundation

extension GitHubModel {
    /// Selects the pull request a link names: from the cached list when it is there, otherwise with a minimal page
    /// that fills in once the detail is read. Only selects and reads.
    func open(_ link: GitHubLink.Target) {
        let listed = prs.values.flatMap { $0 }.first { $0.url == link.url }
        let pr = listed ?? GitHubPR(url: link.url, number: link.number, title: "", repo: link.repo, updated: .distantPast)
        select(pr)
        linkedURL = pr.url
    }
}
