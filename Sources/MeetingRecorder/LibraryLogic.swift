import Foundation

struct FolderItem: Equatable {
    let name: String
    let created: Date
}

struct RecordingEntry: Identifiable, Hashable {
    let audio: URL
    let date: Date
    let duration: TimeInterval?
    /// The companion files (transcript, summary, notes, meta) that exist next to the audio.
    let companions: [URL]
    /// Being recorded as a new meeting; its audio file does not exist yet.
    var inProgress = false

    var id: URL { audio }
    var name: String { audio.deletingPathExtension().lastPathComponent }
    var transcript: URL { ProcessingLogic.transcriptURL(for: audio) }
    var summary: URL { ProcessingLogic.summaryURL(for: audio) }
    var notes: URL { ProcessingLogic.notesURL(for: audio) }
    var meta: URL { ProcessingLogic.metaURL(for: audio) }
    var hasTranscript: Bool { companions.contains(transcript) }
    var hasSummary: Bool { companions.contains(summary) }
    var files: [URL] { [audio] + companions }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(String)
    case task(String, done: Bool)
    case paragraph(String)
}

/// The `<base>.meta.json` sidecar: edits made in the app, kept apart from the generated files.
struct MeetingMeta: Codable, Equatable {
    var title: String?
    var checked: [String: Bool]

    init(title: String? = nil, checked: [String: Bool] = [:]) {
        self.title = title
        self.checked = checked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        checked = try container.decodeIfPresent([String: Bool].self, forKey: .checked) ?? [:]
    }

    static func decode(_ data: Data?) -> MeetingMeta {
        data.flatMap { try? JSONDecoder().decode(MeetingMeta.self, from: $0) } ?? MeetingMeta()
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

struct ChecklistItem: Equatable, Identifiable {
    /// The line as written in the summary; the sidecar stores the checked state under it.
    let key: String
    let task: String
    let owner: String?
    let done: Bool

    var id: String { key }
}

struct SummarySection: Equatable {
    let heading: String
    var lines: [MarkdownBlock]
}

struct ParsedSummary: Equatable {
    var title: String?
    var actionItems: [ChecklistItem] = []
    var sections: [SummarySection] = []
    /// Why there is no summary, when the file is the "No summary" note.
    var unavailable: String?

    var isEmpty: Bool { actionItems.isEmpty && sections.isEmpty }
}

enum DateGroup: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This week"
    case earlier = "Earlier"
}

enum LibraryLogic {
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"]
    static let fallbackTitle = "Meeting"
    private static let actionHeadings = Set(MeetingLanguage.allCases.map(\.headings.actionItems) + ["Åtgärder"])

    /// Finished audio files; in-progress, part and combined files are left out.
    static func isListed(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return audioExtensions.contains(url.pathExtension.lowercased())
            && !RecordingLogic.isWorkFile(baseName: url.deletingPathExtension().lastPathComponent)
    }

    /// Puts the meeting being recorded at the top while its file is not listed yet.
    static func withRecording(_ recording: URL?, in entries: [RecordingEntry], now: Date,
                              timeZone: TimeZone = .current) -> [RecordingEntry] {
        guard let recording, !entries.contains(where: { $0.audio == recording }) else { return entries }
        let date = RecordingLogic.date(fromFileName: recording.lastPathComponent, timeZone: timeZone) ?? now
        return [RecordingEntry(audio: recording, date: date, duration: nil, companions: [], inProgress: true)] + entries
    }

    /// Newest first: by the minute in the file name (creation date otherwise), then `-3` before `-2` before the first.
    static func recordings(in folder: URL, files: [FolderItem], durations: [String: TimeInterval],
                           timeZone: TimeZone = .current) -> [RecordingEntry] {
        let names = Set(files.map(\.name))
        return files.filter { isListed($0.name) }
            .map { item in
                let audio = folder.appendingPathComponent(item.name)
                return RecordingEntry(
                    audio: audio,
                    date: RecordingLogic.date(fromFileName: item.name, timeZone: timeZone) ?? item.created,
                    duration: durations[item.name],
                    companions: ProcessingLogic.companionURLs(for: audio).filter { names.contains($0.lastPathComponent) })
            }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func minutesText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func markdownBlocks(_ markdown: String) -> [MarkdownBlock] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
            }
            for (prefix, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where line.hasPrefix(prefix) {
                return .task(String(line.dropFirst(prefix.count)), done: done)
            }
            for prefix in ["- ", "* "] where line.hasPrefix(prefix) { return .bullet(String(line.dropFirst(prefix.count))) }
            return .paragraph(line)
        }
    }

    /// Reads both the current summary format and the older one (summary, key points, decisions, `task — **owner**`).
    static func parseSummary(_ markdown: String, meta: MeetingMeta = MeetingMeta()) -> ParsedSummary {
        var result = ParsedSummary()
        var isUnavailable = false
        var inActionItems = false
        for block in markdownBlocks(markdown) {
            switch block {
            case .heading(level: 1, let text) where result.title == nil && !isUnavailable:
                isUnavailable = MeetingLanguage.allCases.contains { text.hasPrefix($0.headings.unavailable + ":") }
                if !isUnavailable { result.title = text }
            case .heading(_, let text):
                inActionItems = actionHeadings.contains(text)
                if !inActionItems { result.sections.append(SummarySection(heading: text, lines: [])) }
            case .task(let text, let done):
                result.actionItems.append(checklistItem(text, done: meta.checked[text] ?? done))
            case .paragraph(let text) where isUnavailable:
                if result.unavailable == nil { result.unavailable = text }
            case .bullet, .paragraph:
                if !inActionItems, !result.sections.isEmpty { result.sections[result.sections.count - 1].lines.append(block) }
            }
        }
        return result
    }

    /// `Owner: task`, or the older `task — **Owner**`.
    static func checklistItem(_ text: String, done: Bool) -> ChecklistItem {
        if text.hasSuffix("**"), let range = text.range(of: " \u{2014} **") {
            let owner = text[range.upperBound...].dropLast(2)
            return ChecklistItem(key: text, task: String(text[..<range.lowerBound]), owner: String(owner), done: done)
        }
        if let colon = text.range(of: ": ") {
            let owner = text[..<colon.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            if !owner.isEmpty, owner.count <= 40, owner.split(separator: " ").count <= 3 {
                return ChecklistItem(key: text, task: String(text[colon.upperBound...]), owner: owner, done: done)
            }
        }
        return ChecklistItem(key: text, task: text, owner: nil, done: done)
    }

    /// The renamed title, else the summary's title, else "Meeting".
    static func title(override: String?, aiTitle: String?) -> String {
        [override, aiTitle].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallbackTitle
    }

    /// What to store for an edited title: nothing when it is empty or what would be shown anyway.
    static func titleOverride(_ text: String, aiTitle: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == title(override: nil, aiTitle: aiTitle) ? nil : trimmed
    }

    static func dateGroup(_ date: Date, now: Date, calendar: Calendar = .current) -> DateGroup {
        if date > now || calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) ? .thisWeek : .earlier
    }

    static func grouped(_ entries: [RecordingEntry], now: Date,
                        calendar: Calendar = .current) -> [(group: DateGroup, entries: [RecordingEntry])] {
        let groups = Dictionary(grouping: entries) { dateGroup($0.date, now: now, calendar: calendar) }
        return DateGroup.allCases.compactMap { group in groups[group].map { (group, $0) } }
    }

    /// Every word of the query appears in one of the texts, ignoring case and diacritics.
    static func matches(_ query: String, in texts: [String]) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            texts.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The `[hh:mm:ss] sentence` lines of a transcript file.
    static func transcriptSegments(_ markdown: String) -> [TranscriptSegment] {
        markdown.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let fields = line[line.index(after: line.startIndex)..<close].split(separator: ":").compactMap { Double($0) }
            guard fields.count == 3 else { return nil }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return TranscriptSegment(start: fields[0] * 3600 + fields[1] * 60 + fields[2], text: text)
        }
    }

    /// Joins sentences into paragraphs that each start a new `span` of seconds.
    static func paragraphs(_ segments: [TranscriptSegment], span: TimeInterval = 30) -> [TranscriptSegment] {
        segments.reduce(into: []) { result, segment in
            if let last = result.last, segment.start - last.start < span {
                result[result.count - 1] = TranscriptSegment(start: last.start, text: last.text + " " + segment.text)
            } else {
                result.append(segment)
            }
        }
    }

    /// The language named in the `_file · Svenska · engine_` line of a transcript or summary.
    static func language(in markdown: String) -> MeetingLanguage? {
        MeetingLanguage.allCases.first { markdown.contains("\u{00B7} \($0.displayName) \u{00B7}") }
    }
}
