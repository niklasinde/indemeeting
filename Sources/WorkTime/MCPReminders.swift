import Foundation

/// add_reminder, reminders and complete_reminder: the user's Apple Reminders, read and written by the running app (it holds
/// the Reminders permission) through the agent inbox.
extension MCPServer {
    static func reminderTools(sources: NoticeSources = NoticeSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func send(_ request: ReminderRequest) throws -> String {
            try sources.ask(AgentInbox.encode(request), id: request.id, name: ReminderLogic.requestName(request.id), what: "the reminder").message
        }
        func request(_ action: ReminderRequest.Action) -> ReminderRequest {
            ReminderRequest(id: UUID().uuidString, action: action, source: sources.source(), created: now())
        }
        func text(_ args: [String: Any], _ name: String) -> String? {
            (args[name] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return [
            MCPTool(name: "add_reminder",
                    description: "Adds a reminder to the user's Apple Reminders (shown in WorkTime's notch bar), for something the user "
                        + "should do later rather than be told now. The notes say which agent added it. An open reminder with the same "
                        + "title and due in the same list is returned instead of adding another.",
                    properties: ["title": ["type": "string", "maxLength": NoticeLogic.titleLimit, "description": "What to do."],
                                 "notes": ["type": "string", "maxLength": NoticeLogic.bodyLimit],
                                 "due": ["type": "string",
                                         "description": "ISO 8601 (2026-11-13T09:00, local time without an offset) or HH:mm for today "
                                             + "(tomorrow once past), which also sets an alarm then; a date alone (2026-11-13) is all-day. "
                                             + "At most 30 days ahead."],
                                 "list": ["type": "string", "description": "A Reminders list by name; the list WorkTime shows when left out."],
                                 "link": ["type": "string",
                                          "description": "A GitHub pull request (url or owner/repo#number), a Jira key or url, or an https url."],
                                 "priority": ["type": "string", "enum": ReminderPriority.allCases.map(\.rawValue)]],
                    required: ["title"], readOnly: false) { args in
                var add = request(.add)
                switch ReminderLogic.draft(args, now: add.created, timeZone: sources.timeZone) {
                case .success(let draft): add.draft = draft
                case .failure(let error): throw MCPToolError(error.message)
                }
                return try send(add)
            },
            MCPTool(name: "reminders",
                    description: "The user's open Apple Reminders, due ones soonest first: id, list, title, due, priority and link.",
                    properties: ["list": ["type": "string", "description": "Only this list, by name."],
                                 "due_before": ["type": "string",
                                                "description": "Only reminders due before this: a date (that day counts), ISO 8601 or HH:mm."]]) { args in
                var list = request(.list)
                list.list = text(args, "list")
                if let raw = text(args, "due_before") {
                    switch ReminderLogic.dueBefore(raw, now: list.created, timeZone: sources.timeZone) {
                    case .success(let date): list.dueBefore = date
                    case .failure(let error): throw MCPToolError(error.message)
                    }
                }
                return try send(list)
            },
            MCPTool(name: "complete_reminder",
                    description: "Marks one of the user's Apple Reminders as completed, by the id add_reminder or reminders gave.",
                    properties: ["id": ["type": "string"]], required: ["id"], readOnly: false) { args in
                guard let id = text(args, "id") else { throw MCPToolError("id is required.") }
                var complete = request(.complete)
                complete.reminder = id
                return try send(complete)
            },
        ]
    }
}
