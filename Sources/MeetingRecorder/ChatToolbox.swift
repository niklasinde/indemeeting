import Foundation

/// The lookups the chat may make, as the same `MCPTool`s the MCP server offers plus a few for one meeting or one stretch
/// of activity. Every result is cut to what fits the model's context.
enum ChatToolbox {
    static func tools(for scope: ChatScope, store: MeetingStore, budget: ChatBudget, now: @escaping () -> Date = Date.init) -> [MCPTool] {
        let shared = MCPServer.meetingTools(.success(store), now: now)
        func named(_ names: [String]) -> [MCPTool] { names.compactMap { name in shared.first { $0.name == name } } }
        let tools: [MCPTool]
        switch scope.kind {
        case .general:
            tools = named(["search_meetings", "get_meeting", "recent_meetings"]) + [meetingsOn(store, now), openActionItems(store)]
                + [activityOn(store, now)] + named(["activity_context", "time_report"])
        case .meeting, .notes:
            tools = scope.meetingID.map { [searchInMeeting(store, $0, budget), readTranscript(store, $0, budget), getNotes(store, $0)] } ?? []
        case .activityBlock:
            tools = [blockDetails(store, scope), blocksInRange(store, scope, now)]
        case .day, .week:
            tools = [blocksInRange(store, scope, now)] + named(["time_report"]) + [meetingsOn(store, now)] + named(["get_meeting"])
        }
        return tools.map { capped($0, budget) }
    }

    /// What the model is told about the subject before the first question.
    static func overview(for scope: ChatScope, store: MeetingStore, budget: ChatBudget, now: Date = Date()) throws -> String? {
        switch scope.kind {
        case .general: return nil
        case .meeting, .notes:
            guard let content = try scope.meetingID.flatMap({ try meetingContent(store, $0) }) else { return nil }
            return ChatLogic.overview(of: content, maxCharacters: budget.overview)
        case .activityBlock:
            guard let range = scope.range, let id = scope.id, let block = try store.blocks(in: range).first(where: { $0.id == id }) else { return nil }
            return ChatLogic.trim(ChatLogic.blockDetails(block), maxCharacters: budget.overview)
        case .day:
            guard let range = scope.range else { return nil }
            let markdown = ActivityLogic.contextMarkdown(blocks: try store.blocks(in: range), meetings: try store.meetingLines(in: range), range: range,
                                                         rules: try store.rules(), projects: try store.projects(), directory: try store.ticketDirectory())
            return ChatLogic.trim(markdown, maxCharacters: budget.overview)
        case .week:
            guard let from = scope.from else { return nil }
            return ChatLogic.trim(ActivityLogic.markdown(try store.weekReport(containing: from)), maxCharacters: budget.overview)
        }
    }

    private static func capped(_ tool: MCPTool, _ budget: ChatBudget) -> MCPTool {
        let isMeeting = tool.name == "get_meeting"
        return MCPTool(name: tool.name, description: tool.description, properties: tool.properties, required: tool.required) { arguments in
            var arguments = arguments
            if isMeeting { arguments["max_characters"] = max(budget.toolOutput, 1000) }
            return ChatLogic.trim(try tool.run(arguments), maxCharacters: budget.toolOutput)
        }
    }

    private static func meetingContent(_ store: MeetingStore, _ id: Int64) throws -> MeetingContent? {
        try store.meeting(id: id).flatMap { try store.content(of: $0.audioFile) }
    }

    private static func requireContent(_ store: MeetingStore, _ id: Int64) throws -> MeetingContent {
        guard let content = try meetingContent(store, id) else { throw MCPToolError("This meeting no longer exists.") }
        return content
    }

    // MARK: General

    private static func meetingsOn(_ store: MeetingStore, _ now: @escaping () -> Date) -> MCPTool {
        MCPTool(name: "meetings_on", description: "The meetings on one day, with ids for get_meeting.",
                properties: ["date": ["type": "string", "description": "The day as YYYY-MM-DD."]], required: ["date"]) {
            guard let text = $0["date"] as? String else { throw MCPToolError("date is required") }
            let range = ActivityLogic.day(containing: try MCPServer.date(text))
            let found = try store.meetings().filter { range.contains($0.created) }.sorted { $0.created < $1.created }
            return found.isEmpty ? "No meetings on \(text).\n" : found.map(MCPServer.meetingLine).joined(separator: "\n") + "\n"
        }
    }

    private static func activityOn(_ store: MeetingStore, _ now: @escaping () -> Date) -> MCPTool {
        MCPTool(name: "activity_on", description: "What the user worked on during one day as Markdown: time, projects, apps, repositories, tickets.",
                properties: ["date": ["type": "string", "description": "The day as YYYY-MM-DD, today when left out."]]) {
            let day = ActivityLogic.day(containing: try ($0["date"] as? String).map(MCPServer.date) ?? now())
            let end = min(day.upperBound, now())
            return try store.contextMarkdown(hours: max(end.timeIntervalSince(day.lowerBound), 60) / 3600, now: end)
        }
    }

    private static func openActionItems(_ store: MeetingStore) -> MCPTool {
        MCPTool(name: "open_action_items", description: "Action items from all meetings that are not ticked off yet, newest first, with owner.",
                properties: ["limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many, 20 when left out."]]) {
            let items = try store.openActionItems(limit: MCPServer.count($0["limit"] ?? 20))
            guard !items.isEmpty else { return "No open action items.\n" }
            return items.map {
                "- id \($0.meeting) \u{00B7} \(ActivityLogic.dateText($0.date)) \u{00B7} \($0.title) \u{00B7} " + ($0.owner.map { "\($0): " } ?? "no owner: ") + $0.task
            }.joined(separator: "\n") + "\n"
        }
    }

    // MARK: One meeting

    private static func searchInMeeting(_ store: MeetingStore, _ id: Int64, _ budget: ChatBudget) -> MCPTool {
        MCPTool(name: "search_in_meeting",
                description: "Finds the transcript lines of this meeting that contain the words, with time and speaker.",
                properties: ["query": ["type": "string", "description": "Words to look for."]], required: ["query"]) {
            guard let query = $0["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else { throw MCPToolError("query is required") }
            let content = try requireContent(store, id)
            let lines = ChatLogic.search(content.segments, query: query, names: content.names, language: content.meeting.language ?? .current,
                                         maxCharacters: budget.toolOutput)
            return lines.isEmpty ? "No transcript lines match \u{201C}\(query)\u{201D}.\n" : lines.joined(separator: "\n") + "\n"
        }
    }

    private static func readTranscript(_ store: MeetingStore, _ id: Int64, _ budget: ChatBudget) -> MCPTool {
        MCPTool(name: "read_transcript",
                description: "Reads this meeting's transcript between two times, about five minutes when to is left out.",
                properties: ["from": ["type": "string", "description": "Start as mm:ss, 0:00 when left out."],
                             "to": ["type": "string", "description": "End as mm:ss."]]) {
            let start = ($0["from"] as? String).flatMap(ChatLogic.seconds) ?? 0
            let end = ($0["to"] as? String).flatMap(ChatLogic.seconds) ?? start + 300
            let content = try requireContent(store, id)
            let text = ChatLogic.excerpt(content.segments, from: start, to: max(end, start + 1), names: content.names,
                                         language: content.meeting.language ?? .current, maxCharacters: budget.toolOutput)
            return text.isEmpty ? "The transcript has no lines in that time.\n" : text + "\n"
        }
    }

    private static func getNotes(_ store: MeetingStore, _ id: Int64) -> MCPTool {
        MCPTool(name: "get_notes", description: "The notes the user wrote for this meeting.", properties: [:]) { _ in
            let notes = try requireContent(store, id).meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return notes.isEmpty ? "The user wrote no notes for this meeting.\n" : notes + "\n"
        }
    }

    // MARK: Activity

    private static func blockDetails(_ store: MeetingStore, _ scope: ChatScope) -> MCPTool {
        MCPTool(name: "block_details", description: "Everything known about the activity this chat is about.", properties: [:]) { _ in
            guard let range = scope.range, let id = scope.id, let block = try store.blocks(in: range).first(where: { $0.id == id }) else {
                throw MCPToolError("This activity is no longer stored.")
            }
            return ChatLogic.blockDetails(block) + "\n"
        }
    }

    private static func blocksInRange(_ store: MeetingStore, _ scope: ChatScope, _ now: @escaping () -> Date) -> MCPTool {
        let around: TimeInterval = scope.kind == .activityBlock ? 3600 : 0
        let base = scope.range.map { ($0.lowerBound.addingTimeInterval(-around))..<($0.upperBound.addingTimeInterval(around)) }
            ?? now().addingTimeInterval(-8 * 3600)..<now()
        return MCPTool(name: "blocks_in_range",
                       description: "The tracked activity between two times, one line per block with app, window, repository, branch and ticket.",
                       properties: ["from": ["type": "string", "description": "Start as YYYY-MM-DD HH:mm, or HH:mm on the day of this chat."],
                                    "to": ["type": "string", "description": "End in the same form."]]) {
            let start = ($0["from"] as? String).flatMap { parse($0, day: base.lowerBound) } ?? base.lowerBound
            let end = ($0["to"] as? String).flatMap { parse($0, day: base.lowerBound) } ?? base.upperBound
            guard start < end else { throw MCPToolError("from must be before to") }
            let blocks = try store.blocks(in: start..<end).filter { !$0.key.idle }
            guard !blocks.isEmpty else { return "No activity between those times.\n" }
            let limit = 60
            let lines = blocks.prefix(limit).map(ChatLogic.blockLine) + (blocks.count > limit ? ["(\(blocks.count - limit) more blocks; narrow the range)"] : [])
            return lines.joined(separator: "\n") + "\n"
        }
    }

    private static func parse(_ text: String, day: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }
}
