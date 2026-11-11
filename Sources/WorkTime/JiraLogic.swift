import Foundation

struct JiraTicket: Equatable, Identifiable, Sendable {
    let key: String
    let summary: String
    let status: String
    let priority: String?
    let updated: Date?

    var id: String { key }
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

    static var searchBody: [String: Any] { ["jql": jql, "fields": fields, "maxResults": maxResults] }

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

    private static func date(_ text: String) -> Date? {
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
    static let jira = TokenStore(secrets: AppSecretStore(service: "com.niklasinde.MeetingRecorder.jira"), account: "api-token")
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
