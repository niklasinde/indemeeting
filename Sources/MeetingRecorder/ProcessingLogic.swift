import Foundation

enum MeetingLanguage: String, CaseIterable, Identifiable {
    case swedish = "sv-SE"
    case english = "en-US"


    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    /// The ISO 639 code: `sv`, `en`.
    var code: String { String(rawValue.prefix { $0 != "-" }) }
    var displayName: String { self == .swedish ? "Svenska" : "English" }
    var englishName: String { self == .swedish ? "Swedish" : "English" }

    var headings: Headings {
        switch self {
        case .swedish:
            return Headings(transcript: "Transkription", actionItems: "Åtgärdspunkter", unavailable: "Ingen sammanfattning",
                            notes: "Anteckningar", you: "Du", others: "Övriga", speaker: "Talare")
        case .english:
            return Headings(transcript: "Transcript", actionItems: "Action items", unavailable: "No summary", notes: "Notes",
                            you: "You", others: "Others", speaker: "Speaker")
        }
    }

    struct Headings {
        let transcript, actionItems, unavailable, notes, you, others, speaker: String
    }
}

/// Who spoke a segment: the microphone stem is you, the system audio stem the other participants, which speaker
/// recognition tells apart as numbered speakers.
enum Speaker: Hashable {
    case you
    case others
    case numbered(Int)

    private static let numberedPrefix = "speaker-"

    init?(rawValue: String) {
        switch rawValue {
        case "you": self = .you
        case "others": self = .others
        default:
            guard rawValue.hasPrefix(Self.numberedPrefix), let number = Int(rawValue.dropFirst(Self.numberedPrefix.count)),
                  number > 0 else { return nil }
            self = .numbered(number)
        }
    }

    var rawValue: String {
        switch self {
        case .you: return "you"
        case .others: return "others"
        case .numbered(let number): return Self.numberedPrefix + String(number)
        }
    }

    func name(in language: MeetingLanguage) -> String {
        switch self {
        case .you: return language.headings.you
        case .others: return language.headings.others
        case .numbered(let number): return "\(language.headings.speaker) \(number)"
        }
    }
}

typealias SpeakerNames = [Speaker: String]

extension SpeakerNames {
    /// The name the user gave a speaker, or its label in `language`.
    func name(of speaker: Speaker, in language: MeetingLanguage) -> String { self[speaker] ?? speaker.name(in: language) }
}

struct TranscriptSegment: Equatable {
    let start: TimeInterval
    let text: String
    var speaker: Speaker? = nil

    func line(_ language: MeetingLanguage, names: SpeakerNames = [:]) -> String {
        "\(ProcessingLogic.timestamp(start)) " + (speaker.map { "\(names.name(of: $0, in: language)): " } ?? "") + text
    }

    func with(speaker: Speaker?) -> TranscriptSegment { TranscriptSegment(start: start, text: text, speaker: speaker) }
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
    case languageMismatch(mac: String, siri: String)
    case unsupportedLanguage(MeetingLanguage)
    case requiresMacOS26

    private var reason: String {
        switch self {
        case .appleIntelligenceOff: return "Apple Intelligence is turned off"
        case .deviceNotEligible: return "this Mac can\u{2019}t run Apple Intelligence"
        case .modelNotReady: return "Apple Intelligence is still downloading"
        case .languageMismatch: return "your Mac and Siri languages don\u{2019}t match"
        case .unsupportedLanguage(let language): return "Apple Intelligence doesn\u{2019}t support \(language.englishName)"
        case .requiresMacOS26: return "this needs macOS 26 with Apple Intelligence"
        }
    }

    var message: String { (self == .modelNotReady ? "No summary yet" : "No summary") + " \u{2014} " + reason }

    var sentence: String { reason.prefix(1).uppercased() + reason.dropFirst() }

    /// Apple Intelligence only runs when the Mac's first language matches Siri's, so a mismatch explains a model
    /// that is not ready.
    static func notReady(macLanguage: String?, siriLanguage: String?) -> SummaryUnavailable {
        guard let macLanguage, let siriLanguage else { return .modelNotReady }
        let mac = Locale.Language(identifier: macLanguage), siri = Locale.Language(identifier: siriLanguage)
        let sameRegion = mac.region == nil || siri.region == nil || mac.region == siri.region
        return mac.languageCode == siri.languageCode && sameRegion ? .modelNotReady
            : .languageMismatch(mac: macLanguage, siri: siriLanguage)
    }
}

enum SettingsLink: Equatable {
    case appleIntelligence
    case languageAndRegion

    var title: String { self == .languageAndRegion ? "Open Language & Region" : "Open Settings" }

    var path: String {
        self == .languageAndRegion ? "com.apple.Localization-Settings.extension" : "com.apple.Siri-Settings.extension"
    }
}

struct SummaryNotice: Equatable {
    var title: String
    var message: String
    var details: String?
    var settings: SettingsLink?
    var canSummarise = true

    var showsSettings: Bool { settings != nil }

    static func make(status: ProcessingStatus?, statusMessage: String?, hasTranscript: Bool,
                     currentReason: SummaryUnavailable?) -> SummaryNotice {
        if status == .unavailable, let currentReason { return SummaryNotice(currentReason) }
        if status == .failed {
            return SummaryNotice(title: "No summary \u{2014} summarising failed", message: "Click Summarise to try again.",
                                 details: statusMessage ?? "Unknown error")
        }
        return SummaryNotice(title: "No summary yet", message: hasTranscript
            ? "There is a transcript but no summary. Summarise it on this Mac with Apple Intelligence."
            : "Transcribe and summarise this recording on this Mac. Nothing leaves your computer.")
    }
}

extension SummaryNotice {
    init(_ reason: SummaryUnavailable) {
        title = reason.message
        switch reason {
        case .modelNotReady:
            message = "Your transcript is summarised by itself once the download finishes."
            settings = .appleIntelligence
        case .languageMismatch(let mac, let siri):
            let english = Locale(identifier: "en")
            func name(_ identifier: String) -> String { english.localizedString(forIdentifier: identifier) ?? identifier }
            let region = Locale.Language(identifier: mac).region.flatMap { english.localizedString(forRegionCode: $0.identifier) }
            message = "Your Mac is set to \(name(mac)) and Siri to \(name(siri)). Apple Intelligence needs them to be the same. "
                + "In System Settings \u{2192} General \u{2192} Language & Region, add \(name(siri)) and move it to the top"
                + (region.map { " (keep Region: \($0))" } ?? "") + ", then restart."
            settings = .languageAndRegion
        case .appleIntelligenceOff:
            message = "Turn it on in System Settings, then click Summarise."
            settings = .appleIntelligence
        case .unsupportedLanguage:
            message = "Change the Apple Intelligence language in System Settings, then click Summarise."
            settings = .appleIntelligence
        case .deviceNotEligible, .requiresMacOS26:
            message = "The transcript and audio are still here."
            canSummarise = false
        }
    }
}

extension ProcessingLogic {
    /// The full error: its description, then its type, case and domain/code, so it can be pasted into a bug report.
    static func errorDetails(_ error: Error) -> String {
        let description = error.localizedDescription
        let reflected = String(reflecting: error)
        let nsError = error as NSError
        var parts = [description]
        if reflected != description { parts.append(reflected) }
        if !reflected.contains("Code=\(nsError.code)") { parts.append("\(nsError.domain) code \(nsError.code)") }
        return parts.joined(separator: "\n")
    }
}

enum ProcessingStage: Equatable {
    case transcribing(progress: Double? = nil)
    case recognisingSpeakers(progress: Double? = nil)
    case detectingLanguage
    case summarising(part: Int, of: Int)
    case combining

    func text(for name: String) -> String {
        switch self {
        case .transcribing(let progress?): return "Transcribing \(name)\u{2026} \(ProcessingLogic.percent(progress))"
        case .transcribing: return "Transcribing \(name)\u{2026}"
        case .recognisingSpeakers(let progress?): return "Recognising speakers in \(name)\u{2026} \(ProcessingLogic.percent(progress))"
        case .recognisingSpeakers: return "Recognising speakers in \(name)\u{2026}"
        case .detectingLanguage: return "Detecting the language of \(name)\u{2026}"
        case .summarising(let part, let total) where total > 1: return "Summarising \(name)\u{2026} (\(part)/\(total))"
        case .summarising: return "Summarising \(name)\u{2026}"
        case .combining: return "Summarising \(name)\u{2026} (combining)"
        }
    }
}

enum ProcessingLogic {
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

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

    static let echoWindow: TimeInterval = 3
    static let echoSimilarity = 0.7

    /// One transcript from the two stems, by start time. A microphone segment that repeats a system segment spoken at
    /// the same time is the other participants bleeding into the microphone, so only the system one is kept.
    static func mergeSpeakers(you: [TranscriptSegment], others: [TranscriptSegment]) -> [TranscriptSegment] {
        let others = others.map { $0.with(speaker: .others) }
        let you = you.filter { mine in !others.contains { isEcho(mine, of: $0) } }.map { $0.with(speaker: .you) }
        return (others + you).enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
    }

    static func isEcho(_ segment: TranscriptSegment, of source: TranscriptSegment) -> Bool {
        abs(segment.start - source.start) <= echoWindow && similarity(segment.text, source.text) >= echoSimilarity
    }

    /// Dice coefficient of the words, ignoring case, accents and punctuation.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var remaining = Dictionary(right.map { ($0, 1) }, uniquingKeysWith: +)
        let shared = left.filter { word in
            guard let count = remaining[word], count > 0 else { return false }
            remaining[word] = count - 1
            return true
        }.count
        return 2 * Double(shared) / Double(left.count + right.count)
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Characters of transcript per model call, leaving room for instructions, schema and the reply.
    /// A model that is not ready reports a context size of 0, so fall back to the macOS 26 window.
    static func chunkCharacters(contextSize: Int) -> Int {
        let reservedTokens = 2200, charactersPerToken = 3
        let tokens = contextSize > reservedTokens ? contextSize : 4096
        return max(1500, (tokens - reservedTokens) * charactersPerToken)
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
                                   segments: [TranscriptSegment], names: SpeakerNames = [:]) -> String {
        """
        # \(language.headings.transcript): \(baseName(audioName))

        _\(audioName) \u{00B7} \(language.displayName) \u{00B7} on-device \(engine)_

        \(segments.map { $0.line(language, names: names) }.joined(separator: "\n\n"))

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
                                            engine: meeting.transcriptEngine ?? "transcription", segments: content.segments,
                                            names: content.names))
        }
        return parts.joined(separator: "\n")
    }

    private static func baseName(_ audioName: String) -> String {
        URL(fileURLWithPath: audioName).deletingPathExtension().lastPathComponent
    }

    /// `--process <audio>` transcribes, recognises speakers and summarises; `--recognise-speakers <audio>` only
    /// recognises the speakers of its stored transcript.
    static func processArguments(_ arguments: [String]) -> (audio: URL, language: MeetingLanguage?, recogniseOnly: Bool)? {
        guard let index = arguments.firstIndex(where: { $0 == "--process" || $0 == "--recognise-speakers" }),
              index + 1 < arguments.count else { return nil }
        let language = arguments.firstIndex(of: "--language").flatMap {
            $0 + 1 < arguments.count ? MeetingLanguage(rawValue: arguments[$0 + 1]) : nil
        }
        return (URL(fileURLWithPath: arguments[index + 1]), language, arguments[index] == "--recognise-speakers")
    }
}
