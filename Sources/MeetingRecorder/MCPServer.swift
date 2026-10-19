import Foundation

struct MCPTool {
    let name: String
    let description: String
    let properties: [String: [String: Any]]
    let run: ([String: Any]) throws -> String

    var listing: [String: Any] {
        ["name": name, "description": description, "annotations": ["readOnlyHint": true, "openWorldHint": false],
         "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false]]
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
        Read-only access to MeetingRecorder on this Mac: the user's meetings (summaries, action items, notes, transcripts \
        with speakers) and tracked activity (apps, repositories, branches, tickets, Claude Code sessions, hours).
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
                             "serverInfo": ["name": "meetingrecorder", "version": version],
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

    /// `--mcp`: serves the read-only tools over stdin and stdout until stdin closes.
    static func runFromCommandLine() -> Never {
        let store = Result { try MeetingStore.openReadOnly() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let server = MCPServer(tools: meetingTools(store), version: version)
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let response = server.handle(line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
        exit(0)
    }
}

extension MCPServer {
    static func meetingTools(_ opened: Result<MeetingStore, Error>, now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func store() throws -> MeetingStore {
            do { return try opened.get() } catch {
                throw MCPToolError("The MeetingRecorder database at \(AppPaths.database.path) could not be opened: \(error.localizedDescription)")
            }
        }
        let limit: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many meetings, 10 when left out."]
        return [
            MCPTool(name: "activity_context",
                    description: "What the user worked on in the last hours: active time, projects, apps, repositories and branches, "
                        + "tickets, websites, Claude Code sessions, recent writing and meetings, as Markdown.",
                    properties: ["hours": ["type": "number", "minimum": 0.25, "maximum": 168, "description": "Hours back from now, 8 when left out."]]) {
                try store().contextMarkdown(hours: min(max(number($0["hours"]) ?? 8, 0.25), 168), now: now())
            },
            MCPTool(name: "time_report",
                    description: "Hours for one week per day and project, with totals per branch and per ticket, as Markdown.",
                    properties: ["week_start": ["type": "string", "description": "Any day of the week as YYYY-MM-DD; this week when left out."]]) {
                let day = try ($0["week_start"] as? String).map(date) ?? now()
                return ActivityLogic.markdown(try store().weekReport(containing: day))
            },
            MCPTool(name: "search_meetings",
                    description: "Finds meetings whose title, transcript, summary or notes contain every word (as a word prefix). "
                        + "Returns ids for get_meeting, best matches first.",
                    properties: ["query": ["type": "string", "description": "Words to search for."], "limit": limit]) {
                guard let query = $0["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw MCPToolError("query is required")
                }
                let found = try store().searchMeetings(query, limit: count($0["limit"]))
                guard !found.isEmpty else { return "No meetings match \u{201C}\(query)\u{201D}.\n" }
                return found.map { meetingLine($0.meeting) + "\n  " + $0.snippet.replacingOccurrences(of: "\n", with: " ") }
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
                let limit = max(Int(number($0["max_characters"]) ?? 40_000), 1000)
                return text.count <= limit ? text : String(text.prefix(limit)) + "\n\n[Cut at \(limit) characters]\n"
            },
            MCPTool(name: "recent_meetings", description: "The latest meetings, newest first, with ids for get_meeting.",
                    properties: ["limit": limit]) {
                let meetings = try store().meetings().sorted { $0.created > $1.created }.prefix(count($0["limit"]))
                return meetings.isEmpty ? "No meetings yet.\n" : meetings.map(meetingLine).joined(separator: "\n") + "\n"
            },
        ]
    }

    static func meetingLine(_ meeting: Meeting) -> String {
        "- id \(meeting.id) \u{00B7} " + [ActivityLogic.dateText(meeting.created) + " " + meeting.created.formatted(date: .omitted, time: .shortened),
                                          meeting.title, meeting.duration.map(ActivityLogic.hoursText)].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    private static func count(_ value: Any?) -> Int {
        min(max(Int(number(value) ?? 10), 1), 50)
    }

    private static func date(_ text: String) throws -> Date {
        guard let date = try? Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash).parse(text) else {
            throw MCPToolError("week_start must be YYYY-MM-DD, not \(text)")
        }
        return date
    }
}

/// `<data folder>/bin/meetingrecorder`, a link to the running app that the Claude Code plugin starts with `--mcp`.
enum CommandLineLink {
    static func refresh(link: URL = AppPaths.commandLineLink, bundle: Bundle = .main) {
        guard bundle.bundleURL.pathExtension == "app", let executable = bundle.executableURL else { return }
        let fileManager = FileManager.default
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != executable.path else { return }
        try? fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: link)
        try? fileManager.createSymbolicLink(at: link, withDestinationURL: executable)
    }
}
