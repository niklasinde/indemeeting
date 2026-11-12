import Foundation

struct MCPTool {
    let name: String
    let description: String
    let properties: [String: [String: Any]]
    var required: [String] = []
    var readOnly = true
    let run: ([String: Any]) throws -> String

    var listing: [String: Any] {
        ["name": name, "description": description, "annotations": ["readOnlyHint": readOnly, "openWorldHint": false],
         "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false]
            .merging(required.isEmpty ? [:] : ["required": required]) { $1 }]
    }
}

struct MCPToolError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

/// A Model Context Protocol server: JSON-RPC 2.0, one message per line on stdin and stdout.
struct MCPServer {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let instructions = """
        Read-only access to WorkTime on this Mac: the user's meetings (summaries, action items, notes, transcripts \
        with speakers), tracked activity (apps, repositories, branches, tickets, Claude Code sessions, hours), cached pull \
        requests, the app's Claude agents, and read-only Jira and Slack lookups with the tokens set up in WorkTime. send_to_agent \
        hands a prompt to one of the app's agents, notify shows the user a notification, now or at a set time, and \
        add_reminder and complete_reminder write to the user's Apple Reminders.
        """

    let tools: [MCPTool]
    var version = "1.0"

    /// The response to one message, or nil for a notification.
    func handle(_ line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let message = object as? [String: Any], let method = message["method"] as? String else {
            return Self.encode(["jsonrpc": "2.0", "id": (object as? [String: Any])?["id"] ?? NSNull(),
                                "error": ["code": -32600, "message": "Invalid request"]])
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch respond(method, params) {
        case .success(let result): return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
        case .failure(let error): return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        }
    }

    private struct RPCError: Error {
        let code: Int
        let message: String
    }

    private func respond(_ method: String, _ params: [String: Any]) -> Result<[String: Any], RPCError> {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return .success(["protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                             "capabilities": ["tools": ["listChanged": false]],
                             "serverInfo": ["name": "worktime", "version": version],
                             "instructions": Self.instructions])
        case "ping":
            return .success([:])
        case "tools/list":
            return .success(["tools": tools.map(\.listing)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return .failure(RPCError(code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "")"))
            }
            do {
                return .success(["content": [["type": "text", "text": try tool.run(params["arguments"] as? [String: Any] ?? [:])]],
                                 "isError": false])
            } catch {
                return .success(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return .failure(RPCError(code: -32601, message: "Method not found: \(method)"))
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The names of every tool the server offers.
    static var toolNames: [String] {
        let none = Result<MeetingStore, Error>.failure(MCPToolError(""))
        return (meetingTools(none) + githubTools(none) + agentTools(none) + topicTools() + resumeTools(none) + noticeTools() + reminderTools()).map(\.name)
    }

    /// `--mcp`: serves the read-only tools over stdin and stdout until stdin closes.
    static func runFromCommandLine() -> Never {
        let store = Result { try MeetingStore.openReadOnly() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let github = githubTools(store)
        let server = MCPServer(tools: meetingTools(store) + github + agentTools(store, github: github) + topicTools() + resumeTools(store) + noticeTools()
                                   + reminderTools(),
                               version: version)
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let response = server.handle(line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
        exit(0)
    }
}

extension MCPServer {
    static func meetingTools(_ opened: Result<MeetingStore, Error>, now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func store() throws -> MeetingStore { try openedStore(opened) }
        let limit = limitSchema("meetings", 10)
        return [
            MCPTool(name: "activity_context",
                    description: "What the user worked on in the last hours: active time, projects, apps, repositories and branches, "
                        + "tickets, websites, Claude Code sessions, recent writing and meetings, as Markdown. Optional filters, all combined: "
                        + "since and until (instead of hours), app, repo, branch, ticket, project, category; the answer says which applied.",
                    properties: ["hours": ["type": "number", "minimum": 0.25, "maximum": 168, "description": "Hours back from now, 8 when left out."],
                                 "since": ["type": "string", "description": "Start of the period instead of hours: YYYY-MM-DD or an ISO 8601 date-time."],
                                 "until": ["type": "string", "description": "End of the period, now when left out: YYYY-MM-DD (that day counts) or ISO 8601."]]
                        .merging(ActivityFilter.properties) { $1 }) { args in
                    let date = now(), filter = try ActivityFilter(args)
                    let since = try FilterLogic.bound(args, "since", end: false, now: date)
                    let until = try FilterLogic.bound(args, "until", end: true, now: date)
                    let end = until ?? date
                    let start = since ?? end.addingTimeInterval(-hours(args) * 3600)
                    guard start < end else { throw MCPToolError("since must be before until, which is now when left out.") }
                    let range = start..<end
                    let applied = FilterLogic.applied(["since": FilterLogic.text(args, "since"), "until": FilterLogic.text(args, "until")]) + filter.applied
                    return FilterLogic.header(applied) + (try store().contextMarkdown(range: range, filter: filter))
            },
            MCPTool(name: "time_report",
                    description: "Hours for one week per day and project, with totals per branch and per ticket, as Markdown. Optional filters, "
                        + "all combined: app, repo, branch, ticket, project, category; the answer says which applied.",
                    properties: ["week_start": ["type": "string", "description": "Any day of the week as YYYY-MM-DD; this week when left out."]]
                        .merging(ActivityFilter.properties) { $1 }) { args in
                let day = try (args["week_start"] as? String).map(date) ?? now(), filter = try ActivityFilter(args)
                return FilterLogic.header(filter.applied) + ActivityLogic.markdown(try store().weekReport(containing: day, filter: filter))
            },
            MCPTool(name: "search_meetings",
                    description: "Finds meetings whose title, transcript, summary or notes contain every word (as a word prefix). "
                        + "Returns ids for get_meeting, best matches first. Optional filters, all combined: since, until, with, source, status, "
                        + "min_minutes, has_action_items; the answer says which applied.",
                    properties: ["query": ["type": "string", "description": "Words to search for."], "limit": limit]
                        .merging(MeetingFilter.properties) { $1 }) { args in
                guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw MCPToolError("query is required")
                }
                let filter = try MeetingFilter(args.filter { $0.key != "query" }, now: now())
                let store = try store()
                let found = try store.searchMeetings(query, limit: filter.isEmpty ? count(args["limit"]) : searchPool)
                let kept = try filter.apply(found.map(\.meeting), in: store).map(\.id)
                let shown = found.filter { kept.contains($0.meeting.id) }.prefix(count(args["limit"]))
                guard !shown.isEmpty else { return FilterLogic.header(filter.applied) + "No meetings match \u{201C}\(query)\u{201D}.\n" }
                return FilterLogic.header(filter.applied) + shown.map { meetingLine($0.meeting) + "\n  " + $0.snippet.replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: "\n") + "\n"
            },
            MCPTool(name: "get_meeting",
                    description: "One meeting as Markdown: summary, action items, notes and the transcript with timestamps and speakers.",
                    properties: ["id": ["type": "integer", "description": "The meeting id from recent_meetings or search_meetings."],
                                 "max_characters": ["type": "integer", "minimum": 1000, "description": "Cut the text here, 40000 when left out."]]) {
                guard let id = number($0["id"]).map(Int64.init) else { throw MCPToolError("id is required") }
                let store = try store()
                guard let meeting = try store.meeting(id: id), let content = try store.content(of: meeting.audioFile) else {
                    throw MCPToolError("No meeting with id \(id)")
                }
                let text = meetingLine(meeting) + "\n\n" + ProcessingLogic.exportMarkdown(content)
                return cut(text, at: max(Int(number($0["max_characters"]) ?? Double(outputLimit)), 1000))
            },
            MCPTool(name: "recent_meetings",
                    description: "The latest meetings, newest first, with ids for get_meeting. Optional filters, all combined: since, until, with, "
                        + "source, status, min_minutes, has_action_items, query (in the title or notes); the answer says which applied.",
                    properties: ["limit": limit, "query": ["type": "string", "description": "Only meetings whose title or notes contain this."]]
                        .merging(MeetingFilter.properties) { $1 }) { args in
                let filter = try MeetingFilter(args, now: now())
                let store = try store()
                let meetings = try filter.apply(try store.meetings(), in: store).sorted { $0.created > $1.created }.prefix(count(args["limit"]))
                return FilterLogic.header(filter.applied) + (meetings.isEmpty ? "No meetings yet.\n" : meetings.map(meetingLine).joined(separator: "\n") + "\n")
            },
        ]
    }

    static let searchPool = 500

    static func hours(_ args: [String: Any]) -> Double { min(max(number(args["hours"]) ?? 8, 0.25), 168) }

    static func meetingLine(_ meeting: Meeting) -> String {
        "- id \(meeting.id) \u{00B7} " + [ActivityLogic.dateText(meeting.created) + " " + meeting.created.formatted(date: .omitted, time: .shortened),
                                          meeting.title, meeting.duration.map(ActivityLogic.hoursText)].compactMap { $0 }.joined(separator: " \u{00B7} ")
            + (meeting.source.flatMap { MeetingSourceLogic.label(app: $0.app, title: $0.title) }.map { " (source: \($0))" } ?? "")
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    static let outputLimit = 40_000

    static func limitSchema(_ what: String, _ fallback: Int) -> [String: Any] {
        ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many \(what), \(fallback) when left out."]
    }

    static func openedStore(_ opened: Result<MeetingStore, Error>) throws -> MeetingStore {
        do { return try opened.get() } catch {
            throw MCPToolError("The WorkTime database at \(AppPaths.database.path) could not be opened: \(error.localizedDescription)")
        }
    }

    static func cut(_ text: String, at limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "\n\n[Cut at \(limit) characters]\n"
    }

    static func count(_ value: Any?, fallback: Int = 10) -> Int {
        min(max(Int(number(value) ?? Double(fallback)), 1), 50)
    }

    static func date(_ text: String) throws -> Date {
        guard let date = try? Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash).parse(text) else {
            throw MCPToolError("week_start must be YYYY-MM-DD, not \(text)")
        }
        return date
    }
}

/// `<data folder>/bin/worktime`, a link to the running app that the Claude Code plugin starts with `--mcp`, and
/// `meetingrecorder` beside it, its name before the rename, for plugins that still look for that.
enum CommandLineLink {
    static let name = "worktime"
    static let legacyName = "meetingrecorder"

    static func refresh(folder: URL = AppPaths.commandLineFolder, bundle: Bundle = .main) {
        guard bundle.bundleURL.pathExtension == "app", let executable = bundle.executableURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        link(folder.appendingPathComponent(name), to: executable.path)
        link(folder.appendingPathComponent(legacyName), to: name)
    }

    private static func link(_ link: URL, to destination: String) {
        let fileManager = FileManager.default
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != destination else { return }
        try? fileManager.removeItem(at: link)
        try? fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }
}
