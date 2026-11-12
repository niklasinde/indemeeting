import Foundation

/// notify, scheduled_notifications and cancel_notification: notifications handed to the running app through the agent inbox.
extension MCPServer {
    struct NoticeSources {
        var file = AppPaths.notices
        var inbox = AppPaths.agentInbox
        var replyTimeout: TimeInterval = 10
        var timeZone = TimeZone.current
        var source: () -> NoticeSource = {
            NoticeSource.current(environment: ProcessInfo.processInfo.environment, cwd: FileManager.default.currentDirectoryPath)
        }

        func notices() -> [AgentNotice] { NoticeLogic.decode(try? Data(contentsOf: file)) }

        func send(_ request: NoticeRequest) throws -> NoticeReply {
            try ask(AgentInbox.encode(request), id: request.id, name: NoticeLogic.requestName(request.id), what: "the notification")
        }

        /// Hands the app a request and returns its answer, or throws the app's reason when it says no.
        func ask(_ data: Data, id: String, name: String, what: String) throws -> NoticeReply {
            let reply: NoticeReply = try exchange(data, id: id, name: name, inbox: inbox, timeout: replyTimeout, what: what)
            guard reply.ok else { throw MCPToolError(reply.message) }
            return reply
        }
    }

    static func noticeTools(sources: NoticeSources = NoticeSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        [
            MCPTool(name: "notify",
                    description: "Tells the user something needs them with a macOS notification from WorkTime, kept in the notch bar's "
                        + "Reminders list until they open or dismiss it. Use it when something needs the user and they may not be watching; "
                        + "with at, it fires later (a meeting reminder, say). Clicking it opens the link. Repeats within a minute collapse.",
                    properties: ["title": ["type": "string", "maxLength": NoticeLogic.titleLimit, "description": "Short: what needs the user."],
                                 "body": ["type": "string", "maxLength": NoticeLogic.bodyLimit, "description": "One or two sentences more."],
                                 "link": ["type": "string",
                                          "description": "Opened on click: a GitHub pull request url (opens in WorkTime), a Jira key or url, a Slack "
                                              + "permalink, any https url, or a WorkTime agent key (main:<workspace>, topic:<id>, an assistant's key)."],
                                 "urgency": ["type": "string", "enum": ["normal", "high"], "description": "normal when left out."],
                                 "at": ["type": "string",
                                        "description": "When to show it instead of now: ISO 8601 (2026-11-12T13:15, local time without an offset) "
                                            + "or HH:mm for today (tomorrow once past). At most 30 days ahead."]],
                    required: ["title"], readOnly: false) { args in
                let date = now()
                let notice: AgentNotice
                switch NoticeLogic.notice(args, source: sources.source(), now: date, timeZone: sources.timeZone) {
                case .success(let made): notice = made
                case .failure(let error): throw MCPToolError(error.message)
                }
                let reply = try sources.send(NoticeRequest(id: UUID().uuidString, action: .notify, notice: notice, source: notice.source, created: date))
                return NoticeLogic.replyText(reply, scheduled: notice.at, timeZone: sources.timeZone)
            },
            MCPTool(name: "scheduled_notifications",
                    description: "Notifications waiting for their time, soonest first, with id, time, title and who scheduled them. "
                        + "Optional filters, all combined: source, urgency, due_before, due_after, query; the answer says which applied.",
                    properties: NoticeFilter.properties) { args in
                let filter = try NoticeFilter(args, now: now(), timeZone: sources.timeZone)
                let pending = NoticeLogic.pending(sources.notices()).filter(filter.matches)
                return FilterLogic.header(filter.applied) + (pending.isEmpty ? "No scheduled notifications.\n"
                    : pending.map { NoticeLogic.line($0, timeZone: sources.timeZone) }.joined(separator: "\n") + "\n")
            },
            MCPTool(name: "cancel_notification",
                    description: "Cancels a scheduled notification by its id. Agents can cancel their own; a Main can cancel any.",
                    properties: ["id": ["type": "string", "description": "The id notify or scheduled_notifications gave."]],
                    required: ["id"], readOnly: false) { args in
                guard let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { throw MCPToolError("id is required.") }
                let source = sources.source()
                if let problem = NoticeLogic.cancelProblem(id, in: sources.notices(), by: source) { throw MCPToolError(problem) }
                return try sources.send(NoticeRequest(id: UUID().uuidString, action: .cancel, cancel: id, source: source, created: now())).message
            },
        ]
    }

    /// The notifications still in the user's list, for the attention tool; nil when there are none.
    static func noticeAttention(_ sources: NoticeSources) -> String? {
        let notices = sources.notices()
        let waiting = NoticeLogic.waiting(notices), pending = NoticeLogic.pending(notices)
        guard !waiting.isEmpty || !pending.isEmpty else { return nil }
        return (waiting + pending).prefix(10).map { NoticeLogic.line($0, timeZone: sources.timeZone) + ($0.state == .scheduled ? " \u{00B7} scheduled" : "") }
            .joined(separator: "\n") + "\n"
    }
}
