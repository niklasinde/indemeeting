import Foundation

struct PhoneResponse {
    enum Body {
        case data(Data)
        case file(URL, offset: Int64, length: Int64)
    }

    var status = 200
    var contentType = "application/json"
    var headers: [String: String] = [:]
    var body: Body

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> PhoneResponse {
        PhoneResponse(status: status, body: .data((try? PhoneAPI.encoder.encode(value)) ?? Data("{}".utf8)))
    }

    static func error(_ status: Int, _ code: String, _ message: String, headers: [String: String] = [:]) -> PhoneResponse {
        var response = json(PhoneError(error: code, message: message), status: status)
        response.headers = headers
        return response
    }
}

/// A chat to run on the Mac: the scope, the earlier turns and the question.
struct PhoneChatJob {
    let scope: ChatScope
    let history: [ChatMessage]
    let question: String
}

enum PhoneRoute {
    case response(PhoneResponse)
    case chat(PhoneChatJob)
}

/// What the phone may ask for. Everything here reads; the only write is the GitHub refresh, which goes through
/// `refreshGitHub`. Chats are run by the caller from the job this returns and are never stored.
struct PhoneEndpoints {
    static let maxLimit = 200
    static let maxBlocks = 5000
    static let maxChatMessages = 40
    static let maxChatCharacters = 8000

    let store: MeetingStore
    var audioFolder: URL = AppPaths.recordings
    var appVersion = "1.0"
    var serverName = ProcessInfo.processInfo.hostName
    var now: @Sendable () -> Date = { Date() }
    var features: @Sendable () -> PhoneFeatures = { PhoneFeatures(githubEnabled: false, activityEnabled: false, chatAvailable: false) }
    /// Fetches the pull requests and saves them; returns why that failed, if it did.
    var refreshGitHub: @Sendable () async -> String? = { nil }

    func handle(_ request: HTTPRequest) async -> PhoneRoute {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { return .response(.error(404, "not_found", "Unknown path.")) }
        do {
            switch (request.method, Array(parts.dropFirst())) {
            case ("GET", ["status"]): return .response(try status())
            case ("GET", ["meetings"]): return .response(try meetings(request))
            case ("GET", let rest) where rest.count == 2 && rest[0] == "meetings": return .response(try meeting(rest[1]))
            case ("GET", let rest) where rest.count == 3 && rest[0] == "meetings" && rest[2] == "audio": return .response(try audio(rest[1], request))
            case ("GET", ["activity", "day"]): return .response(try activity(request, week: false))
            case ("GET", ["activity", "week"]): return .response(try activity(request, week: true))
            case ("GET", ["github"]): return .response(try github())
            case ("POST", ["github", "refresh"]): return .response(await refresh())
            case ("POST", ["chat"]): return try chat(request)
            default:
                return .response(Self.isKnown(parts) ? .error(405, "method_not_allowed", "That method is not supported here.", headers: ["Allow": request.method == "GET" ? "POST" : "GET"])
                                                     : .error(404, "not_found", "Unknown path."))
            }
        } catch let error as PhoneRequestError {
            return .response(.error(error.status, error.code, error.message))
        } catch {
            return .response(.error(500, "internal", "The Mac could not read its data."))
        }
    }

    private static func isKnown(_ parts: [String]) -> Bool {
        switch Array(parts.dropFirst()) {
        case ["status"], ["meetings"], ["activity", "day"], ["activity", "week"], ["github"], ["github", "refresh"], ["chat"]: return true
        case let rest where rest.count == 2 && rest[0] == "meetings": return true
        case let rest where rest.count == 3 && rest[0] == "meetings" && rest[2] == "audio": return true
        default: return false
        }
    }

    // MARK: Status

    private func status() throws -> PhoneResponse {
        .json(PhoneStatus(appVersion: appVersion, apiVersion: PhoneAPI.version, schemaVersion: try store.schemaVersion(),
                          serverTime: now(), serverName: serverName, features: features()))
    }

    // MARK: Meetings

    private func meetings(_ request: HTTPRequest) throws -> PhoneResponse {
        let limit = min(max(request.query["limit"].flatMap(Int.init) ?? 50, 1), Self.maxLimit)
        let query = request.query["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty {
            let found = try store.searchMeetings(query, limit: limit)
            let summaries = try summaries(of: found.map(\.meeting))
            return .json(PhoneMeetingList(meetings: zip(summaries, found).map { var summary = $0; summary.snippet = $1.snippet; return summary }))
        }
        var all = try store.meetings().sorted { ($0.created, $0.id) > ($1.created, $1.id) }
        if let text = request.query["before"] {
            guard let before = ISO8601DateFormatter().date(from: text) else { throw PhoneRequestError.bad("before must be an ISO 8601 date.") }
            all = all.filter { Int($0.created.timeIntervalSince1970) < Int(before.timeIntervalSince1970) }
        }
        let page = Array(all.prefix(limit))
        return .json(PhoneMeetingList(meetings: try summaries(of: page), nextBefore: all.count > limit ? page.last?.created : nil))
    }

    private func summaries(of meetings: [Meeting]) throws -> [PhoneMeetingSummary] {
        let speakers = try store.speakerLabels(of: meetings.map(\.id))
        return try meetings.map { meeting in
            let language = meeting.language ?? .current
            let names = speakers[meeting.id] ?? []
            return PhoneMeetingSummary(id: meeting.id, title: meeting.title, date: meeting.created, duration: meeting.duration,
                                       language: meeting.language?.code, hasSummary: meeting.summarised,
                                       speakers: names.map { $0.name ?? $0.speaker.name(in: language) },
                                       chatCount: try store.chatCount(meeting: meeting.id))
        }
    }

    private func meeting(_ text: String) throws -> PhoneResponse {
        guard let id = Int64(text), let meeting = try store.meeting(id: id), let content = try store.content(of: meeting.audioFile) else {
            throw PhoneRequestError.notFound("No meeting with that id.")
        }
        let language = meeting.language ?? .current
        let duration = meeting.duration
        let segments = content.segments.enumerated().map { index, segment -> PhoneSegment in
            let following = index + 1 < content.segments.count ? content.segments[index + 1].start : nil
            let limit = segment.start + SpeakerLogic.maxSegmentLength
            let end = min(max(following ?? limit, segment.start), limit, duration.map { max($0, segment.start) } ?? limit)
            return PhoneSegment(start: segment.start, end: end, speaker: segment.speaker?.rawValue,
                                speakerName: segment.speaker.map { content.names.name(of: $0, in: language) }, text: segment.text)
        }
        let file = audioURL(meeting)
        let bytes = file.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? nil }
        let summary = content.summary
        return .json(PhoneMeetingDetail(
            id: meeting.id, title: meeting.title, date: meeting.created, duration: duration,
            languages: meeting.language.map { [$0.code] } ?? [], languageDetected: meeting.languageDetected,
            engines: PhoneEngines(transcript: meeting.transcriptEngine, summary: meeting.summarised ? "apple-intelligence" : nil),
            summaryTitle: summary.title, summaryUnavailable: summary.unavailable,
            topics: summary.sections.map { PhoneSummaryTopic(title: $0.heading, points: $0.lines.map(\.text)) },
            actionItems: summary.actionItems.map { PhoneActionItem(id: Int64($0.key) ?? 0, owner: $0.owner, text: $0.task, done: $0.done) },
            notes: meeting.notes, transcript: segments,
            audio: PhoneAudioInfo(available: bytes != nil, duration: duration, bytes: bytes,
                                  contentType: bytes == nil ? nil : PhoneHTTP.contentType(forAudio: meeting.audioFile))))
    }

    /// The recording's file, only when its stored name is a plain file name inside the recordings folder.
    private func audioURL(_ meeting: Meeting) -> URL? {
        guard (meeting.audioFile as NSString).lastPathComponent == meeting.audioFile, !meeting.audioFile.hasPrefix(".") else { return nil }
        let url = audioFolder.appendingPathComponent(meeting.audioFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func audio(_ text: String, _ request: HTTPRequest) throws -> PhoneResponse {
        guard let id = Int64(text), let meeting = try store.meeting(id: id), let url = audioURL(meeting),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil else {
            throw PhoneRequestError.notFound("This meeting has no audio on the Mac.")
        }
        var response = PhoneResponse(contentType: PhoneHTTP.contentType(forAudio: meeting.audioFile), headers: ["Accept-Ranges": "bytes"],
                                     body: .file(url, offset: 0, length: size))
        switch PhoneHTTP.range(request.header("range"), size: size) {
        case .whole:
            break
        case .partial(let range):
            response.status = 206
            response.headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
            response.body = .file(url, offset: range.lowerBound, length: range.upperBound - range.lowerBound + 1)
        case .unsatisfiable:
            return .error(416, "range_not_satisfiable", "The range is outside the file.", headers: ["Content-Range": "bytes */\(size)"])
        }
        return response
    }

    // MARK: Activity

    private func activity(_ request: HTTPRequest, week: Bool) throws -> PhoneResponse {
        guard let text = request.query[week ? "start" : "date"] else { throw PhoneRequestError.bad("\(week ? "start" : "date") is required (YYYY-MM-DD).") }
        let date = try day(text)
        let days = week ? ActivityLogic.week(containing: date) : [ActivityLogic.day(containing: date)]
        let range = days.first!.lowerBound..<days.last!.upperBound
        let blocks = try store.blocks(in: range)
        let rules = try store.rules(), projects = try store.projects(), directory = try store.ticketDirectory()
        let totals = PhoneActivityTotals(
            activeSeconds: ActivityLogic.activeSeconds(blocks, in: range),
            projects: ActivityLogic.projectTotals(blocks, in: range, rules: rules, projects: projects).map(Self.total),
            categories: ActivityLogic.categoryTotals(blocks, in: range).map(Self.total),
            apps: ActivityLogic.appTotals(blocks, in: range).map(Self.total),
            branches: ActivityLogic.workTotals(blocks, in: range, rules: rules, projects: projects).map {
                PhoneWorkTotal(name: $0.name, repo: $0.repo, ticket: $0.ticket, project: $0.project?.name,
                               projectGuessed: $0.project?.guessed ?? false, seconds: $0.seconds)
            },
            tickets: ActivityLogic.ticketTotals(blocks, in: range, rules: rules, projects: projects).map {
                PhoneTicketTotal(ticket: $0.ticket, title: directory.titles[$0.ticket], url: directory.url(for: $0.ticket)?.absoluteString,
                                 branches: $0.branches, project: $0.project?.name, projectGuessed: $0.project?.guessed ?? false, seconds: $0.seconds)
            })
        let rows = ActivityLogic.timelineRows(blocks.filter { !$0.key.idle })
        return .json(PhoneActivity(
            from: range.lowerBound, to: range.upperBound, totals: totals,
            days: days.map { PhoneDayTotal(date: ActivityLogic.dateText($0.lowerBound), activeSeconds: ActivityLogic.activeSeconds(blocks, in: $0)) },
            blocks: rows.prefix(Self.maxBlocks).map { Self.block($0, rules: rules, projects: projects) }))
    }

    private static func total(_ total: ActivityLogic.Total) -> PhoneTotal { PhoneTotal(name: total.name, seconds: total.seconds) }

    /// A block as the phone sees it. A redacted block keeps only what its redaction leaves, whatever the row still holds.
    static func block(_ block: ActivityBlock, rules: [ProjectRule], projects: [Project]) -> PhoneBlock {
        let key = block.key
        let project = ActivityLogic.project(for: block, rules: rules, projects: projects)?.name
        var result = PhoneBlock(id: block.id, start: block.start, end: block.end, app: key.redaction == .other ? nil : key.appName,
                                category: block.category?.rawValue, project: project,
                                projectGuessed: project != nil && ActivityLogic.projectIsGuessed(block, rules: rules), redaction: key.redaction?.rawValue)
        guard key.redaction == nil else { return result }
        result.title = block.title
        result.url = key.url
        result.repo = key.repo.map { _ in ActivityLogic.repoLabel(key) }
        result.branch = key.branch
        result.ticket = ActivityLogic.ticket(of: key)
        result.summary = block.aiDescription
        result.excerpt = block.claudePrompt ?? block.typedExcerpt
        return result
    }

    private func day(_ text: String) throws -> Date {
        do { return try MCPServer.date(text) } catch { throw PhoneRequestError.bad("Dates are YYYY-MM-DD, not \(text).") }
    }

    // MARK: GitHub

    private func github(error: String? = nil) throws -> PhoneResponse {
        let enabled = features().githubEnabled
        let prs = enabled ? try store.githubPRs() : [:]
        return .json(PhoneGitHub(enabled: enabled, refreshedAt: enabled ? try store.githubFetched() : nil,
                                 prs: Dictionary(uniqueKeysWithValues: GitHubKind.allCases.map { kind in
                                     (kind.rawValue, (prs[kind] ?? []).map(Self.pullRequest))
                                 }), error: error))
    }

    private func refresh() async -> PhoneResponse {
        guard features().githubEnabled else { return .error(409, "github_disabled", "GitHub is turned off in the Mac app.") }
        let error = await refreshGitHub()
        return (try? github(error: error)) ?? .error(500, "internal", "The Mac could not read its data.")
    }

    static func pullRequest(_ pr: GitHubPR) -> PhonePR {
        PhonePR(url: pr.url, number: pr.number, title: pr.title, repo: pr.repo, isDraft: pr.isDraft, state: pr.state.rawValue,
                updated: pr.updated, review: pr.review?.rawValue, checks: pr.checks.rawValue, author: pr.author, additions: pr.additions,
                deletions: pr.deletions, comments: pr.comments, labels: pr.labels, ticket: pr.ticket)
    }

    // MARK: Chat

    private func chat(_ request: HTTPRequest) throws -> PhoneRoute {
        guard let body = try? PhoneAPI.decoder.decode(PhoneChatRequest.self, from: request.body) else {
            throw PhoneRequestError.bad("The body is not a chat request.")
        }
        guard let question = body.messages.last, question.role == "user", !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.messages.count <= Self.maxChatMessages, body.messages.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.text.count <= Self.maxChatCharacters }) else {
            throw PhoneRequestError.bad("Send up to \(Self.maxChatMessages) messages ending with a question from the user.")
        }
        let stamp = now()
        let history = body.messages.dropLast().map { ChatMessage(id: 0, role: $0.role == "user" ? .user : .assistant, text: $0.text, toolNote: nil, created: stamp) }
        return .chat(PhoneChatJob(scope: try scope(body.scope), history: history, question: question.text))
    }

    func scope(_ scope: PhoneChatScope) throws -> ChatScope {
        switch scope.kind {
        case "general": return .general
        case "meeting", "notes":
            guard let id = scope.meetingId, let meeting = try store.meeting(id: id) else { throw PhoneRequestError.notFound("No meeting with that id.") }
            return scope.kind == "meeting" ? .meeting(id, label: meeting.title) : .notes(id, label: meeting.title)
        case "activity_block":
            guard let id = scope.blockId, let from = scope.from, let to = scope.to, from < to else {
                throw PhoneRequestError.bad("An activity_block scope needs blockId, from and to.")
            }
            let found = try store.blocks(in: from..<to).first { $0.id == id }
            return .block(id, from: from, to: to, label: found.flatMap { ChatScope.block($0).label })
        case "day", "week":
            guard let text = scope.date else { throw PhoneRequestError.bad("A \(scope.kind) scope needs a date.") }
            return scope.kind == "day" ? .day(containing: try day(text)) : .week(containing: try day(text))
        default:
            throw PhoneRequestError.bad("Unknown scope kind \(scope.kind).")
        }
    }
}

struct PhoneRequestError: Error {
    let status: Int
    let code: String
    let message: String

    static func bad(_ message: String) -> Self { Self(status: 400, code: "bad_request", message: message) }
    static func notFound(_ message: String) -> Self { Self(status: 404, code: "not_found", message: message) }
}

extension MeetingStore {
    /// The speakers of each meeting in order of their label, with the name the user gave them.
    func speakerLabels(of ids: [Int64]) throws -> [Int64: [(speaker: Speaker, name: String?)]] {
        guard !ids.isEmpty else { return [:] }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try read {
            try db.query("""
                SELECT DISTINCT t.meeting_id, t.speaker, s.name FROM transcript_segments t
                LEFT JOIN speakers s ON s.meeting_id = t.meeting_id AND s.label = t.speaker
                WHERE t.speaker IS NOT NULL AND t.meeting_id IN (\(marks))
                """, ids.map { $0 as SQLValue? }) { row in (row.int64(0), Speaker(rawValue: row.string(1)), row.optionalString(2)) }
        }
        var result: [Int64: [(speaker: Speaker, name: String?)]] = [:]
        for (id, speaker, name) in rows { if let speaker { result[id, default: []].append((speaker, name)) } }
        return result.mapValues { $0.sorted { Self.rank($0.speaker) < Self.rank($1.speaker) } }
    }

    private static func rank(_ speaker: Speaker) -> Int {
        switch speaker {
        case .you: return 0
        case .others: return 1
        case .numbered(let number): return 1 + number
        }
    }
}
