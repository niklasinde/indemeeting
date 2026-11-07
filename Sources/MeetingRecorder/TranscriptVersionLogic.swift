import Foundation

/// A meeting's transcript and the summary made from it, as kept when a re-transcription replaces them.
struct TranscriptSnapshot: Equatable {
    var segments: [TranscriptSegment]
    var speakers: [SpeakerProfile] = []
    var language: MeetingLanguage?
    var languageDetected = false
    var engine: String?
    var transcribedAt: Date?
    var summary = ParsedSummary()

    var names: SpeakerNames { SpeakerNames(speakers.compactMap { profile in profile.name.map { (profile.speaker, $0) } }) { $1 } }
}

/// An earlier transcript of a meeting, as listed in its "Earlier versions" menu.
struct TranscriptVersionInfo: Equatable, Identifiable {
    let id: Int64
    let transcribedAt: Date?
    let engine: String?
}

enum TranscriptVersionLogic {
    struct RestorePlan: Equatable {
        /// What becomes the meeting's transcript and summary.
        let current: TranscriptSnapshot
        /// The transcript being replaced, kept as a version; nil when there is none to keep.
        let archive: TranscriptSnapshot?
    }

    static func isWorthKeeping(_ snapshot: TranscriptSnapshot) -> Bool { !snapshot.segments.isEmpty }

    static func restorePlan(current: TranscriptSnapshot, restoring version: TranscriptSnapshot) -> RestorePlan {
        RestorePlan(current: version, archive: isWorthKeeping(current) ? current : nil)
    }

    /// "5 Nov 14:02 · Whisper Large v3 Turbo", or "Live · Apple Speech · 5 Nov 14:02" for the live transcript.
    static func label(_ version: TranscriptVersionInfo, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let engine = version.engine, engine == TranscriptionEngine.liveValue else {
            return LibraryLogic.transcriptionLabel(at: version.transcribedAt, engine: version.engine, locale: locale, timeZone: timeZone)
        }
        return TranscriptionEngine.displayName(stored: engine) + " \u{00B7} "
            + LibraryLogic.transcriptionLabel(at: version.transcribedAt, engine: nil, locale: locale, timeZone: timeZone)
    }

    /// The finished live lines as transcript segments, `offset` seconds into the meeting's audio.
    static func liveSegments(_ lines: [LiveLine], offset: TimeInterval) -> [TranscriptSegment] {
        lines.filter { $0.isFinal && !$0.text.isEmpty }
            .map { TranscriptSegment(start: $0.start + offset, text: $0.text, speaker: $0.speaker) }
    }

    /// The live transcript to keep as a version: a new one, or `existing` with a continued recording's lines added.
    /// Nil when nothing was heard.
    static func liveSnapshot(_ segments: [TranscriptSegment], appendingTo existing: TranscriptSnapshot?,
                             language: MeetingLanguage?, at date: Date) -> TranscriptSnapshot? {
        guard !segments.isEmpty else { return nil }
        guard var snapshot = existing else {
            return TranscriptSnapshot(segments: segments, language: language, engine: TranscriptionEngine.liveValue, transcribedAt: date)
        }
        snapshot.segments = (snapshot.segments + segments).sorted { $0.start < $1.start }
        return snapshot
    }

    struct ComparedRow: Equatable {
        let version: TranscriptSegment?
        let current: TranscriptSegment?
    }

    /// Two transcripts side by side: a paragraph shares a row with the other side's paragraph that starts before
    /// either one's next paragraph, otherwise it stands alone, in order of time.
    static func sideBySide(version: [TranscriptSegment], current: [TranscriptSegment]) -> [ComparedRow] {
        var rows: [ComparedRow] = []
        var left = version[...], right = current[...]
        while left.first != nil || right.first != nil {
            let a = left.first, b = right.first
            let nextA = left.dropFirst().first?.start ?? .infinity, nextB = right.dropFirst().first?.start ?? .infinity
            if let a, let b, b.start < nextA, a.start < nextB {
                rows.append(ComparedRow(version: a, current: b))
                left = left.dropFirst()
                right = right.dropFirst()
            } else if let a, b.map({ a.start <= $0.start }) ?? true {
                rows.append(ComparedRow(version: a, current: nil))
                left = left.dropFirst()
            } else {
                rows.append(ComparedRow(version: nil, current: b))
                right = right.dropFirst()
            }
        }
        return rows
    }

    /// `meeting` as it was when `snapshot` was its transcript, for showing a version read-only.
    static func content(of meeting: Meeting, as snapshot: TranscriptSnapshot) -> MeetingContent {
        var shown = meeting
        shown.language = snapshot.language
        shown.languageDetected = snapshot.languageDetected
        shown.transcriptEngine = snapshot.engine
        shown.transcribedAt = snapshot.transcribedAt
        shown.transcribed = !snapshot.segments.isEmpty
        shown.aiTitle = snapshot.summary.title
        shown.status = snapshot.summary.status
        shown.statusMessage = snapshot.summary.unavailable
        shown.summarised = shown.status == .summarised
        shown.summaryEngine = snapshot.summary.engine
        return MeetingContent(meeting: shown, segments: snapshot.segments, summary: snapshot.summary, names: snapshot.names)
    }

    /// The segments, speakers and summary as JSON; the rest is stored in columns of their own.
    static func encode(_ snapshot: TranscriptSnapshot) throws -> Data {
        let summary = snapshot.summary
        return try JSONEncoder().encode(Body(
            segments: snapshot.segments.map { Body.Segment(start: $0.start, text: $0.text, speaker: $0.speaker?.rawValue) },
            speakers: snapshot.speakers.map { Body.Voice(speaker: $0.speaker.rawValue, name: $0.name, embedding: $0.embedding) },
            title: summary.title, unavailable: summary.unavailable, summaryEngine: summary.engine,
            actionItems: summary.actionItems.map { Body.Item(task: $0.task, owner: $0.owner, done: $0.done) },
            topics: summary.sections.map { Body.Topic(title: $0.heading, points: $0.lines.map(\.text)) }))
    }

    static func decode(_ data: Data, language: MeetingLanguage?, languageDetected: Bool, engine: String?,
                       transcribedAt: Date?) throws -> TranscriptSnapshot {
        let body = try JSONDecoder().decode(Body.self, from: data)
        let summary = ParsedSummary(
            title: body.title,
            actionItems: body.actionItems.enumerated().map { index, item in
                ChecklistItem(key: "version-\(index)", task: item.task, owner: item.owner, done: item.done)
            },
            sections: body.topics.map { SummarySection(heading: $0.title, lines: $0.points.map(MarkdownBlock.bullet)) },
            unavailable: body.unavailable, engine: body.summaryEngine)
        return TranscriptSnapshot(
            segments: body.segments.map { TranscriptSegment(start: $0.start, text: $0.text, speaker: $0.speaker.flatMap(Speaker.init(rawValue:))) },
            speakers: body.speakers.compactMap { voice in
                Speaker(rawValue: voice.speaker).map { SpeakerProfile(speaker: $0, name: voice.name, embedding: voice.embedding) }
            },
            language: language, languageDetected: languageDetected, engine: engine, transcribedAt: transcribedAt, summary: summary)
    }

    private struct Body: Codable {
        struct Segment: Codable { let start: Double; let text: String; let speaker: String? }
        struct Voice: Codable { let speaker: String; let name: String?; let embedding: [Float]? }
        struct Item: Codable { let task: String; let owner: String?; let done: Bool }
        struct Topic: Codable { let title: String; let points: [String] }

        let segments: [Segment]
        let speakers: [Voice]
        let title: String?
        let unavailable: String?
        var summaryEngine: String?
        let actionItems: [Item]
        let topics: [Topic]
    }
}
