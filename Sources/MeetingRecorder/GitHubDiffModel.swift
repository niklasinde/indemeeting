import Foundation

/// The patches of a pull request or a commit, fetched when a file is first opened, and which files are open.
@MainActor
final class GitHubDiffModel: ObservableObject {
    enum Source: Equatable {
        case pull(repo: String, number: Int, head: String?)
        case commit(repo: String, sha: String)

        /// A pull request is fetched again once its head moves; a commit never changes.
        var key: String? {
            switch self {
            case .pull(let repo, let number, let head): return head.map { "\(repo)#\(number)@\($0)" }
            case .commit(let repo, let sha): return "\(repo)@\(sha)"
            }
        }
    }

    @Published private(set) var patches: [String: GitHubFilePatch] = [:]
    /// The files in GitHub's order.
    @Published private(set) var files: [GitHubFilePatch] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var error: GitHubError?
    @Published private(set) var expanded = Set<String>()
    /// Files shown past the first rows.
    @Published var whole = Set<String>()
    private var source: Source?
    private var renders: [String: GitHubDiffRender] = [:]
    private static var cache: [String: [GitHubFilePatch]] = [:]

    init() {}

    func toggle(_ path: String, from source: Source) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path); load(source) }
    }

    func expand(_ paths: [String], from source: Source) {
        expanded.formUnion(paths)
        load(source)
    }

    func collapseAll() { expanded = [] }

    /// The rows and syntax of a file's patch, worked out on first use and kept until the files change.
    func render(_ path: String, patch: String) -> GitHubDiffRender {
        if let cached = renders[path] { return cached }
        let render = GitHubDiffLogic.render(patch, path: path)
        renders[path] = render
        return render
    }

    func load(_ next: Source) {
        guard !loading, !(loaded && source == next && error == nil) else { return }
        if let key = next.key, let cached = Self.cache[key] { return show(cached, from: next) }
        loading = true
        let cli = GitHubLogic.findCLI()
        Task {
            let result = await Task.detached { () -> Result<[GitHubFilePatch], GitHubError> in
                switch next {
                case .pull(let repo, let number, _): return GitHubClient.fetchFiles(cli: cli, repo: repo, number: number)
                case .commit(let repo, let sha): return GitHubClient.fetchCommitFiles(cli: cli, repo: repo, sha: sha)
                }
            }.value
            loading = false
            switch result {
            case .success(let files):
                next.key.map { Self.cache[$0] = files }
                show(files, from: next)
            case .failure(let failure):
                error = failure
            }
        }
    }

    private func show(_ files: [GitHubFilePatch], from next: Source) {
        self.files = files
        renders = [:]
        patches = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        source = next
        loaded = true
        error = nil
    }

    #if DEBUG
    init(sample: [GitHubFilePatch], expanded: [String]) {
        self.expanded = Set(expanded)
        show(sample, from: .commit(repo: "", sha: ""))
    }
    #endif
}
