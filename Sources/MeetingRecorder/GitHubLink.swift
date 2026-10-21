import Foundation

/// The `meetingrecorder://` links to a pull request: `pr?url=<github pull request url>` and `pr/<owner>/<repo>/<number>`.
enum GitHubLink {
    static let scheme = "meetingrecorder"

    struct Target: Equatable {
        let repo: String
        let number: Int

        var url: String { "https://github.com/\(repo)/pull/\(number)" }
    }

    /// The link that opens a pull request in the app, with its address percent-encoded in the query.
    static func appLink(for pullRequestURL: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = pullRequestURL.addingPercentEncoding(withAllowedCharacters: unreserved) ?? pullRequestURL
        return "\(scheme)://pr?url=\(encoded)"
    }

    /// The pull request a link names, or nil for anything else: another scheme or host, extra parts or parameters,
    /// and any owner, repository or number that GitHub would not accept.
    static func parse(_ text: String) -> Target? {
        guard let link = URLComponents(string: text), link.scheme?.lowercased() == scheme, link.host?.lowercased() == "pr",
              link.user == nil, link.password == nil, link.port == nil, link.fragment == nil else { return nil }
        let query = link.queryItems ?? []
        if link.percentEncodedPath.isEmpty {
            guard query.count == 1, query[0].name == "url", let address = query[0].value else { return nil }
            return pullRequest(at: address)
        }
        guard query.isEmpty else { return nil }
        let parts = link.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? "" }
        guard parts.count == 3 else { return nil }
        return target(owner: parts[0], repo: parts[1], number: parts[2])
    }

    /// `--open-link <url>`: prints the pull request a link names, or fails. Reads nothing and writes nothing.
    static func printFromCommandLine(_ text: String) -> Never {
        guard let target = parse(text) else {
            FileHandle.standardError.write(Data("Not a meetingrecorder pull request link\n".utf8))
            exit(2)
        }
        print("\(target.repo) #\(target.number) \(target.url)")
        exit(0)
    }

    private static func pullRequest(at address: String) -> Target? {
        guard let page = URLComponents(string: address), page.scheme?.lowercased() == "https", page.host?.lowercased() == "github.com",
              page.user == nil, page.password == nil, page.port == nil, page.query == nil, page.fragment == nil else { return nil }
        let parts = page.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? "" }
        guard parts.count == 4, parts[2] == "pull" else { return nil }
        return target(owner: parts[0], repo: parts[1], number: parts[3])
    }

    private static func target(owner: String, repo: String, number: String) -> Target? {
        guard owner.wholeMatch(of: #/[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/#) != nil,
              repo.wholeMatch(of: #/[A-Za-z0-9._-]{1,100}/#) != nil, repo != ".", repo != "..",
              number.wholeMatch(of: #/[1-9][0-9]{0,8}/#) != nil, let value = Int(number) else { return nil }
        return Target(repo: "\(owner)/\(repo)", number: value)
    }
}
