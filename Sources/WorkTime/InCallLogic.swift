import Foundation

/// A ticket, pull request or known name heard in a call. Pull request keys are `owner/repo#123`, or `#123` while the
/// repository is not known.
struct SpottedEntity: Equatable, Hashable {
    enum Kind: String, CaseIterable { case ticket, pullRequest = "pr", name }

    let kind: Kind
    let key: String
    var line: String = ""
    var at: TimeInterval = 0

    var id: String { "\(kind.rawValue):\(key)" }

    var pullRequest: (repo: String?, number: Int)? {
        guard kind == .pullRequest, let hash = key.lastIndex(of: "#"), let number = Int(key[key.index(after: hash)...]) else { return nil }
        let repo = String(key[..<hash])
        return (repo.isEmpty ? nil : repo, number)
    }

    var label: String {
        guard let pr = pullRequest else { return key }
        return (pr.repo.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "PR ") + "#\(pr.number)"
    }

    static func pullRequest(repo: String?, number: Int, line: String = "", at: TimeInterval = 0) -> SpottedEntity {
        SpottedEntity(kind: .pullRequest, key: "\(repo ?? "")#\(number)", line: line, at: at)
    }
}

/// What the spotter knows: Jira project keys, how a Jira site's name sounds (`kvidly` for quiddly.atlassian.net),
/// repositories (`owner/repo`) and other names such as projects and customers.
struct InCallVocabulary: Equatable {
    var ticketPrefixes: Set<String> = []
    /// Phonetic key of a spoken word to the ticket prefix it stands for.
    var aliases: [String: String] = [:]
    var repos: [String] = []
    var names: [String] = []

    init(ticketPrefixes: Set<String> = [], sites: [String: String] = [:], repos: [String] = [], names: [String] = []) {
        self.ticketPrefixes = ticketPrefixes.union(sites.keys)
        self.repos = repos
        self.names = names
        for (prefix, site) in sites.sorted(by: { $0.key < $1.key }) {
            guard let word = site.split(separator: ".").first.map(String.init), Self.spells(prefix, in: word) else { continue }
            aliases[EntitySpotter.phonetic(word)] = aliases[EntitySpotter.phonetic(word)] ?? prefix
        }
    }

    /// The repository `name` stands for: an `owner/repo` as is, a known repository by its name, nil otherwise.
    func repo(_ name: String) -> String? {
        if name.contains("/") { return name }
        return repos.first { $0.split(separator: "/").last?.lowercased() == name.lowercased() }
    }

    /// Whether the letters of `prefix` appear in order in `word`: QDLY in quiddly.
    static func spells(_ prefix: String, in word: String) -> Bool {
        var rest = Substring(word.lowercased())
        for letter in prefix.lowercased() {
            guard let found = rest.firstIndex(of: letter) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}

enum EntitySpotter {
    /// Upper-case words with a number that are not tickets.
    static let notTickets: Set<String> = ["UTF", "ISO", "COVID", "SHA", "MP", "GPT", "RFC", "TLS", "SSL", "HTTP", "UTC", "GMT", "CET",
                                          "CEST", "AES", "RSA", "PDF", "WCAG", "IPV", "USB", "HDMI", "MD", "ES", "PS", "LTE", "TOP"]
    private static let pullWords: Set<String> = ["pr", "prs", "pren", "prn", "pullrequest", "pullrequesten"]
    private static let fillers: Set<String> = ["en", "n", "s", "nummer", "number", "nr", "no", "num"]

    /// The tickets, pull requests and names in one line, in the order they are said. `repoContext` is the repository
    /// talked about just before, for a bare `PR 12`.
    static func spot(_ text: String, at: TimeInterval = 0, vocabulary: InCallVocabulary, repoContext: String? = nil) -> [SpottedEntity] {
        var found: [(offset: Int, entity: SpottedEntity)] = []
        func add(_ offset: Int, _ kind: SpottedEntity.Kind, _ key: String) {
            found.append((offset, SpottedEntity(kind: kind, key: key, line: text, at: at)))
        }
        var masked = text
        for match in matches(#"github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/pull/([0-9]+)"#, in: text, options: .caseInsensitive) {
            add(match.offset, .pullRequest, "\(match.groups[0])/\(match.groups[1])#\(match.groups[2])")
            masked = mask(match.range, in: masked)
        }
        let names = spotNames(masked, vocabulary: vocabulary)
        let lineRepo = names.lazy.compactMap { vocabulary.repo($0.name) }.first ?? repoContext
        for match in matches(#"(?<![\w/.-])([A-Za-z0-9-]+/)?([A-Za-z0-9._-]*[A-Za-z][A-Za-z0-9._-]*)#([1-9][0-9]{0,5})\b"#, in: masked) {
            let owner = match.groups[0], name = match.groups[1]
            guard let repo = owner.isEmpty ? vocabulary.repo(name) : owner + name else { continue }
            add(match.offset, .pullRequest, "\(repo)#\(match.groups[2])")
            masked = mask(match.range, in: masked)
        }
        if let lineRepo {
            for match in matches(#"(?<![\w/#])#([1-9][0-9]{1,5})\b"#, in: masked) {
                add(match.offset, .pullRequest, "\(lineRepo)#\(match.groups[0])")
                masked = mask(match.range, in: masked)
            }
        }
        for match in matches(#"(?<![A-Za-z0-9])([A-Z][A-Z0-9]{1,9})-([1-9][0-9]{0,5})(?![0-9])"#, in: masked)
        where vocabulary.ticketPrefixes.contains(match.groups[0]) || !notTickets.contains(match.groups[0]) {
            add(match.offset, .ticket, "\(match.groups[0])-\(match.groups[1])")
            masked = mask(match.range, in: masked)
        }
        let tokens = tokenize(masked)
        var index = 0
        while index < tokens.count {
            if let ticket = looseTicket(tokens, at: index, vocabulary: vocabulary) {
                add(tokens[index].offset, .ticket, ticket.key)
                index = ticket.next
            } else if let pr = loosePullRequest(tokens, at: index) {
                add(tokens[index].offset, .pullRequest, "\(lineRepo ?? "")#\(pr.value)")
                index = pr.next
            } else {
                index += 1
            }
        }
        for name in names { add(Int.max, .name, name.name) }
        var seen = Set<String>()
        return found.sorted { $0.offset < $1.offset }.map(\.entity).filter { seen.insert($0.id).inserted }
    }

    /// A word as it sounds, so spellings Whisper picks for a spoken name meet: quiddly and kvidly are both `kvidli`.
    static func phonetic(_ word: String) -> String {
        var text = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for (from, to) in [("qu", "kv"), ("ck", "k"), ("ph", "f"), ("q", "k"), ("c", "k"), ("w", "v"), ("z", "s"), ("y", "i")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        var result = ""
        for letter in text where letter.isLetter && result.last != letter { result.append(letter) }
        return result
    }

    /// The number said from `start` on: one group of digits, or short groups read out one or two at a time (`90 31`).
    static func number(_ tokens: [String], from start: Int) -> (value: Int, next: Int)? {
        var digits = "", last = 0, index = start
        while index < tokens.count, isDigits(tokens[index]) {
            let group = tokens[index]
            if !digits.isEmpty && (last > 3 || group.count > 3 || digits.count + group.count > 6) { break }
            digits += group
            last = group.count
            index += 1
        }
        guard !digits.isEmpty, digits.count <= 6, digits.first != "0", let value = Int(digits) else { return nil }
        return (value, index)
    }

    private struct Token {
        let text: String
        let offset: Int
    }

    /// Words and numbers, split where letters meet digits, so `QDLY9031` and `Q-D-L-Y 9031` read alike.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = [], current = "", start = 0, kind = 0
        for (offset, character) in text.enumerated() {
            let next = character.isNumber ? 1 : character.isLetter ? 2 : 0
            if next != kind {
                if !current.isEmpty { tokens.append(Token(text: current, offset: start)) }
                current = ""
                start = offset
                kind = next
            }
            if next != 0 { current.append(character) }
        }
        if !current.isEmpty { tokens.append(Token(text: current, offset: start)) }
        return tokens
    }

    private static func looseTicket(_ tokens: [Token], at index: Int, vocabulary: InCallVocabulary) -> (key: String, next: Int)? {
        let words = tokens.map(\.text)
        func prefix(_ word: String) -> String? {
            guard word.allSatisfy(\.isLetter) else { return nil }
            if vocabulary.ticketPrefixes.contains(word.uppercased()), word == word.uppercased() || word.count >= 3 { return word.uppercased() }
            return word.count >= 4 ? vocabulary.aliases[phonetic(word)] : nil
        }
        var candidates: [(prefix: String, next: Int)] = []
        if let found = prefix(words[index]) { candidates.append((found, index + 1)) }
        var spelled = "", end = index
        while end < words.count, words[end].count == 1, words[end].first!.isLetter, spelled.count < 10 {
            spelled += words[end].uppercased()
            end += 1
            if spelled.count > 1, vocabulary.ticketPrefixes.contains(spelled) { candidates.append((spelled, end)) }
        }
        for candidate in candidates.reversed() {
            var next = candidate.next
            if next < words.count, fillers.contains(words[next].lowercased()), next + 1 < words.count, isDigits(words[next + 1]) { next += 1 }
            if let number = number(words, from: next) { return ("\(candidate.prefix)-\(number.value)", number.next) }
        }
        return nil
    }

    private static func loosePullRequest(_ tokens: [Token], at index: Int) -> (value: Int, next: Int)? {
        let words = tokens.map { $0.text.lowercased() }
        var next = index
        if words[next] == "pull", next + 1 < words.count, words[next + 1].hasPrefix("request") {
            next += 2
        } else if pullWords.contains(words[next]) {
            next += 1
        } else {
            return nil
        }
        while next < words.count, fillers.contains(words[next]) { next += 1 }
        return number(words, from: next)
    }

    private static func spotNames(_ text: String, vocabulary: InCallVocabulary) -> [(name: String, offset: Int)] {
        let spoken = " " + normalized(text) + " "
        let candidates = vocabulary.repos.map { (name: String($0.split(separator: "/").last ?? Substring($0)), key: $0) }
            + vocabulary.names.map { (name: $0, key: $0) }
        var seen = Set<String>()
        return candidates.compactMap { candidate -> (String, Int)? in
            let words = normalized(candidate.name)
            guard words.filter(\.isLetter).count >= 4, seen.insert(candidate.name.lowercased()).inserted,
                  let range = spoken.range(of: " " + words + " ") else { return nil }
            return (candidate.name, spoken.distance(from: spoken.startIndex, to: range.lowerBound))
        }.sorted { $0.1 < $1.1 }
    }

    /// Lower-case words split at anything but letters and digits, with "dot" and "punkt" read as a separator.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .filter { $0 != "dot" && $0 != "punkt" }
            .joined(separator: " ")
    }

    private static func isDigits(_ word: String) -> Bool { !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isNumber } }

    private static func mask(_ range: Range<String.Index>, in text: String) -> String {
        var copy = text
        let start = text.distance(from: text.startIndex, to: range.lowerBound), length = text.distance(from: range.lowerBound, to: range.upperBound)
        let lower = copy.index(copy.startIndex, offsetBy: start)
        copy.replaceSubrange(lower..<copy.index(lower, offsetBy: length), with: String(repeating: " ", count: length))
        return copy
    }

    private static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = [])
    -> [(offset: Int, range: Range<String.Index>, groups: [String])] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let groups = (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            return (text.distance(from: text.startIndex, to: range.lowerBound), range, groups)
        }
    }
}

enum InCallLogic {
    static let enabledKey = "inCallHelp"
    static let ministralKey = "inCallHelpMinistral"
    /// How long a repository stays the one a bare `PR 12` belongs to.
    static let repoContextWindow: TimeInterval = 120
    static let modelInterval: TimeInterval = 60
    static let modelWindow: TimeInterval = 240
    /// More lines than this waiting for Whisper means the live transcript is behind, and Ministral waits.
    static let maxPendingLines = 6

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    static func usesMinistral(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: ministralKey) as? Bool ?? true }

    /// The entities not seen before, and all of them. A `#12` whose repository is unknown is dropped once one with a
    /// repository is known, and replaced when its repository becomes known.
    static func merge(_ known: [SpottedEntity], _ new: [SpottedEntity]) -> (all: [SpottedEntity], added: [SpottedEntity]) {
        var all = known, added: [SpottedEntity] = []
        for entity in new where !all.contains(where: { $0.id == entity.id }) {
            if let pr = entity.pullRequest {
                let sameNumber = all.filter { $0.pullRequest?.number == pr.number }
                if pr.repo == nil, sameNumber.contains(where: { $0.pullRequest?.repo != nil }) { continue }
                if pr.repo != nil { all.removeAll { $0.pullRequest?.number == pr.number && $0.pullRequest?.repo == nil } }
            }
            all.append(entity)
            added.append(entity)
        }
        return (all, added)
    }

    /// The repository last talked about within `repoContextWindow` before `time`.
    static func repoContext(_ entities: [SpottedEntity], at time: TimeInterval, vocabulary: InCallVocabulary) -> String? {
        entities.filter { time - $0.at <= repoContextWindow && $0.at <= time }.reversed().lazy.compactMap { entity -> String? in
            if entity.kind == .name { return vocabulary.repo(entity.key) }
            return entity.pullRequest?.repo
        }.first
    }

    /// `QDLY-9031, finq.api#2688`: the tickets and pull requests, for "Mentioned:".
    static func mentioned(_ entities: [SpottedEntity]) -> String? {
        let labels = entities.filter { $0.kind == .ticket || $0.pullRequest?.repo != nil }.map(\.label)
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// Whether `text` asks what was decided before, in English or Swedish.
    static func asksAboutLastTime(_ text: String) -> Bool {
        let text = text.lowercased()
        let anchor = "(last time|last week|last meeting|before|previously|earlier|förra gången|förra veckan|förra mötet|sist|senast|tidigare|innan)"
        let patterns = [
            "what (did|do|have) we (decide|decided|agree|agreed|conclude|concluded|settle|settled|land|landed)",
            "where did we (land|end up)",
            "remind me what we (decided|agreed)",
            "what did we (say|discuss|talk about).{0,30}\(anchor)",
            "\(anchor),? (we|did we) (decided|agreed|decide|agree)",
            "vad (bestämde|beslutade|beslöt|landade|enades) vi",
            "vad (kom|har|hade) vi (fram till|kommit fram till|bestämt|beslutat)",
            "vad var det vi (bestämde|beslutade|kom fram till)",
            "vad sa vi.{0,30}\(anchor)",
            "\(anchor) (bestämde|beslutade|kom) vi",
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Ministral looks over the last minutes at most once a minute, on mains power, while the live text keeps up and
    /// something new was said.
    static func shouldAskModel(now: Date, last: Date?, onBattery: Bool, pending: Int, newLines: Int, allowed: Bool) -> Bool {
        guard allowed, !onBattery, pending <= maxPendingLines, newLines > 0 else { return false }
        return last.map { now.timeIntervalSince($0) >= modelInterval } ?? true
    }
}

/// An earlier meeting as the retrieval sees it, and what it decided once it is chosen.
struct PastMeeting: Equatable, Identifiable {
    let id: Int64
    var title: String
    var date: Date
    var sourceApp: String? = nil
    var attendees: [String] = []
    var seriesID: String? = nil
    var mentions: Set<String> = []
    var line: String? = nil
    var decisions: [String] = []
    var actionItems: [String] = []
    var openItems: [String] = []
}

struct RetrievalContext: Equatable {
    var entities: Set<String> = []
    var title: String?
    var attendees: [String] = []
    var sourceApp: String?
    var seriesID: String?
    var now = Date()
}

enum InCallRetrieval {
    static let threshold = 1.5
    private static let stopWords: Set<String> = ["the", "and", "for", "with", "och", "med", "att", "meeting", "mote", "motet",
                                                 "call", "sync", "weekly", "daily", "veckomöte", "avstämning", "about", "kring", "från"]

    /// How well an earlier meeting matches the call: shared tickets and pull requests count most, then the same
    /// recurring event, the same people and a similar title; the same app and recency break ties.
    static func score(_ meeting: PastMeeting, context: RetrievalContext) -> Double {
        var score = Double(min(context.entities.intersection(meeting.mentions).count, 3)) * 3
        if let series = context.seriesID, series == meeting.seriesID { score += 4 }
        score += overlap(people(context.attendees), people(meeting.attendees)) * 4
        if let title = context.title { score += overlap(words(title), words(meeting.title)) * 3 }
        if let app = context.sourceApp, app == meeting.sourceApp { score += 0.5 }
        let days = max(0, context.now.timeIntervalSince(meeting.date) / 86400)
        return score + exp(-days / 30)
    }

    /// The best `limit` meetings that match on more than app and recency, best first.
    static func rank(_ meetings: [PastMeeting], context: RetrievalContext, limit: Int = 3) -> [PastMeeting] {
        let scored: [(meeting: PastMeeting, score: Double)] = meetings.filter { $0.date < context.now }
            .map { ($0, score($0, context: context)) }
        let kept = scored.filter { $0.score >= threshold }.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.meeting.date > b.meeting.date
        }
        return kept.prefix(limit).map(\.meeting)
    }

    static func words(_ text: String) -> Set<String> {
        Set(EntitySpotter.normalized(text).split(separator: " ").map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    /// Emails where given, else names, in lower case.
    static func people(_ attendees: [String]) -> Set<String> {
        Set(attendees.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

struct InCallAnswer: Equatable {
    let text: String
    var meetingID: Int64?
    var meetingTitle: String?
    var date: Date?
}

enum InCallPrompts {
    static let decisionSchema: [String: Any] = [
        "type": "object", "required": ["found", "answer", "meeting"],
        "properties": ["found": ["type": "boolean"], "answer": ["type": "string"], "meeting": ["type": "integer"]],
    ]

    static let extractionSchema: [String: Any] = {
        let list: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return ["type": "object", "required": ["tickets", "pullRequests", "names", "asksWhatWasDecided"],
                "properties": ["tickets": list, "pullRequests": list, "names": list, "asksWhatWasDecided": ["type": "boolean"]]]
    }()

    static func decision(question: String, meetings: [PastMeeting], language: String) -> (system: String, prompt: String) {
        let system = """
            You help during a meeting by recalling what earlier meetings decided. Answer in \(language) in at most three short \
            sentences, using only the meeting notes given. Name the decision, not the discussion. found: false when none of \
            the notes answers the question. meeting: the number of the meeting the answer comes from, 0 when none.
            """
        let notes = meetings.enumerated().map { index, meeting in
            var lines = ["Meeting \(index + 1): \(meeting.title) (\(day(meeting.date)))"]
            if let line = meeting.line { lines.append("Said there: \(line)") }
            lines += meeting.decisions.prefix(8).map { "- \($0)" }
            lines += meeting.actionItems.prefix(5).map { "- Action: \($0)" }
            return lines.joined(separator: "\n")
        }
        return (system, "Question: \(question)\n\n" + notes.joined(separator: "\n\n"))
    }

    static func parseDecision(_ text: String, meetings: [PastMeeting]) -> InCallAnswer? {
        guard let json = object(in: text), json["found"] as? Bool == true,
              let answer = (json["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { return nil }
        let index = (json["meeting"] as? Int).map { $0 - 1 }
        let meeting = index.flatMap { meetings.indices.contains($0) ? meetings[$0] : nil }
        return InCallAnswer(text: answer, meetingID: meeting?.id, meetingTitle: meeting?.title, date: meeting?.date)
    }

    /// Without Ministral: the best meeting's first decisions.
    static func fallback(_ meeting: PastMeeting) -> InCallAnswer? {
        let points = meeting.decisions.isEmpty ? meeting.actionItems : meeting.decisions
        guard !points.isEmpty else { return nil }
        return InCallAnswer(text: points.prefix(3).joined(separator: " "), meetingID: meeting.id, meetingTitle: meeting.title, date: meeting.date)
    }

    static func extraction(lines: [String], vocabulary: InCallVocabulary) -> (system: String, prompt: String) {
        let known = (Array(vocabulary.ticketPrefixes).sorted().map { "\($0)-123" } + vocabulary.repos + vocabulary.names).prefix(60)
        let system = """
            You read a live meeting transcript in Swedish or English, written by speech recognition, and list what it refers \
            to. tickets: Jira keys such as ABC-123, also when spoken as letters and digits ("Q D L Y nittio trettioett" is \
            QDLY-9031). pullRequests: pull requests as owner/repo#number or repo#number. names: repositories, projects or \
            customers from the known list. asksWhatWasDecided: whether someone asks what was decided or agreed earlier. \
            Only list what the transcript says; leave lists empty when nothing is mentioned.
            """
        return (system, "Known: \(known.joined(separator: ", "))\n\nTranscript:\n" + lines.joined(separator: "\n"))
    }

    /// The entities Ministral named, kept only where the spotter recognises them, so made-up names are dropped.
    static func parseExtraction(_ text: String, at time: TimeInterval, vocabulary: InCallVocabulary) -> (entities: [SpottedEntity], asks: Bool) {
        guard let json = object(in: text) else { return ([], false) }
        let said = ["tickets", "pullRequests", "names"].flatMap { json[$0] as? [String] ?? [] }
        let entities = said.flatMap { phrase in
            EntitySpotter.spot(phrase, at: time, vocabulary: vocabulary).map { SpottedEntity(kind: $0.kind, key: $0.key, line: "", at: time) }
        }
        return (entities, json["asksWhatWasDecided"] as? Bool ?? false)
    }

    private static func object(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct CalendarAttendee: Equatable, Codable {
    var name: String?
    var email: String?

    var label: String { name ?? email ?? "" }
    /// What retrieval compares: the email where known.
    var identity: String { (email ?? name ?? "").lowercased() }
}

/// A calendar event, as much of it as in-call help uses.
struct CalendarEventInfo: Equatable {
    let id: String
    var seriesID: String?
    let title: String
    let start: Date
    let end: Date
    var attendees: [CalendarAttendee] = []
    var notes: String?
    var url: String?
    var location: String?
    var isAllDay = false
    var declined = false
    var cancelled = false
}

enum CalendarLogic {
    /// How far around the recording's start an event may begin or end and still be its meeting.
    static let slack: TimeInterval = 10 * 60

    /// The meeting service an event is held in, from its address, location or the links in its notes.
    static func service(of event: CalendarEventInfo) -> String? {
        let links = [event.url, event.location].compactMap { $0 } + links(in: event.notes ?? "") + links(in: event.location ?? "")
        return links.lazy.compactMap { MeetingSourceLogic.service(url: $0, title: $0.contains("huddle") ? "huddle" : "") }.first
    }

    /// The event a recording starting at `start` belongs to: one running then is preferred over one starting or ending
    /// just around it, then one held in the app the call is in, then the one starting closest.
    static func pick(_ events: [CalendarEventInfo], at start: Date, sourceApp: String?) -> CalendarEventInfo? {
        let near = events.filter { $0.start <= start.addingTimeInterval(slack) && $0.end >= start.addingTimeInterval(-slack / 2) }
        func rank(_ event: CalendarEventInfo) -> (Int, Int, TimeInterval) {
            let running = event.start <= start && start < event.end ? 1 : 0
            let app = sourceApp != nil && service(of: event) == sourceApp ? 1 : 0
            return (running, app, -abs(event.start.timeIntervalSince(start)))
        }
        return near.max { rank($0) < rank($1) }
    }

    static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { $0.url?.absoluteString }
    }

    private static let boilerplate = ["join zoom meeting", "meeting id", "passcode", "password:", "join with google meet", "join by phone",
                                      "dial-in", "dial in", "microsoft teams", "join the meeting", "click here to join", "meeting options",
                                      "more phone numbers", "learn more", "need help?", "join on your computer", "join conference",
                                      "conference id", "möte-id", "lösenord", "ansluta till mötet", "anslut till mötet", "pin:", "one tap mobile"]

    /// The start of an event's notes without HTML, links and the call service's joining instructions.
    static func agenda(_ notes: String?, limit: Int = 280) -> String? {
        guard var text = notes, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let lower = line.lowercased()
                return !line.isEmpty && line.contains(where: \.isLetter) && !boilerplate.contains(where: lower.contains)
                    && lower.range(of: #"^(<)?https?://\S+(>)?$"#, options: .regularExpression) == nil
                    && lower.range(of: #"^[-_=~:.*\u{2500}]{4,}"#, options: .regularExpression) == nil
            }
        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return joined.count <= limit ? joined : String(joined.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The tickets and pull requests the event names in its title, notes and address.
    static func seeds(_ event: CalendarEventInfo, vocabulary: InCallVocabulary) -> [SpottedEntity] {
        let text = [event.title, event.notes ?? "", event.url ?? ""].joined(separator: "\n")
        return text.components(separatedBy: .newlines).flatMap { EntitySpotter.spot($0, vocabulary: vocabulary) }
            .filter { $0.kind != .name }
            .map { SpottedEntity(kind: $0.kind, key: $0.key, line: "Calendar: \(event.title)", at: 0) }
    }

    /// Lines put before the transcript for the summary, so it can use the invitation's title and agenda.
    static func summaryContext(title: String?, attendees: [String], agenda: String?) -> [String] {
        guard let title, !title.isEmpty else { return [] }
        var lines = ["[Calendar event: \(title)]"]
        if !attendees.isEmpty { lines.append("[Invited: \(attendees.prefix(12).joined(separator: ", "))]") }
        if let agenda, !agenda.isEmpty { lines.append("[Agenda: \(agenda.replacingOccurrences(of: "\n", with: " / "))]") }
        return lines
    }
}

/// What the notch and the meeting's sidebar show while a call is recorded.
struct InCallCard: Identifiable, Equatable {
    struct Ticket: Equatable {
        let key: String
        var summary: String?
        var status: String?
        var assignee: String?
        var url: URL?
    }

    struct PullRequest: Equatable {
        let repo: String
        let number: Int
        var title: String?
        var state: String?
        var checks: String?
        var review: String?

        var url: String { "https://github.com/\(repo)/pull/\(number)" }
        var label: String { "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(number)" }
    }

    enum Kind: Equatable {
        case about(CalendarEventInfo)
        case ticket(Ticket)
        case pullRequest(PullRequest)
        case meeting(PastMeeting, because: [String])
        case answer(InCallAnswer, question: String)
    }

    let id: String
    var kind: Kind
    var added: Date

    static func order(_ cards: [InCallCard], dismissed: Set<String>) -> [InCallCard] {
        cards.filter { !dismissed.contains($0.id) }.sorted { a, b in
            let pinned = (a.isAbout, b.isAbout)
            if pinned.0 != pinned.1 { return pinned.0 }
            return a.added > b.added
        }
    }

    /// Adds `card`, or updates the one with its id in place without moving it.
    static func upsert(_ card: InCallCard, into cards: inout [InCallCard]) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index].kind = card.kind
        } else {
            cards.append(card)
        }
    }

    var isAbout: Bool { if case .about = kind { return true } else { return false } }
}
