import Foundation

/// Where a resume card's parts come from. The app and the `--mcp` process read the same database, caches and files.
struct ResumeSources: Sendable {
    var store: @Sendable () throws -> MeetingStore
    var jira: @Sendable () -> MCPServer.JiraAccess? = { MCPServer.storedJira() }
    var githubEnabled: @Sendable () -> Bool = { MCPServer.githubSwitchIsOn() }
    var agentState = AppPaths.agentState
    var projects = ClaudeTranscripts.projectsFolder
}

/// Builds a resume card from the activity blocks, the GitHub cache, Jira, the meetings and the agents. Read-only.
enum ResumeGatherer {
    static func blocks(_ store: MeetingStore, before: Date) throws -> [ActivityBlock] {
        try store.blocks(in: before.addingTimeInterval(-Double(ResumeLogic.lookbackDays) * 86_400)..<before)
    }

    static func card(for key: ResumeContextKey, entered: Date, blocks: [ActivityBlock], sources: ResumeSources) async throws -> ResumeCard {
        let store = try sources.store()
        let visit = ResumeLogic.lastVisit(blocks, key: key, before: entered)
        let since = visit?.end ?? entered
        var card = ResumeCard(key: key, entered: entered, visit: visit)
        if let visit { card.prompts = prompts(visit, root: sources.projects) }
        if sources.githubEnabled(), let pr = ResumeLogic.pullRequest(for: key, in: uniquePRs(try store.githubPRs()), head: store.githubHeadBranch) {
            card.pr = ResumeLogic.changes(pr, detail: try? store.githubDetail(pr.url), comments: (try? store.githubComments(pr.url))?.comments,
                                          since: since)
        }
        if let ticket = key.ticket, let access = sources.jira() {
            card.ticket = try? await jiraTicket(ticket, access: access, since: since)
        }
        card.meetings = meetings(store, key: key, pr: card.pr?.number, from: (visit?.start ?? entered).addingTimeInterval(-ResumeLogic.meetingLead))
        let agents = (try? Data(contentsOf: sources.agentState)).flatMap(AgentOverview.decode)?.agents ?? []
        card.agent = ResumeLogic.agent(in: agents, prURL: card.pr?.url, ticket: key.ticket)
        return card
    }

    private static func uniquePRs(_ lists: [GitHubKind: [GitHubPR]]) -> [GitHubPR] {
        var seen = Set<String>()
        return lists.values.joined().filter { seen.insert($0.url).inserted }
    }

    /// The last prompts typed in the visit's sessions, read from the end of their transcripts.
    static func prompts(_ visit: ResumeVisit, root: URL, limit: Int = 3) -> [ResumePrompt] {
        visit.sessions.prefix(limit).flatMap { session -> [ResumePrompt] in
            guard let url = ClaudeTranscripts.transcript(id: session.id, cwd: session.folder, root: root), let text = tail(url) else { return [] }
            return ResumeLogic.prompts(inJSONL: text, until: visit.end.addingTimeInterval(60))
                .map { ResumePrompt(session: session.title, text: $0.text, date: $0.time) }
        }
        .prefix(limit).map { $0 }
    }

    private static func tail(_ url: URL, bytes: UInt64 = 512_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: size > bytes ? size - bytes : 0)) != nil, let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func jiraTicket(_ key: String, access: MCPServer.JiraAccess, since: Date) async throws -> ResumeTicket {
        let data = try await access.client.send(path: ResumeLogic.issuePath(key))
        return ResumeLogic.ticket(try JiraLogic.parseIssue(data), changes: ResumeLogic.parseChangelog(data), since: since,
                                  url: JiraLogic.browseURL(site: access.site, key: key)?.absoluteString)
    }

    static func meetings(_ store: MeetingStore, key: ResumeContextKey, pr: Int?, from: Date, limit: Int = 3) -> [ResumeMention] {
        var found: [Int64: ResumeMention] = [:]
        for query in ResumeLogic.meetingQueries(ticket: key.ticket, repo: key.repo) {
            for hit in (try? store.searchMeetings(query, limit: 10)) ?? [] where hit.meeting.created >= from && found[hit.meeting.id] == nil {
                guard let content = try? store.content(of: hit.meeting.audioFile),
                      let line = ResumeLogic.mentionLine(in: ProcessingLogic.exportMarkdown(content), ticket: key.ticket, prNumber: pr, repo: key.repo)
                else { continue }
                found[hit.meeting.id] = ResumeMention(meeting: hit.meeting.id, title: hit.meeting.title, date: hit.meeting.created, line: line)
            }
        }
        return found.values.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }
}

extension MCPServer {
    static func resumeTools(_ opened: Result<MeetingStore, Error>, sources: ResumeSources? = nil, timeout: TimeInterval = 30,
                            now: @escaping @Sendable () -> Date = { Date() }) -> [MCPTool] {
        let sources = sources ?? ResumeSources(store: { try openedStore(opened) })
        return [
            MCPTool(name: "resume_context",
                    description: "Where the user left off on a branch, repository or Jira ticket: when they were last there and for how long, "
                        + "their last Claude Code prompts there, the pull request with commits, comments and checks since then, the "
                        + "ticket's status, assignee and comment changes since then, meetings that mentioned it with the line, and its "
                        + "WorkTime agent. With no arguments, the context the user was in last. Read-only.",
                    properties: ["repo": ["type": "string", "description": "Repository folder name or owner/name, e.g. finq.api."],
                                 "branch": ["type": "string", "description": "Branch name, e.g. NI/QDLY-1234."],
                                 "ticket": ["type": "string", "description": "Jira key like QDLY-1234, or its browse link."]]) { args in
                func text(_ name: String) -> String? {
                    (args[name] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
                }
                let ticket = try text("ticket").map { raw -> String in
                    guard let key = JiraLogic.issueKey(raw) else { throw MCPToolError("ticket must be a Jira key like QDLY-1234, not \u{201C}\(raw)\u{201D}.") }
                    return key
                }
                let date = now()
                let blocks = try ResumeGatherer.blocks(try sources.store(), before: date)
                let wanted = [text("repo"), text("branch"), ticket].contains { $0 != nil }
                guard let key = wanted ? ResumeLogic.context(repo: text("repo"), branch: text("branch"), ticket: ticket, blocks: blocks)
                        : ResumeLogic.latestContext(blocks) else {
                    throw MCPToolError(wanted ? "No tracked activity on that repository in the last \(ResumeLogic.lookbackDays) days; pass a branch or ticket."
                                              : "No tracked repository, branch or ticket in the last \(ResumeLogic.lookbackDays) days.")
                }
                switch blocking(timeout: timeout, { ResumeLogic.markdown(try await ResumeGatherer.card(for: key, entered: date, blocks: blocks, sources: sources), now: date) }) {
                case .success(let text): return cut(text, at: outputLimit)
                case .failure(let error): throw error
                case nil: throw MCPToolError("resume_context did not finish within \(Int(timeout)) seconds.")
                }
            },
        ]
    }
}
