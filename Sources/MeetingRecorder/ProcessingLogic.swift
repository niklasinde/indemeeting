import Foundation

enum MeetingLanguage: String, CaseIterable, Identifiable {
    case swedish = "sv-SE"
    case english = "en-US"

    static let storageKey = "meetingLanguage"

    static var current: MeetingLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init) ?? .swedish
    }

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var displayName: String { self == .swedish ? "Svenska" : "English" }
    var englishName: String { self == .swedish ? "Swedish" : "English" }

    var headings: Headings {
        switch self {
        case .swedish:
            return Headings(transcript: "Transkription", actionItems: "Åtgärdspunkter", unavailable: "Ingen sammanfattning",
                            notes: "Anteckningar")
        case .english:
            return Headings(transcript: "Transcript", actionItems: "Action items", unavailable: "No summary", notes: "Notes")
        }
    }

    struct Headings {
        let transcript, actionItems, unavailable, notes: String
    }
}

struct TranscriptSegment: Equatable {
    let start: TimeInterval
    let text: String

    var line: String { "\(ProcessingLogic.timestamp(start)) \(text)" }
}

struct MeetingSummary: Codable, Equatable {
    struct ActionItem: Codable, Equatable {
        let task: String
        let owner: String?
        var done: Bool? = nil
    }

    struct Topic: Codable, Equatable {
        let title: String
        let points: [String]
    }

    let title: String
    let actionItems: [ActionItem]
    let topics: [Topic]

    static func decode(json: String) throws -> MeetingSummary {
        try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
    }
}

extension MeetingSummary {
    init(_ parsed: ParsedSummary, title: String) {
        self.init(title: title,
                  actionItems: parsed.actionItems.map { ActionItem(task: $0.task, owner: $0.owner, done: $0.done) },
                  topics: parsed.sections.map { Topic(title: $0.heading, points: $0.lines.map(\.text)) })
    }
}

extension ParsedSummary {
    init(_ summary: MeetingSummary) {
        self.init(title: summary.title,
                  actionItems: summary.actionItems.enumerated().map { index, item in
                      ChecklistItem(key: String(index), task: item.task, owner: item.owner, done: item.done ?? false)
                  },
                  sections: summary.topics.map { SummarySection(heading: $0.title, lines: $0.points.map(MarkdownBlock.bullet)) })
    }
}

enum SummaryUnavailable: Error, Equatable {
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady
    case unsupportedLanguage(MeetingLanguage)
    case requiresMacOS26

    private static let settings = "System Settings \u{2192} Apple Intelligence & Siri"
    private static let retry = "then choose \u{201C}Transcribe & summarise a recording\u{2026}\u{201D} in the menu to summarise this meeting."

    var menuText: String {
        switch self {
        case .appleIntelligenceOff: return "No summary: Apple Intelligence is off (\(Self.settings))"
        case .deviceNotEligible: return "No summary: this Mac does not support Apple Intelligence"
        case .modelNotReady: return "No summary: Apple Intelligence model not ready yet"
        case .unsupportedLanguage(let language): return "No summary: Apple Intelligence does not support \(language.englishName)"
        case .requiresMacOS26: return "No summary: needs macOS 26 with Apple Intelligence"
        }
    }

    var message: String {
        switch self {
        case .appleIntelligenceOff:
            return "Apple Intelligence is turned off, so the on-device model cannot summarise. Turn it on in \(Self.settings), \(Self.retry)"
        case .deviceNotEligible:
            return "This Mac is not eligible for Apple Intelligence, so no on-device summary can be made. The transcript is still available."
        case .modelNotReady:
            return "The Apple Intelligence model is not ready yet (it may still be downloading). Check \(Self.settings), wait for the download to finish, \(Self.retry)"
        case .unsupportedLanguage(let language):
            return "The on-device Apple Intelligence model does not support \(language.englishName) on this Mac. Check the language in \(Self.settings), \(Self.retry)"
        case .requiresMacOS26:
            return "Summaries use Apple's on-device Foundation Models, which need macOS 26 or later with Apple Intelligence turned on in \(Self.settings)."
        }
    }
}

enum ProcessingStage: Equatable {
    case transcribing
    case summarising(part: Int, of: Int)
    case combining

    func text(for name: String) -> String {
        switch self {
        case .transcribing: return "Transcribing \(name)\u{2026}"
        case .summarising(let part, let total) where total > 1: return "Summarising \(name)\u{2026} (\(part)/\(total))"
        case .summarising: return "Summarising \(name)\u{2026}"
        case .combining: return "Summarising \(name)\u{2026} (combining)"
        }
    }
}

enum ProcessingLogic {
    static func timestamp(_ seconds: TimeInterval) -> String {
        "[\(RecordingLogic.elapsedText(max(seconds, 0)))]"
    }

    static func transcriptURL(for audio: URL) -> URL { sibling(of: audio, suffix: "transcript.md") }
    static func summaryURL(for audio: URL) -> URL { sibling(of: audio, suffix: "summary.md") }
    static func notesURL(for audio: URL) -> URL { sibling(of: audio, suffix: "notes.md") }
    static func metaURL(for audio: URL) -> URL { sibling(of: audio, suffix: "meta.json") }

    private static func sibling(of audio: URL, suffix: String) -> URL {
        audio.deletingPathExtension().appendingPathExtension(suffix)
    }

    static func sentences(_ pieces: [(text: String, start: TimeInterval?)], from fallback: TimeInterval) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var text = ""
        var start: TimeInterval?
        var latest = fallback
        func emit() {
            let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { segments.append(TranscriptSegment(start: start ?? latest, text: sentence)) }
            text = ""
            start = nil
        }
        for piece in pieces {
            latest = piece.start ?? latest
            if text.trimmingCharacters(in: .whitespaces).isEmpty { start = piece.start ?? latest }
            text += piece.text
            if let last = piece.text.trimmingCharacters(in: .whitespaces).last, ".?!".contains(last) { emit() }
        }
        emit()
        return segments
    }

    static func chunks(_ lines: [String], maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for piece in lines.flatMap({ split($0, maxCharacters: maxCharacters) }) {
            if !current.isEmpty && current.count + 1 + piece.count > maxCharacters {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : "\n" + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func split(_ line: String, maxCharacters: Int) -> [String] {
        guard line.count > maxCharacters else { return [line] }
        var pieces: [String] = []
        var current = ""
        for word in line.split(separator: " ").flatMap({ hardSplit(String($0), maxCharacters) }) {
            if !current.isEmpty && current.count + 1 + word.count > maxCharacters {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? word : " " + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func hardSplit(_ word: String, _ size: Int) -> [String] {
        stride(from: 0, to: word.count, by: size).map {
            let start = word.index(word.startIndex, offsetBy: $0)
            return String(word[start..<(word.index(start, offsetBy: size, limitedBy: word.endIndex) ?? word.endIndex)])
        }
    }

    static func transcriptMarkdown(audioName: String, language: MeetingLanguage, engine: String,
                                   segments: [TranscriptSegment]) -> String {
        """
        # \(language.headings.transcript): \(baseName(audioName))

        _\(audioName) \u{00B7} \(language.displayName) \u{00B7} on-device \(engine)_

        \(segments.map(\.line).joined(separator: "\n\n"))

        """
    }

    /// `# Title`, `## Action items` as `- [ ] Owner: task` lines, then one `## Topic` with bullets per topic.
    static func summaryMarkdown(_ summary: MeetingSummary, audioName: String?, language: MeetingLanguage) -> String {
        var parts = ["# \(summary.title)"]
        if let audioName { parts.append("_\(audioName) \u{00B7} \(language.displayName) \u{00B7} on-device Apple Intelligence_") }
        if !summary.actionItems.isEmpty {
            parts.append("## \(language.headings.actionItems)")
            parts.append(summary.actionItems.map { item in
                let owner = item.owner?.trimmingCharacters(in: .whitespaces) ?? ""
                return (item.done == true ? "- [x] " : "- [ ] ") + (owner.isEmpty ? "" : "\(owner): ") + item.task
            }.joined(separator: "\n"))
        }
        for topic in summary.topics where !topic.points.isEmpty {
            parts.append("## \(topic.title)")
            parts.append(topic.points.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    static func unavailableMarkdown(_ reason: SummaryUnavailable, audioName: String, language: MeetingLanguage) -> String {
        """
        # \(language.headings.unavailable): \(baseName(audioName))

        \(reason.message)

        The transcript is in `\(transcriptURL(for: URL(fileURLWithPath: audioName)).lastPathComponent)`.

        """
    }

    /// The summary with its action items, the notes and the transcript of a meeting in one document.
    static func exportMarkdown(_ content: MeetingContent) -> String {
        let meeting = content.meeting
        let language = meeting.language ?? .current
        let hasSummary = !content.summary.isEmpty
        var parts = [summaryMarkdown(MeetingSummary(content.summary, title: meeting.title),
                                     audioName: hasSummary ? meeting.audioFile : nil, language: language)]
        if !hasSummary, let reason = meeting.statusMessage { parts.append(reason + "\n") }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("## \(language.headings.notes)\n\n\(notes)\n") }
        if !content.segments.isEmpty {
            parts.append(transcriptMarkdown(audioName: meeting.audioFile, language: language,
                                            engine: meeting.transcriptEngine ?? "transcription", segments: content.segments))
        }
        return parts.joined(separator: "\n")
    }

    private static func baseName(_ audioName: String) -> String {
        URL(fileURLWithPath: audioName).deletingPathExtension().lastPathComponent
    }

    static func processArguments(_ arguments: [String]) -> (audio: URL, language: MeetingLanguage?)? {
        guard let index = arguments.firstIndex(of: "--process"), index + 1 < arguments.count else { return nil }
        let language = arguments.firstIndex(of: "--language").flatMap {
            $0 + 1 < arguments.count ? MeetingLanguage(rawValue: arguments[$0 + 1]) : nil
        }
        return (URL(fileURLWithPath: arguments[index + 1]), language)
    }
}
