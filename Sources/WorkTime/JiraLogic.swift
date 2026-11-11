import Foundation

struct JiraTicket: Equatable, Identifiable, Sendable {
    let key: String
    let summary: String
    let status: String
    let priority: String?
    let updated: Date?

    var id: String { key }
}

/// One issue as the agents' `jira_issue` tool shows it.
struct JiraIssue: Equatable, Sendable {
    struct Comment: Equatable, Sendable {
        let author: String
        let created: Date?
        let body: String
    }

    struct Link: Equatable, Sendable {
        let relation: String
        let key: String
        let summary: String
        let status: String
    }

    let key: String
    let summary: String
    let status: String
    let type: String?
    let priority: String?
    let assignee: String?
    let reporter: String?
    let created: Date?
    let updated: Date?
    let description: String
    let comments: [Comment]
    let commentTotal: Int
    let links: [Link]
}

struct JiraSearch: Equatable, Sendable {
    var tickets: [JiraTicket]
    /// Nil when there are more pages and the count is not known.
    var total: Int?
}

enum JiraError: Error, Equatable {
    case notConfigured
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case offline
    case failed(String)

    var message: String {
        switch self {
        case .notConfigured: return "Add your Jira site, email and API token in Settings."
        case .unauthorized: return "Jira did not accept the email and API token. Check them in Settings."
        case .forbidden: return "The Jira account is not allowed to search issues on this site."
        case .notFound: return "No Jira Cloud site answered at this address. Check the site in Settings."
        case .rateLimited: return "Jira is rate limiting requests. Try again in a few minutes."
        case .offline: return "Jira cannot be reached. Check the site and your connection."
        case .failed(let detail): return "Jira returned an error: \(detail)"
        }
    }

    static func from(status: Int, body: Data) -> JiraError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .rateLimited
        default:
            let messages = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.errorMessages ?? []
            return .failed(messages.first.map { ActivityLogic.truncate($0, to: 160) } ?? "HTTP \(status)")
        }
    }

    static func from(_ error: Error) -> JiraError {
        if let error = error as? JiraError { return error }
        let offline: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut,
                                        .networkConnectionLost, .dnsLookupFailed]
        if let error = error as? URLError, offline.contains(error.code) { return .offline }
        return .failed(error.localizedDescription)
    }

    private struct ErrorBody: Decodable {
        let errorMessages: [String]?
    }
}

enum JiraLogic {
    static let enabledKey = "jiraEnabled"
    static let siteKey = "jiraSite"
    static let emailKey = "jiraEmail"
    static let intervalKey = "jiraRefreshMinutes"
    static let filter = "assignee = currentUser() AND statusCategory != Done"
    static let jql = filter + " ORDER BY updated DESC"
    static let fields = ["key", "summary", "status", "priority", "updated"]
    static let maxResults = 20
    static let tokenPage = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
    static let searchPath = "/rest/api/3/search/jql"
    static let legacySearchPath = "/rest/api/3/search"
    static let countPath = "/rest/api/3/search/approximate-count"
    static let myselfPath = "/rest/api/3/myself"
    static let issueFields = ["summary", "status", "issuetype", "priority", "assignee", "reporter", "created", "updated", "description",
                              "comment", "issuelinks"]
    static let commentLimit = 10
    static let searchLimit = 50

    static func issuePath(_ key: String) -> String { "/rest/api/3/issue/\(key)?fields=" + issueFields.joined(separator: ",") }

    /// `ISD-123` from a typed key in any case, or from a pasted browse or board link; nil for anything else.
    static func issueKey(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [text]
        if text.contains("://"), let url = URLComponents(string: text) {
            candidates += (url.queryItems ?? []).filter { $0.name == "selectedIssue" }.compactMap(\.value)
            candidates += url.path.split(separator: "/").last.map { [String($0)] } ?? []
        }
        return candidates.map { $0.uppercased() }.first { $0.wholeMatch(of: #/[A-Z][A-Z0-9_]+-[1-9][0-9]*/#) != nil }
    }

    /// The host of a typed site: `yourco`, `yourco.atlassian.net` or a pasted `https://yourco.atlassian.net/browse/X-1`.
    static func site(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        guard let host = text.split(separator: "/").first.map(String.init), !host.isEmpty,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return host.contains(".") ? host : host + ".atlassian.net"
    }

    /// The Jira site seen most often in the browser, as the suggestion for Settings.
    static func suggestedSite(_ sites: [String: String]) -> String? {
        let counts = Dictionary(sites.values.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.min { ($1.value, $0.key) < ($0.value, $1.key) }?.key
    }

    static func browseURL(site: String, key: String) -> URL? {
        URL(string: "https://\(site)/browse/\(key)")
    }

    static func authorization(email: String, token: String) -> String {
        "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    static func request(site: String, path: String, email: String, token: String, body: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(site)\(path)")!)
        request.setValue(authorization(email: email, token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    static var searchBody: [String: Any] { searchBody(jql: jql) }

    static func searchBody(jql: String, max: Int = maxResults) -> [String: Any] { ["jql": jql, "fields": fields, "maxResults": max] }

    static func parseSearch(_ data: Data) throws -> JiraSearch {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        let tickets = response.issues.map { issue in
            JiraTicket(key: issue.key, summary: issue.fields.summary ?? "", status: issue.fields.status?.name ?? "",
                       priority: issue.fields.priority?.name, updated: issue.fields.updated.flatMap(date))
        }
        let complete = response.isLast ?? (response.nextPageToken == nil && response.total == nil)
        return JiraSearch(tickets: tickets, total: response.total ?? (complete ? tickets.count : nil))
    }

    static func parseCount(_ data: Data) throws -> Int {
        try JSONDecoder().decode(CountResponse.self, from: data).count
    }

    static func parseDisplayName(_ data: Data) throws -> String {
        try JSONDecoder().decode(Myself.self, from: data).displayName
    }

    static func headline(total: Int?, shown: Int) -> String {
        total.map { "\($0) assigned to you" } ?? "\(shown)+ assigned to you"
    }

    static func parseIssue(_ data: Data) throws -> JiraIssue {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let key = object["key"] as? String,
              let fields = object["fields"] as? [String: Any] else { throw JiraError.failed("unexpected response") }
        func name(_ value: Any?) -> String? { (value as? [String: Any])?["name"] as? String }
        func person(_ value: Any?) -> String? { (value as? [String: Any])?["displayName"] as? String }
        let comment = fields["comment"] as? [String: Any] ?? [:]
        let comments = (comment["comments"] as? [[String: Any]] ?? []).map {
            JiraIssue.Comment(author: person($0["author"]) ?? "Someone", created: ($0["created"] as? String).flatMap(date), body: text($0["body"]))
        }
        let links = (fields["issuelinks"] as? [[String: Any]] ?? []).compactMap { link -> JiraIssue.Link? in
            let type = link["type"] as? [String: Any] ?? [:]
            let outward = link["outwardIssue"] != nil
            guard let issue = link[outward ? "outwardIssue" : "inwardIssue"] as? [String: Any], let linked = issue["key"] as? String else { return nil }
            let linkedFields = issue["fields"] as? [String: Any] ?? [:]
            return JiraIssue.Link(relation: type[outward ? "outward" : "inward"] as? String ?? "relates to", key: linked,
                                  summary: linkedFields["summary"] as? String ?? "", status: name(linkedFields["status"]) ?? "")
        }
        return JiraIssue(key: key, summary: fields["summary"] as? String ?? "", status: name(fields["status"]) ?? "", type: name(fields["issuetype"]),
                         priority: name(fields["priority"]), assignee: person(fields["assignee"]), reporter: person(fields["reporter"]),
                         created: (fields["created"] as? String).flatMap(date), updated: (fields["updated"] as? String).flatMap(date),
                         description: text(fields["description"]), comments: comments,
                         commentTotal: comment["total"] as? Int ?? comments.count, links: links)
    }

    /// Plain text of an Atlassian Document Format value, or of a plain string as older sites return.
    static func text(_ document: Any?) -> String {
        func walk(_ node: Any?) -> String {
            if let text = node as? String { return text }
            guard let node = node as? [String: Any] else { return "" }
            let inner = (node["content"] as? [Any] ?? []).map(walk).joined()
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            switch node["type"] as? String {
            case "text": return node["text"] as? String ?? ""
            case "hardBreak": return "\n"
            case "mention", "emoji", "status": return attrs["text"] as? String ?? attrs["shortName"] as? String ?? ""
            case "inlineCard", "blockCard": return attrs["url"] as? String ?? ""
            case "listItem": return "- " + inner.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            case "paragraph", "heading", "codeBlock", "blockquote", "tableRow": return inner + "\n"
            case "tableCell", "tableHeader": return inner.trimmingCharacters(in: .whitespacesAndNewlines) + " | "
            default: return inner
            }
        }
        return walk(document).replacing(#/\n{3,}/#, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func issueMarkdown(_ issue: JiraIssue, site: String?, now: Date) -> String {
        let facts = [issue.type, issue.status, issue.priority.map { "priority \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
        var lines = ["# \(issue.key) \(issue.summary)", facts.joined(separator: " \u{00B7} ")]
        if let site, let url = browseURL(site: site, key: issue.key) { lines.append(url.absoluteString) }
        lines.append("Assignee: \(issue.assignee ?? "unassigned") \u{00B7} Reporter: \(issue.reporter ?? "unknown")")
        let times = [issue.created.map { "Created \(GitHubLogic.updatedText($0, now: now))" },
                     issue.updated.map { "updated \(GitHubLogic.updatedText($0, now: now))" }].compactMap { $0 }
        if !times.isEmpty { lines.append(times.joined(separator: ", ")) }
        lines.append("\n## Description\n" + (issue.description.isEmpty ? "No description." : issue.description))
        if !issue.links.isEmpty {
            lines.append("\n## Linked issues\n" + issue.links.map { "- \($0.relation) \($0.key) \($0.summary)" + ($0.status.isEmpty ? "" : " (\($0.status))") }
                .joined(separator: "\n"))
        }
        let shown = issue.comments.suffix(commentLimit)
        let header = "\n## Comments" + (issue.commentTotal > shown.count ? " (last \(shown.count) of \(issue.commentTotal))" : "")
        lines.append(header + "\n" + (shown.isEmpty ? "No comments." : shown.map { comment in
            "### \(comment.author)" + (comment.created.map { ", \(GitHubLogic.updatedText($0, now: now))" } ?? "") + "\n" + comment.body
        }.joined(separator: "\n\n")))
        return lines.joined(separator: "\n") + "\n"
    }

    static func searchMarkdown(_ search: JiraSearch, jql: String, site: String?, now: Date) -> String {
        guard !search.tickets.isEmpty else { return "No issues match \(jql).\n" }
        let count = search.total.map { "\($0) issue\($0 == 1 ? "" : "s")" } ?? "\(search.tickets.count)+ issues"
        return "\(count) for \(jql)\n" + search.tickets.map { ticket in
            let facts = [ticket.status, ticket.priority, ticket.updated.map { "updated \(GitHubLogic.updatedText($0, now: now))" }].compactMap { $0 }
            let url = site.flatMap { browseURL(site: $0, key: ticket.key) }.map { "\n  \($0.absoluteString)" } ?? ""
            return "- \(ticket.key) \(ticket.summary) \u{00B7} " + facts.joined(separator: " \u{00B7} ") + url
        }.joined(separator: "\n") + "\n"
    }

    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter.date(from: text)
    }

    private struct SearchResponse: Decodable {
        let issues: [Issue]
        let total: Int?
        let isLast: Bool?
        let nextPageToken: String?
    }

    private struct Issue: Decodable {
        let key: String
        let fields: Fields
    }

    private struct Fields: Decodable {
        let summary: String?
        let status: Named?
        let priority: Named?
        let updated: String?
    }

    private struct Named: Decodable {
        let name: String
    }

    private struct CountResponse: Decodable {
        let count: Int
    }

    private struct Myself: Decodable {
        let displayName: String
    }
}

/// An API token in the app's secrets file and nowhere else.
struct TokenStore {
    static let jiraService = "com.niklasinde.MeetingRecorder.jira"
    static let jira = TokenStore(secrets: AppSecretStore(service: jiraService), account: "api-token")
    static let slackService = "com.niklasinde.MeetingRecorder.slack"
    static let slack = TokenStore(secrets: AppSecretStore(service: slackService), account: "user-token")

    let secrets: PhoneSecretStore
    let account: String

    func token() -> String? {
        secrets.key(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func save(_ token: String) throws {
        try secrets.save(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8), for: account)
    }

    func remove() {
        secrets.delete(account)
    }
}
