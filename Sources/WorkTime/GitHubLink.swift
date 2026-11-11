import Foundation

/// The `worktime://` (or older `meetingrecorder://`) links to a pull request: `pr?url=<github pull request url>` and
/// `pr/<owner>/<repo>/<number>`.
enum GitHubLink {
    struct Target: Equatable {
        let repo: String
        let number: Int

        var url: String { "https://github.com/\(repo)/pull/\(number)" }
    }

    /// The link that opens a pull request in the app, with its address percent-encoded in the query.
    static func appLink(for pullRequestURL: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = pullRequestURL.addingPercentEncoding(withAllowedCharacters: unreserved) ?? pullRequestURL
        return "\(AppURL.scheme)://pr?url=\(encoded)"
    }

    /// The pull request a link names, or nil for anything else: another scheme or host, extra parts or parameters,
    /// and any owner, repository or number that GitHub would not accept.
    static func parse(_ text: String) -> Target? {
        guard let link = URLComponents(string: text), AppURL.accepts(scheme: link.scheme), link.host?.lowercased() == "pr",
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

    /// The link that opens a pull request in the Agent window.
    static func agentLink(for pullRequestURL: String) -> String {
        appLink(for: pullRequestURL).replacingOccurrences(of: "://pr?url=", with: "://agent?pr=")
    }

    /// The pull request an `agent?pr=<github pull request url>` link names, or nil for anything else.
    static func parseAgent(_ text: String) -> Target? {
        guard let link = URLComponents(string: text), AppURL.accepts(scheme: link.scheme), link.host?.lowercased() == "agent",
              link.user == nil, link.password == nil, link.port == nil, link.fragment == nil, link.percentEncodedPath.isEmpty,
              let query = link.queryItems, query.count == 1, query[0].name == "pr", let address = query[0].value else { return nil }
        return pullRequest(at: address)
    }

    /// The pull request in pasted or typed text: its GitHub page or any tab of it, `owner/repo#number`, or an app link.
    static func pasted(_ text: String) -> Target? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = parse(text) { return target }
        if let page = text.wholeMatch(of: #/(?i:(?:https?://)?(?:www\.)?github\.com)/([^/\s]+)/([^/\s]+)/pull/([0-9]+)(?:[/?#]\S*)?/#) {
            return target(owner: String(page.1), repo: String(page.2), number: String(page.3))
        }
        if let short = text.wholeMatch(of: #/([^/\s#]+)/([^/\s#]+)#([0-9]+)/#) {
            return target(owner: String(short.1), repo: String(short.2), number: String(short.3))
        }
        return nil
    }

    /// `--open-link <url>`: prints the pull request a link names, or fails. Reads nothing and writes nothing.
    static func printFromCommandLine(_ text: String) -> Never {
        guard let target = parse(text) else {
            FileHandle.standardError.write(Data("Not a WorkTime pull request link\n".utf8))
            exit(2)
        }
        print("\(target.repo) #\(target.number) \(target.url)")
        exit(0)
    }

    static func pullRequest(at address: String) -> Target? {
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
