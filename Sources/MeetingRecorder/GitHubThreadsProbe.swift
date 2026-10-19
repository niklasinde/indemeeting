import Foundation

/// `--github-pr-threads <owner/repo#n>`: a read-only feasibility probe for review threads. Fetches the threads, the pull
/// request comments and the reviews in one query and prints what the data looks like and what the query cost. Writes nothing.
enum GitHubThreadsProbe {
    static let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          rateLimit { cost remaining limit }
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              comments(first: 100) { totalCount pageInfo { hasNextPage } nodes { author { login __typename } body createdAt url } }
              reviews(first: 100) { totalCount pageInfo { hasNextPage } nodes { author { login __typename } body state submittedAt } }
              reviewThreads(first: 50) {
                totalCount
                pageInfo { hasNextPage }
                nodes {
                  isResolved isOutdated isCollapsed path line startLine diffSide resolvedBy { login }
                  comments(first: 50) {
                    totalCount
                    nodes {
                      author { login __typename } body createdAt diffHunk outdated replyTo { id } url
                      pullRequestReview { state } reactions { totalCount }
                    }
                  }
                }
              }
            }
          }
        }
        """

    static func runFromCommandLine(_ reference: String) -> Never {
        guard let target = GitHubLogic.reference(reference), let cli = GitHubLogic.findCLI() else {
            FileHandle.standardError.write(Data("Usage: --github-pr-threads owner/repo#number (needs gh)\n".utf8))
            exit(2)
        }
        let owner = GitHubLogic.repoName(target.repo)
        let arguments = ["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(owner.owner)", "-f", "name=\(owner.name)", "-F", "number=\(target.number)"]
        guard let output = GitHubClient.run(cli, arguments), output.status == 0,
              let root = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any], let data = root["data"] as? [String: Any],
              let pr = (data["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else {
            FileHandle.standardError.write(Data("Failed to fetch threads\n".utf8))
            exit(1)
        }
        print("\(reference): payload \(output.stdout.count) bytes, rateLimit \(data["rateLimit"] ?? "?")")
        print(report(pr))
        exit(0)
    }

    private static func list(_ object: Any?, _ key: String = "nodes") -> [[String: Any]] {
        ((object as? [String: Any])?[key] as? [[String: Any]]) ?? []
    }

    private static func count(_ object: Any?) -> Int { ((object as? [String: Any])?["totalCount"] as? Int) ?? 0 }
    private static func hasNext(_ object: Any?) -> Bool { (((object as? [String: Any])?["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool) ?? false }
    private static func body(_ node: [String: Any]) -> String { node["body"] as? String ?? "" }
    private static func login(_ node: [String: Any]) -> String { ((node["author"] as? [String: Any])?["login"] as? String) ?? "ghost" }
    private static func isBot(_ node: [String: Any]) -> Bool { ((node["author"] as? [String: Any])?["__typename"] as? String) == "Bot" }

    static func report(_ pr: [String: Any]) -> String {
        let threads = list(pr["reviewThreads"])
        let comments = threads.map { list($0["comments"]) }
        let flat = comments.flatMap { $0 }
        let sizes = comments.map(\.count)
        let issueComments = list(pr["comments"])
        let reviews = list(pr["reviews"])
        let everything = flat + issueComments + reviews
        let authors = Dictionary(grouping: everything, by: login).mapValues(\.count).sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        func has(_ needle: String) -> Int { everything.filter { body($0).contains(needle) }.count }
        let replies = flat.filter { $0["replyTo"] is [String: Any] }.count
        return """
            threads: \(count(pr["reviewThreads"])) (fetched \(threads.count), more pages: \(hasNext(pr["reviewThreads"])))
              resolved \(threads.filter { $0["isResolved"] as? Bool == true }.count), outdated \(threads.filter { $0["isOutdated"] as? Bool == true }.count), \
            collapsed \(threads.filter { $0["isCollapsed"] as? Bool == true }.count), resolved and outdated \(threads.filter { $0["isResolved"] as? Bool == true && $0["isOutdated"] as? Bool == true }.count)
              comments per thread: avg \(sizes.isEmpty ? 0 : Double(sizes.reduce(0, +)) / Double(sizes.count)), max \(sizes.max() ?? 0), \
            totalCount beyond 50: \(threads.contains { count($0["comments"]) > 50 })
              comments with replyTo: \(replies) of \(flat.count); every reply points at the thread's first comment: \(replyTargetsAreFlat(comments))
              thread comments by bots: \(flat.filter(isBot).count); on a range (startLine set): \(threads.filter { $0["startLine"] is Int }.count); \
            line null (outdated or file level): \(threads.filter { $0["line"] == nil || $0["line"] is NSNull }.count)
            pr comments: \(count(pr["comments"])) (more pages: \(hasNext(pr["comments"]))), reviews: \(count(pr["reviews"])) \
            (with body: \(reviews.filter { !body($0).isEmpty }.count), states \(Dictionary(grouping: reviews, by: { $0["state"] as? String ?? "?" }).mapValues(\.count)))
            authors: \(authors.prefix(8).map { name, count in "\(name)\(everything.contains { login($0) == name && isBot($0) } ? " [bot]" : "") \(count)" }.joined(separator: ", "))
            bots among all: \(everything.filter(isBot).count)
            body features: suggestion blocks \(has("```suggestion")), fenced code \(has("```")), tables \(everything.filter { body($0).contains("|---") || body($0).contains("| ---") }.count), \
            images \(has("![") + has("<img")), html details \(has("<details")), html comments \(has("<!--")), mentions \(has("@")), reactions on \(flat.filter { count($0["reactions"]) > 0 }.count) comments
            diffHunk: avg \(flat.isEmpty ? 0 : flat.map { ($0["diffHunk"] as? String ?? "").count }.reduce(0, +) / flat.count) characters, max \(flat.map { ($0["diffHunk"] as? String ?? "").count }.max() ?? 0)
            """
    }

    /// Whether every reply in every thread points at that thread's first comment, which is how GitHub keeps a thread flat.
    private static func replyTargetsAreFlat(_ threads: [[[String: Any]]]) -> Bool {
        threads.allSatisfy { comments in
            guard let first = comments.first?["url"] as? String else { return true }
            let firstID = comments.dropFirst().compactMap { ($0["replyTo"] as? [String: Any])?["id"] as? String }
            return Set(firstID).count <= 1 && comments.dropFirst().allSatisfy { $0["replyTo"] is [String: Any] } && !first.isEmpty
        }
    }
}
