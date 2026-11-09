import Foundation

/// Sends one request and returns the body and the HTTP status. Tests replace it with a fake.
typealias JiraTransport = @Sendable (URLRequest) async throws -> (Data, Int)

/// Jira Cloud REST v3 with Basic auth (email and API token).
struct JiraClient: Sendable {
    let site: String
    let email: String
    let token: String
    var transport: JiraTransport = JiraClient.urlSession

    static let urlSession: JiraTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func displayName() async throws -> String {
        let data = try await send(path: JiraLogic.myselfPath)
        do { return try JiraLogic.parseDisplayName(data) } catch { throw JiraError.failed("unexpected response") }
    }

    /// The open tickets assigned to the user, through the current search endpoint or the older one where it is missing.
    func assigned() async throws -> JiraSearch {
        let data: Data
        do {
            data = try await send(path: JiraLogic.searchPath, body: JiraLogic.searchBody)
        } catch JiraError.notFound {
            data = try await send(path: JiraLogic.legacySearchPath, body: JiraLogic.searchBody)
        }
        var search: JiraSearch
        do { search = try JiraLogic.parseSearch(data) } catch { throw JiraError.failed("unexpected response") }
        if search.total == nil {
            search.total = try? JiraLogic.parseCount(await send(path: JiraLogic.countPath, body: ["jql": JiraLogic.filter]))
        }
        return search
    }

    private func send(path: String, body: [String: Any]? = nil) async throws -> Data {
        let request = JiraLogic.request(site: site, path: path, email: email, token: token, body: body)
        let (data, status): (Data, Int)
        do { (data, status) = try await transport(request) } catch { throw JiraError.from(error) }
        if status == 405 || status == 410 { throw JiraError.notFound }
        guard (200..<300).contains(status) else { throw JiraError.from(status: status, body: data) }
        return data
    }
}
