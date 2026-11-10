import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let fakeToken = "FAKE-JIRA-TOKEN-0000"

private func issue(_ key: String, summary: String = "Fix the thing", status: String = "In Progress", priority: String? = "High",
                   updated: String = "2026-10-19T12:58:21.000+0200") -> String {
    let priorityJSON = priority.map { #"{"name":"\#($0)"}"# } ?? "null"
    return #"{"id":"1","key":"\#(key)","fields":{"summary":"\#(summary)","status":{"name":"\#(status)","statusCategory":{"key":"indeterminate"}},"priority":\#(priorityJSON),"updated":"\#(updated)"}}"#
}

private func searchResponse(_ issues: [String], tail: String = #""isLast":true"#) -> Data {
    Data(#"{"issues":[\#(issues.joined(separator: ","))],\#(tail)}"#.utf8)
}

private final class Requests: @unchecked Sendable {
    var seen: [URLRequest] = []
}

/// A transport answering each path with a fixed status and body, recording the requests.
private func fake(_ answers: [String: (Int, Data)], requests: Requests = Requests()) -> JiraTransport {
    { request in
        requests.seen.append(request)
        let (status, body) = answers[request.url?.path ?? ""] ?? (404, Data())
        return (body, status)
    }
}

private final class Outcome<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = Outcome<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.result!
}

private func client(_ transport: @escaping JiraTransport) -> JiraClient {
    JiraClient(site: "acme.atlassian.net", email: "me@acme.com", token: fakeToken, transport: transport)
}

let jiraTests: [(name: String, run: () throws -> Void)] = [
    ("a search/jql response is parsed into tickets with every field", {
        let search = try JiraLogic.parseSearch(searchResponse([issue("QDLY-1"), issue("QDLY-2", summary: "Other", status: "To Do", priority: nil)]))
        check(search.tickets.map(\.key) == ["QDLY-1", "QDLY-2"], "keys")
        check(search.tickets[0].summary == "Fix the thing" && search.tickets[0].status == "In Progress", "summary and status")
        check(search.tickets[0].priority == "High" && search.tickets[1].priority == nil, "priority")
        check(search.tickets[0].updated == Date(timeIntervalSince1970: 1_792_407_501), "updated \(String(describing: search.tickets[0].updated))")
        check(search.total == 2, "the last page counts itself")
    }),

    ("the total comes from the legacy response, and is unknown when more pages follow", {
        check(try JiraLogic.parseSearch(searchResponse([issue("A-1")], tail: #""total":57,"startAt":0"#)).total == 57, "legacy total")
        check(try JiraLogic.parseSearch(searchResponse([issue("A-1")], tail: #""isLast":false,"nextPageToken":"abc""#)).total == nil, "more pages")
        check(JiraLogic.headline(total: 57, shown: 20) == "57 assigned to you", "known total")
        check(JiraLogic.headline(total: nil, shown: 20) == "20+ assigned to you", "unknown total")
    }),

    ("the JQL asks for open tickets assigned to the user, newest first", {
        check(JiraLogic.jql == "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC", "jql")
        let body = JiraLogic.searchBody
        check(body["jql"] as? String == JiraLogic.jql, "body jql")
        check(body["fields"] as? [String] == ["key", "summary", "status", "priority", "updated"], "fields")
        check(body["maxResults"] as? Int == 20, "max results")
    }),

    ("requests go to the site over https with Basic auth and a JSON body", {
        let request = JiraLogic.request(site: "acme.atlassian.net", path: JiraLogic.searchPath, email: "me@acme.com", token: fakeToken,
                                        body: JiraLogic.searchBody)
        check(request.url?.absoluteString == "https://acme.atlassian.net/rest/api/3/search/jql", "url \(request.url?.absoluteString ?? "")")
        check(request.httpMethod == "POST", "post")
        let expected = "Basic " + Data("me@acme.com:\(fakeToken)".utf8).base64EncodedString()
        check(request.value(forHTTPHeaderField: "Authorization") == expected, "basic auth")
        let sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        check(sent?["jql"] as? String == JiraLogic.jql && sent?["maxResults"] as? Int == 20, "body")
        let myself = JiraLogic.request(site: "acme.atlassian.net", path: JiraLogic.myselfPath, email: "me@acme.com", token: fakeToken)
        check(myself.httpMethod == "GET" && myself.httpBody == nil, "myself is a GET")
    }),

    ("a typed site is reduced to its host, and the browse link is built from it", {
        check(JiraLogic.site("https://Acme.atlassian.net/browse/QDLY-1") == "acme.atlassian.net", "pasted link")
        check(JiraLogic.site(" acme.atlassian.net/ ") == "acme.atlassian.net", "trailing slash")
        check(JiraLogic.site("acme") == "acme.atlassian.net", "bare name")
        check(JiraLogic.site("") == nil && JiraLogic.site("not a site") == nil, "rejected")
        check(JiraLogic.browseURL(site: "acme.atlassian.net", key: "QDLY-8")?.absoluteString == "https://acme.atlassian.net/browse/QDLY-8", "browse")
    }),

    ("the suggested site is the one most prefixes point at", {
        check(JiraLogic.suggestedSite([:]) == nil, "none known")
        check(JiraLogic.suggestedSite(["QDLY": "b.atlassian.net", "QPB": "b.atlassian.net", "X": "a.atlassian.net"]) == "b.atlassian.net", "most")
        check(JiraLogic.suggestedSite(["X": "b.atlassian.net", "Y": "a.atlassian.net"]) == "a.atlassian.net", "tie by name")
    }),

    ("the client searches the current endpoint and counts beyond the first page", {
        let requests = Requests()
        let transport = fake([JiraLogic.searchPath: (200, searchResponse([issue("A-1")], tail: #""isLast":false,"nextPageToken":"x""#)),
                              JiraLogic.countPath: (200, Data(#"{"count":42}"#.utf8))], requests: requests)
        let search = try blocking { try await client(transport).assigned() }.get()
        check(search.tickets.map(\.key) == ["A-1"] && search.total == 42, "tickets and count")
        check(requests.seen.map { $0.url?.path ?? "" } == [JiraLogic.searchPath, JiraLogic.countPath], "paths")
        let count = try JSONSerialization.jsonObject(with: requests.seen[1].httpBody ?? Data()) as? [String: Any]
        check(count?["jql"] as? String == JiraLogic.filter, "count without ordering")
    }),

    ("the client falls back to the older search endpoint when the current one is missing", {
        let requests = Requests()
        let transport = fake([JiraLogic.legacySearchPath: (200, searchResponse([issue("A-1"), issue("A-2")], tail: #""total":2"#))],
                             requests: requests)
        let search = try blocking { try await client(transport).assigned() }.get()
        check(search.tickets.count == 2 && search.total == 2, "legacy result")
        check(requests.seen.map { $0.url?.path ?? "" } == [JiraLogic.searchPath, JiraLogic.legacySearchPath], "fell back")
    }),

    ("errors are classified, and none of them contains the token", {
        let unauthorized = blocking { try await client(fake([JiraLogic.myselfPath: (401, Data())])).displayName() }
        check((try? unauthorized.get()) == nil, "401 fails")
        if case .failure(let error) = unauthorized { check(error as? JiraError == .unauthorized, "unauthorized \(error)") }
        let body = Data(#"{"errorMessages":["The value 'x' does not exist for the field 'project'."],"errors":{}}"#.utf8)
        check(JiraError.from(status: 400, body: body) == .failed("The value 'x' does not exist for the field 'project'."), "error message")
        check(JiraError.from(status: 500, body: Data()) == .failed("HTTP 500"), "bare status")
        check(JiraError.from(URLError(.cannotFindHost)) == .offline, "offline")
        let name = blocking { try await client(fake([JiraLogic.myselfPath: (200, Data(#"{"displayName":"Niklas Inde"}"#.utf8))])).displayName() }
        check((try? name.get()) == "Niklas Inde", "display name")
        for error in [JiraError.unauthorized, .forbidden, .notFound, .offline, .rateLimited, .notConfigured] {
            check(!error.message.contains(fakeToken), "no token in \(error)")
        }
    }),

    ("the token store saves a trimmed token and removes it, with an in-memory store", {
        let secrets = MemorySecretStore()
        let tokens = TokenStore(secrets: secrets, account: TokenStore.jira.account)
        check(tokens.token() == nil, "nothing saved yet")
        try tokens.save("  \(fakeToken)\n")
        check(tokens.token() == fakeToken, "trimmed token")
        check(secrets.key(for: TokenStore.jira.account) == Data(fakeToken.utf8), "stored under the api-token account")
        tokens.remove()
        check(tokens.token() == nil, "removed")
    }),
]
