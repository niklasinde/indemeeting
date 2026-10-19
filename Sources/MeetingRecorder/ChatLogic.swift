import Foundation

enum ChatRole: String {
    case user
    case assistant
    /// A lookup the assistant made; the message holds no text, only a note of what was searched.
    case tool
}

/// What a chat is about. A general chat has no subject and may look at everything.
struct ChatScope: Equatable {
    enum Kind: String {
        case general
        case meeting
        case notes
        case activityBlock = "activity_block"
        case day
        case week
    }

    var kind = Kind.general
    /// The meeting (for `meeting` and `notes`) or the activity block.
    var id: Int64?
    var from: Date?
    var to: Date?
    /// What the subject was called when the chat started, for when it can no longer be looked up.
    var label: String?

    static let general = ChatScope()

    static func meeting(_ id: Int64, label: String?) -> ChatScope { ChatScope(kind: .meeting, id: id, label: label) }
    static func notes(_ id: Int64, label: String?) -> ChatScope { ChatScope(kind: .notes, id: id, label: label) }

    static func block(_ id: Int64, from: Date, to: Date, label: String?) -> ChatScope {
        ChatScope(kind: .activityBlock, id: id, from: from, to: to, label: label)
    }

    static func block(_ block: ActivityBlock) -> ChatScope {
        .block(block.id, from: block.start, to: block.end,
               label: block.start.formatted(date: .omitted, time: .shortened) + " " + (block.title ?? "Activity"))
    }

    static func day(containing date: Date, calendar: Calendar = .current) -> ChatScope {
        let range = ActivityLogic.day(containing: date, calendar: calendar)
        return ChatScope(kind: .day, from: range.lowerBound, to: range.upperBound)
    }

    static func week(containing date: Date, calendar: Calendar = .current) -> ChatScope {
        let days = ActivityLogic.week(containing: date, calendar: calendar)
        return ChatScope(kind: .week, from: days.first?.lowerBound, to: days.last?.upperBound)
    }

    var isGeneral: Bool { kind == .general }
    var meetingID: Int64? { kind == .meeting || kind == .notes ? id : nil }
    var isAboutMeeting: Bool { meetingID != nil }
    var range: Range<Date>? { from.flatMap { from in to.map { from..<$0 } } }

    /// The text of the chip that names the subject.
    func chipTitle(meetingTitle: String? = nil, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch kind {
        case .general: return "Everything"
        case .meeting: return meetingTitle ?? label ?? "Meeting"
        case .notes: return "Notes \u{00B7} " + (meetingTitle ?? label ?? "Meeting")
        case .activityBlock: return label ?? "Activity"
        case .day:
            guard let from else { return "Day" }
            if calendar.isDate(from, inSameDayAs: now) { return "Today" }
            return from.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week:
            guard let from else { return "Week" }
            return "Week \(calendar.component(.weekOfYear, from: from))"
        }
    }
}

struct Chat: Equatable, Identifiable {
    let id: Int64
    var title: String
    let created: Date
    var updated: Date
    var scope: ChatScope
}

struct ChatMessage: Equatable, Identifiable {
    let id: Int64
    let role: ChatRole
    var text: String
    var toolNote: String?
    let created: Date
}

/// How much of the model's context each part of a conversation may take, measured in characters because Swedish text
/// takes about three characters a token.
struct ChatBudget: Equatable {
    static let charactersPerToken = 3

    let contextSize: Int

    init(contextSize: Int) { self.contextSize = contextSize > 1000 ? contextSize : 4096 }

    private func share(_ percent: Int) -> Int { contextSize * Self.charactersPerToken * percent / 100 }

    /// The overview of the subject in the instructions.
    var overview: Int { min(share(22), 3000) }
    /// One tool result, about 1,500 tokens on a 4,096-token window.
    var toolOutput: Int { min(share(37), 4500) }
    /// The recap of earlier turns that seeds a fresh session.
    var recap: Int { min(share(18), 2000) }
    /// What one chunk of transcript may be when a long meeting is read in parts.
    var chunk: Int { ProcessingLogic.chunkCharacters(contextSize: contextSize) }
}

enum ChatLogic {
    // MARK: Titles

    static let titleLimit = 40

    /// The first words of the question, cut at a word boundary, for when the model gives no title.
    static func fallbackTitle(_ question: String) -> String {
        let text = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count > titleLimit else { return text.isEmpty ? "New chat" : text }
        let cut = String(text.prefix(titleLimit))
        let words = cut.split(separator: " ", omittingEmptySubsequences: false)
        let kept = text.dropFirst(titleLimit).first == " " || words.count < 2 ? cut : words.dropLast().joined(separator: " ")
        return kept.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// A title the model proposed, without quotes, line breaks and a closing full stop; nil when it is unusable.
    static func cleanTitle(_ proposed: String) -> String? {
        let line = proposed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var title = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}*#. \t"))
        while title.last == "." { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard title.count >= 3 else { return nil }
        return title.count > 60 ? String(title.prefix(60)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : title
    }

    // MARK: Rolling context

    /// The latest turns, newest kept first, as plain text that seeds a fresh session when the old one is full or a
    /// stored chat is reopened. Each message is cut short; the oldest turns are dropped to fit `maxCharacters`.
    static func recap(_ messages: [ChatMessage], maxCharacters: Int, perMessage: Int = 400) -> String? {
        var lines: [String] = []
        var used = 0
        for message in messages.reversed() where message.role != .tool && !message.text.isEmpty {
            let line = (message.role == .user ? "User: " : "Assistant: ") + trim(message.text, maxCharacters: perMessage, marker: "\u{2026}")
            guard used + line.count + 1 <= maxCharacters else { break }
            lines.insert(line, at: 0)
            used += line.count + 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// `text` cut to `maxCharacters` at the last line break (or word) before the limit, followed by `marker`.
    static func trim(_ text: String, maxCharacters: Int, marker: String = "\n[Cut]") -> String {
        guard text.count > maxCharacters else { return text }
        let head = String(text.prefix(maxCharacters))
        let cut = head.lastIndex(where: \.isNewline) ?? head.lastIndex(of: " ")
        let kept = cut.map { String(head[..<$0]) }.flatMap { $0.count > maxCharacters / 2 ? $0 : nil } ?? head
        return kept + marker
    }

    // MARK: Citations

    static let seekScheme = "meetingrecorder-seek"
    static let meetingScheme = "meetingrecorder-meeting"

    /// Seconds for "12:41" (minutes and seconds), "1:02:03", or plain seconds.
    static func seconds(from text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, (1...3).contains(numbers.count), numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    /// Timestamps in an answer about one meeting, as links that seek the recording.
    static func linkifiedTimestamps(_ text: String) -> String {
        let pattern = #"(?<![\d:/\w])(\d{1,2}:\d{2}(?::\d{2})?)(?!\d|\w|:\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: result), let seconds = seconds(from: String(result[range])) else { continue }
            result.replaceSubrange(range, with: "[\(result[range])](\(seekScheme)://\(Int(seconds)))")
        }
        return result
    }

    static func seekTarget(_ url: URL) -> TimeInterval? {
        url.scheme == seekScheme ? url.host.flatMap(Double.init) : nil
    }

    static func meetingTarget(_ url: URL) -> Int64? {
        url.scheme == meetingScheme ? url.host.flatMap(Int64.init) : nil
    }

    // MARK: Tool notes

    /// What a lookup is shown as: a first line saying what was done, then the meetings or lines it returned.
    static func note(tool: String, arguments: [String: Any], output: String) -> String {
        func text(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func number(_ key: String) -> String? { (arguments[key] as? NSNumber).map { "\($0)" } ?? text(key) }
        let summary: String
        switch tool {
        case "search_meetings": summary = "Searched meetings for \u{201C}\(text("query") ?? "")\u{201D}"
        case "get_meeting": summary = "Read " + (meetingTitle(inOutput: output).map { "\u{201C}\($0)\u{201D}" } ?? "a meeting")
        case "recent_meetings": summary = "Looked at the latest meetings"
        case "meetings_on": summary = "Looked up meetings on \(text("date") ?? "a day")"
        case "open_action_items": summary = "Looked up open action items"
        case "activity_on": summary = "Looked at the activity on \(text("date") ?? "today")"
        case "activity_context": summary = "Looked at the last \(number("hours") ?? "8") hours of activity"
        case "time_report": summary = "Read the time report" + (text("week_start").map { " for the week of \($0)" } ?? " for this week")
        case "search_in_meeting": summary = "Searched this meeting for \u{201C}\(text("query") ?? "")\u{201D}"
        case "read_transcript": summary = "Read the transcript " + [text("from"), text("to")].compactMap { $0 }.joined(separator: "\u{2013}")
        case "get_notes": summary = "Read the notes"
        case "scan_transcript": summary = "Went through the transcript for \u{201C}\(text("focus") ?? "")\u{201D}"
        case "block_details": summary = "Looked at this activity"
        case "blocks_in_range": summary = "Looked at activity" + ([text("from"), text("to")].compactMap { $0 }.isEmpty ? "" : " " + [text("from"), text("to")].compactMap { $0 }.joined(separator: "\u{2013}"))
        default: summary = "Used \(tool)"
        }
        let listed = tool == "search_in_meeting" ? "[" : "- id "
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix(listed) }
        let details = lines.prefix(tool == "get_meeting" ? 1 : 8).map { trim($0, maxCharacters: 140, marker: "\u{2026}") }
        return ([summary] + details).joined(separator: "\n")
    }

    private static func meetingTitle(inOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first.flatMap { line in
            let parts = line.components(separatedBy: " \u{00B7} ")
            return parts.count >= 3 ? parts[2] : nil
        }
    }

    static func noteSummary(_ note: String) -> String { note.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? note }

    static func noteDetails(_ note: String) -> [String] { Array(note.split(separator: "\n").dropFirst().map(String.init)) }

    /// The meetings a note's lines name, for opening them.
    static func meetingIDs(inNote note: String) -> [Int64] {
        var seen = Set<Int64>()
        return noteDetails(note).compactMap { line -> Int64? in
            guard line.hasPrefix("- id "), let id = Int64(line.dropFirst(5).prefix { $0.isNumber }), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    // MARK: Transcript lookups

    static func transcriptLine(_ segment: TranscriptSegment, names: SpeakerNames, language: MeetingLanguage) -> String {
        "[\(LibraryLogic.durationText(segment.start))] " + (segment.speaker.map { names.name(of: $0, in: language) + ": " } ?? "") + segment.text
    }

    /// The lines that contain the most of the query's words (as word prefixes), best first and capped by `limit`,
    /// then in the order they were said.
    static func search(_ segments: [TranscriptSegment], query: String, names: SpeakerNames, language: MeetingLanguage,
                       limit: Int = 8, maxCharacters: Int) -> [String] {
        let words = foldedWords(query)
        guard !words.isEmpty else { return [] }
        let scored = segments.enumerated().compactMap { index, segment -> (index: Int, score: Int)? in
            let lineWords = foldedWords(segment.text)
            let score = words.filter { word in lineWords.contains { $0.hasPrefix(word) } }.count
            return score > 0 ? (index, score) : nil
        }
        let best = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(limit).sorted { $0.index < $1.index }
        var used = 0
        var lines: [String] = []
        for match in best {
            let line = trim(transcriptLine(segments[match.index], names: names, language: language), maxCharacters: 320, marker: "\u{2026}")
            guard used + line.count + 1 <= maxCharacters else { break }
            lines.append(line)
            used += line.count + 1
        }
        return lines
    }

    /// The lines that start in `from..<to` seconds, cut to `maxCharacters`.
    static func excerpt(_ segments: [TranscriptSegment], from: TimeInterval, to: TimeInterval, names: SpeakerNames,
                        language: MeetingLanguage, maxCharacters: Int) -> String {
        let lines = segments.filter { $0.start >= from && $0.start < to }.map { transcriptLine($0, names: names, language: language) }
        return trim(lines.joined(separator: "\n"), maxCharacters: maxCharacters)
    }

    private static func foldedWords(_ text: String) -> [String] {
        let words = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        let content = words.filter { !stopWords.contains($0) }
        return content.isEmpty ? words : content
    }

    private static let stopWords: Set<String> = [
        "the", "and", "what", "who", "when", "where", "why", "how", "was", "were", "are", "about", "said", "say", "did", "does",
        "this", "that", "with", "for", "from", "meeting", "something", "anything", "any", "there", "which", "have", "has", "had",
        "och", "att", "det", "som", "ett", "pa", "av", "for", "med", "till", "ar", "var", "vad", "vem", "nar", "hur", "sa",
        "sades", "om", "den", "de", "vi", "jag", "du", "har", "hade", "mote", "motet", "nagot", "vilka", "finns", "fanns",
    ]

    /// The transcript lines to show the model next to a question about a meeting, and the lookup note for them.
    static func prefetch(_ question: String, content: MeetingContent, maxCharacters: Int) -> (lines: [String], note: String)? {
        let lines = search(content.segments, query: question, names: content.names, language: content.meeting.language ?? .current,
                           limit: 6, maxCharacters: maxCharacters)
        guard !lines.isEmpty else { return nil }
        let shown = trim(question.split(whereSeparator: \.isWhitespace).joined(separator: " "), maxCharacters: 60, marker: "\u{2026}")
        return (lines, note(tool: "search_in_meeting", arguments: ["query": shown], output: lines.joined(separator: "\n")))
    }

    // MARK: Overviews

    /// The title, time, summary, action items and notes of a meeting, in that order of importance, within `maxCharacters`.
    static func overview(of content: MeetingContent, maxCharacters: Int) -> String {
        let meeting = content.meeting
        let language = meeting.language ?? .current
        var header = "Meeting \u{201C}\(meeting.title)\u{201D} (id \(meeting.id)), \(ActivityLogic.dateText(meeting.created)) "
            + meeting.created.formatted(date: .omitted, time: .shortened)
        if let duration = meeting.duration { header += ", \(ActivityLogic.hoursText(duration))" }
        header += ", spoken language \(language.englishName)"
        let speakers = Set(content.segments.compactMap(\.speaker)).sorted { $0.rawValue < $1.rawValue }
            .map { content.names.name(of: $0, in: language) }
        if !speakers.isEmpty { header += ". Speakers: " + speakers.joined(separator: ", ") }
        var sections = [header]
        let items = content.summary.actionItems
        if !items.isEmpty {
            sections.append("Action items:\n" + items.map { "- " + ($0.owner.map { "\($0): " } ?? "") + $0.task + ($0.done ? " (done)" : "") }
                .joined(separator: "\n"))
        }
        for section in content.summary.sections {
            sections.append(section.heading + ":\n" + section.lines.map { "- " + $0.text }.joined(separator: "\n"))
        }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { sections.append("The user\u{2019}s notes:\n" + notes) }
        if content.summary.isEmpty { sections.append("There is no summary; use the tools to read the transcript.") }
        return fit(sections, maxCharacters: maxCharacters)
    }

    /// Sections joined while they fit; the first is always kept and a section that is too long is cut.
    static func fit(_ sections: [String], maxCharacters: Int) -> String {
        var result = ""
        for section in sections {
            let remaining = maxCharacters - result.count - (result.isEmpty ? 0 : 2)
            guard remaining > 80 else { break }
            result += (result.isEmpty ? "" : "\n\n") + trim(section, maxCharacters: remaining, marker: "\n[Cut]")
        }
        return result
    }

    static func blockLine(_ block: ActivityBlock) -> String {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let key = block.key
        var parts = ["\(time(block.start))\u{2013}\(time(block.end)) (\(ActivityLogic.hoursText(block.duration)))"]
        if key.idle { return parts[0] + " \u{00B7} idle" }
        parts += [key.appName, key.windowTitle, key.url, key.repo.map { _ in ActivityLogic.repoLabel(key) }, key.branch.map { "branch \($0)" },
                  key.ticket, block.claudeFocusSession.map { "Claude: \($0.title)" }, block.aiDescription].compactMap { $0 }
        return "- " + parts.joined(separator: " \u{00B7} ")
    }

    static func blockDetails(_ block: ActivityBlock) -> String {
        var lines = [blockLine(block)]
        if let category = block.category { lines.append("Category: \(category.rawValue)") }
        for session in block.backgroundSessions { lines.append("Claude session in the background: \(session.title)") }
        if let prompt = block.claudePrompt, !prompt.isEmpty { lines.append("Last thing the user asked Claude: \(prompt)") }
        if let excerpt = block.typedExcerpt, !excerpt.isEmpty { lines.append("Text around the cursor: \(excerpt)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Suggestions

    struct Suggestion: Equatable {
        let label: String
        let prompt: String
    }

    /// Prompts offered under an empty chat. Scoped ones ask for a reply in the meeting's language.
    static func suggestions(for scope: ChatScope, language: MeetingLanguage = .current) -> [Suggestion] {
        let reply = " Reply in \(language.englishName)."
        switch scope.kind {
        case .general:
            return ["What did we decide in the last standup?", "What did I work on today?", "Which action items are open for me?", "Summarise my week"]
                .map { Suggestion(label: $0, prompt: $0) }
        case .meeting:
            return [Suggestion(label: "Action items for me", prompt: "List the action items that are mine from this meeting. Use scan_transcript for the focus \u{201C}action items and tasks\u{201D}." + reply),
                    Suggestion(label: "Decisions", prompt: "List the decisions made in this meeting. Use scan_transcript for the focus \u{201C}decisions\u{201D}." + reply),
                    Suggestion(label: "Open questions", prompt: "List the open questions and unresolved issues from this meeting. Use scan_transcript for the focus \u{201C}open questions\u{201D}." + reply),
                    Suggestion(label: "Draft follow-up email", prompt: "Write a short follow-up email to the participants of this meeting with the decisions and action items." + reply)]
        case .notes:
            return [Suggestion(label: "Clean up", prompt: "Rewrite my notes for this meeting as clean, well-structured notes. Keep every fact." + reply),
                    Suggestion(label: "Turn into action items", prompt: "Turn my notes for this meeting into a list of action items with owners where the notes name them." + reply)]
        case .activityBlock:
            return [Suggestion(label: "What was I doing here?", prompt: "What was I doing in this block of activity?"),
                    Suggestion(label: "Which ticket is this?", prompt: "Which ticket does this activity belong to? Say so if none can be told."),
                    Suggestion(label: "Write a worklog entry", prompt: "Write a concise Jira-style worklog entry for this block of activity, one or two sentences in the past tense.")]
        case .day, .week:
            let unit = scope.kind == .day ? "day" : "week"
            return [Suggestion(label: "What did I do?", prompt: "Summarise what I did this \(unit)."),
                    Suggestion(label: "Write a worklog entry", prompt: "Write a concise Jira-style worklog for this \(unit), one line per ticket or project with the time spent.")]
        }
    }
}

// MARK: Instructions and command line

extension ChatLogic {
    static func instructions(scope: ChatScope, overview: String?, recap: String?, now: Date, calendar: Calendar = .current) -> String {
        let today = now.formatted(Date.FormatStyle(calendar: calendar).weekday(.wide)) + " " + ActivityLogic.dateText(now)
        var text = """
            You are the assistant inside MeetingRecorder on the user\u{2019}s Mac. You answer questions about the user\u{2019}s own \
            meetings and tracked work activity. Today is \(today). \
            Answer only from what the tools and the overview tell you; look things up with the tools instead of guessing. \
            When they hold nothing relevant, say so plainly. Never invent meetings, people, decisions, times or numbers. \
            Reply in the language of the user\u{2019}s latest message (Swedish or English). Be concise and use Markdown lists \
            for several items. Summarise instead of copying long lists; for activity name the main projects, tickets and \
            apps with the time spent.
            """
        switch scope.kind {
        case .general:
            text += " Name the title and date of the meeting an answer comes from. To find meetings on a date use meetings_on, "
                + "then get_meeting. For open action items use open_action_items; items owned by the user name \u{201C}You\u{201D}, "
                + "\u{201C}Du\u{201D} or the user\u{2019}s first name."
        case .meeting:
            text += " This chat is about one meeting; its overview follows. The overview has no times and no exact wording. "
                + "Before you answer about who said something, when, or any detail beyond the overview, call search_in_meeting "
                + "(specific topics) or scan_transcript (broad questions such as decisions, action items, open questions, "
                + "a follow-up); read_transcript reads a stretch of time. Cite the speaker and time from the tool result as "
                + "(name, mm:ss). Never state a speaker or a time that no tool result gave you."
        case .notes:
            text += " This chat is about the notes the user wrote for one meeting; the overview follows. When asked to rewrite or "
                + "restructure them, keep every fact and write only the result. Use search_in_meeting and read_transcript to check a detail."
        case .activityBlock:
            text += " This chat is about one block of tracked activity, described below. Say plainly when something cannot be told from "
                + "it. A worklog entry is one or two concise sentences in the past tense about the work done, naming the ticket when known."
        case .day, .week:
            text += " This chat is about one \(scope.kind == .day ? "day" : "week") of tracked activity, summarised below. Use blocks_in_range "
                + "for details. A worklog is one line per ticket or project with the time spent."
        }
        if let overview { text += "\n\nOverview:\n" + overview }
        if let recap { text += "\n\nThe conversation so far, which the user may refer to:\n" + recap }
        return text
    }

    struct ChatJob: Equatable {
        let question: String
        var meeting: Int64?
        var day: String?
    }

    /// `--chat "<question>" [--meeting <id>] [--day <YYYY-MM-DD>]`.
    static func chatArguments(_ arguments: [String]) -> ChatJob? {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let question = value("--chat") else { return nil }
        return ChatJob(question: question, meeting: value("--meeting").flatMap { Int64($0) }, day: value("--day"))
    }
}

// MARK: Chat list and Markdown

extension ChatLogic {
    /// The summary notice for an unavailable model, worded for the chat.
    static func unavailableNotice(_ notice: SummaryNotice) -> SummaryNotice {
        var chat = notice
        for prefix in ["No summary yet \u{2014} ", "No summary \u{2014} "] where chat.title.hasPrefix(prefix) {
            chat.title = String(chat.title.dropFirst(prefix.count))
        }
        chat.title = chat.title.prefix(1).uppercased() + chat.title.dropFirst()
        chat.message = chat.message.replacingOccurrences(of: ", then click Summarise", with: "")
            .replacingOccurrences(of: "Your transcript is summarised by itself once the download finishes.",
                                  with: "Chat works by itself once the download finishes.")
        return chat
    }
}

extension ChatLogic {
    enum GroupKey: Hashable {
        case general
        case activity
        case meeting(Int64)
    }

    struct ChatGroup: Equatable {
        let key: GroupKey
        let title: String
        let chats: [Chat]
    }

    /// Chats about one meeting are listed together under its title; the rest under Activity and General. Groups and the
    /// chats in them come newest first.
    static func groups(_ chats: [Chat], meetingTitles: [Int64: String]) -> [ChatGroup] {
        func key(_ chat: Chat) -> GroupKey {
            switch chat.scope.kind {
            case .general: return .general
            case .meeting, .notes: return chat.scope.id.map(GroupKey.meeting) ?? .general
            case .activityBlock, .day, .week: return .activity
            }
        }
        let sorted = chats.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id > $1.id }
        let grouped = Dictionary(grouping: sorted, by: key)
        return grouped.map { key, chats in
            let title: String
            switch key {
            case .general: title = "General"
            case .activity: title = "Activity"
            case .meeting(let id): title = meetingTitles[id] ?? chats.compactMap(\.scope.label).first ?? "Meeting"
            }
            return ChatGroup(key: key, title: title, chats: chats)
        }.sorted { ($0.chats.first?.updated ?? .distantPast) > ($1.chats.first?.updated ?? .distantPast) }
    }

    enum Block: Equatable {
        case heading(String)
        case bullet(level: Int, text: String)
        case task(level: Int, done: Bool, text: String)
        case numbered(String, text: String)
        case paragraph(String)
        case code(String)
        case table([[String]])
        case image(alt: String, url: String)
    }

    /// The block structure of Markdown: headings, bullets (indented by two spaces a level), task list items, numbered items,
    /// fenced code, tables, images on a line of their own and paragraphs. Inline Markdown stays in the text.
    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [[String]] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.table(table)) }
            paragraph = []
            table = []
        }
        for raw in markdown.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
            } else if code != nil {
                code?.append(raw)
            } else if line.isEmpty {
                flush()
            } else if line.hasPrefix("|"), line.count > 1, paragraph.isEmpty {
                if let cells = tableCells(line) { table.append(cells) } else if table.isEmpty { paragraph.append(line) }
            } else if line.hasPrefix("#"), let heading = marked(line, after: { $0 == "#" }) {
                flush()
                blocks.append(.heading(heading))
            } else if let image = image(line) {
                flush()
                blocks.append(image)
            } else if let bullet = ["- ", "* ", "\u{2022} "].first(where: line.hasPrefix) {
                flush()
                let text = String(line.dropFirst(bullet.count))
                if let done = ["[ ] ": false, "[x] ": true, "[X] ": true].first(where: { text.hasPrefix($0.key) }) {
                    blocks.append(.task(level: indent / 2, done: done.value, text: String(text.dropFirst(4))))
                } else {
                    blocks.append(.bullet(level: indent / 2, text: text))
                }
            } else if let digits = Optional(line.prefix { $0.isNumber }), !digits.isEmpty,
                      let rest = marked(String(line.dropFirst(digits.count)), after: { $0 == "." || $0 == ")" }) {
                flush()
                blocks.append(.numbered(String(digits), text: rest))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// The cells of a table row; nil for the `---|---` separator, which is dropped.
    private static func tableCells(_ line: String) -> [String]? {
        let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } ? nil : cells
    }

    private static func image(_ line: String) -> Block? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let close = line.range(of: "]("),
              !line[close.upperBound...].dropLast().contains(")") else { return nil }
        return .image(alt: String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]), url: String(line[close.upperBound...].dropLast()))
    }
}

private func marked(_ line: String, after isMark: (Character) -> Bool) -> String? {
    let rest = line.drop(while: isMark)
    guard rest.count < line.count, rest.first == " " else { return nil }
    return rest.trimmingCharacters(in: .whitespaces)
}
