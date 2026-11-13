import Foundation

/// meeting_brief: the pre-meeting brief of the user's next meeting, or of one named, made by the running app (it holds the calendar
/// permission) and handed back through the agent inbox.
extension MCPServer {
    static func briefTools(sources: NoticeSources = NoticeSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        [
            MCPTool(name: "meeting_brief",
                    description: "A short brief for a calendar meeting, as the notch bar shows it before the meeting: who is in it, what the last "
                        + "meetings with them decided, action items still open from them, the tickets and pull requests the invitation names with "
                        + "their Jira and GitHub state, and its agenda. The next meeting today when event is left out; the answer says which applied.",
                    properties: ["event": ["type": "string", "description": "A meeting's title (part of it is enough) or id, among those of the next week."]]) { args in
                let event = FilterLogic.text(args, "event")
                var wait = sources
                wait.replyTimeout = 30
                let request = BriefRequest(id: UUID().uuidString, event: event, created: now())
                let reply = try wait.ask(AgentInbox.encode(request), id: request.id, name: MeetingBriefLogic.requestName(request.id), what: "the brief")
                return FilterLogic.header(FilterLogic.applied(["event": event])) + reply.message
            },
        ]
    }
}
