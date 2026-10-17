import Foundation

/// Where the app keeps its data. `--data-dir <folder>` or `MEETING_RECORDER_DATA_DIR` moves both the recordings and
/// the database into that folder, so a copy of the library can be used without touching the real one.
enum AppPaths {
    static let dataDirectory: URL? = {
        let arguments = CommandLine.arguments
        let flag = arguments.firstIndex(of: "--data-dir").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        return (flag ?? ProcessInfo.processInfo.environment["MEETING_RECORDER_DATA_DIR"])
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }()

    static var recordings: URL {
        dataDirectory?.appendingPathComponent("MeetingRecordings", isDirectory: true)
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeetingRecordings", isDirectory: true)
    }

    static var database: URL { support.appendingPathComponent("meetings.sqlite") }
    static var models: URL { support.appendingPathComponent("Models", isDirectory: true) }

    private static var support: URL {
        dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecorder", isDirectory: true)
    }
}

enum ProcessingStatus: String {
    case none
    case summarised
    case unavailable
    case failed
}

struct Meeting: Equatable {
    let id: Int64
    let audioFile: String
    let created: Date
    var duration: TimeInterval?
    var language: MeetingLanguage?
    var titleOverride: String?
    var aiTitle: String?
    var notes: String
    var status: ProcessingStatus
    var statusMessage: String?
    var transcriptEngine: String?
    var transcribed = false
    var summarised = false
    /// Whether the language was detected rather than chosen.
    var languageDetected = false

    var title: String { LibraryLogic.title(override: titleOverride, aiTitle: aiTitle) }
}

/// Why the database could not be opened. The store then refuses every read and write instead of keeping data that
/// would be lost.
struct DatabaseUnavailable: LocalizedError {
    let url: URL
    let reason: String

    var errorDescription: String? { "The meeting database could not be opened: \(reason)" }

    /// The database file, or the nearest folder above it that exists.
    var existingLocation: URL {
        var url = url
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        return url
    }
}

struct MeetingContent: Equatable {
    let meeting: Meeting
    let segments: [TranscriptSegment]
    /// Action item keys are their row ids.
    let summary: ParsedSummary
    var names: SpeakerNames = [:]
}

/// All meeting data except the audio. Every call runs on one serial queue; writes post `didChange` on the main queue.
final class MeetingStore: @unchecked Sendable {
    static let didChange = Notification.Name("MeetingStoreDidChange")
    static let activityDidChange = Notification.Name("ActivityStoreDidChange")

    static let migrations = [
        """
        CREATE TABLE meetings (
            id INTEGER PRIMARY KEY,
            audio_file TEXT NOT NULL UNIQUE,
            created REAL NOT NULL,
            duration REAL,
            language TEXT,
            title_override TEXT,
            ai_title TEXT,
            notes TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'none',
            status_message TEXT,
            transcript_engine TEXT
        );
        CREATE TABLE transcript_segments (
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            start REAL NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (meeting_id, position)
        );
        CREATE TABLE action_items (
            id INTEGER PRIMARY KEY,
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            owner TEXT,
            task TEXT NOT NULL,
            checked INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX action_items_meeting ON action_items(meeting_id);
        CREATE TABLE summary_topics (
            id INTEGER PRIMARY KEY,
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            title TEXT NOT NULL
        );
        CREATE INDEX summary_topics_meeting ON summary_topics(meeting_id);
        CREATE TABLE summary_points (
            topic_id INTEGER NOT NULL REFERENCES summary_topics(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (topic_id, position)
        );
        CREATE VIRTUAL TABLE meetings_fts USING fts5(title, transcript, summary, notes,
                                                     tokenize = 'unicode61 remove_diacritics 2');
        CREATE TRIGGER meetings_fts_delete AFTER DELETE ON meetings BEGIN
            DELETE FROM meetings_fts WHERE rowid = old.id;
        END;
        """,
        "ALTER TABLE transcript_segments ADD COLUMN speaker TEXT",
        """
        ALTER TABLE meetings ADD COLUMN transcribed INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE meetings ADD COLUMN summarised INTEGER NOT NULL DEFAULT 0;
        UPDATE meetings SET transcribed = EXISTS (SELECT 1 FROM transcript_segments WHERE meeting_id = meetings.id),
                            summarised = status = 'summarised';
        """,
        """
        CREATE TABLE speakers (
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            name TEXT,
            embedding BLOB,
            PRIMARY KEY (meeting_id, label)
        );
        CREATE TABLE known_voices (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            embedding BLOB NOT NULL,
            updated REAL NOT NULL
        );
        """,
        """
        CREATE TABLE projects (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            color TEXT NOT NULL
        );
        CREATE TABLE project_rules (
            id INTEGER PRIMARY KEY,
            project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            field TEXT NOT NULL,
            pattern TEXT NOT NULL
        );
        CREATE TABLE activity_blocks (
            id INTEGER PRIMARY KEY,
            start REAL NOT NULL,
            end REAL NOT NULL,
            app_bundle TEXT,
            app_name TEXT,
            window_title TEXT,
            url TEXT,
            repo TEXT,
            branch TEXT,
            ticket TEXT,
            claude_session TEXT,
            claude_title TEXT,
            idle INTEGER NOT NULL DEFAULT 0,
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            typed_excerpt TEXT,
            category TEXT,
            ai_description TEXT,
            ai_project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL
        );
        CREATE INDEX activity_blocks_start ON activity_blocks(start);
        CREATE TABLE activity_ai_cache (
            key TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            description TEXT,
            project TEXT,
            updated REAL NOT NULL
        );
        """,
        "ALTER TABLE meetings ADD COLUMN language_detected INTEGER NOT NULL DEFAULT 0",
    ]

    private static let meetingColumns = """
        id, audio_file, created, duration, language, title_override, ai_title, notes, status, status_message, transcript_engine,
        transcribed, summarised, language_detected
        """

    let openError: DatabaseUnavailable?
    private let connection: SQLiteDatabase?
    private let queue = DispatchQueue(label: "meeting-store")

    init(path: String) throws {
        let db = try SQLiteDatabase(path: path)
        try Self.migrate(db, Self.migrations)
        connection = db
        openError = nil
    }

    private init(unavailable: DatabaseUnavailable) {
        connection = nil
        openError = unavailable
    }

    var isAvailable: Bool { openError == nil }

    var db: SQLiteDatabase {
        get throws {
            guard let connection else { throw openError ?? SQLiteError(message: "not open") }
            return connection
        }
    }

    static func open(at url: URL) throws -> MeetingStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try MeetingStore(path: url.path)
    }

    /// The app's database. When it cannot be opened the store is unavailable: recording still works, but nothing is
    /// read or saved, so no edits disappear into a database that is not there.
    static func openDefault(at url: URL = AppPaths.database) -> MeetingStore {
        do {
            return try open(at: url)
        } catch {
            FileHandle.standardError.write(Data("Could not open \(url.path): \(error.localizedDescription)\n".utf8))
            return MeetingStore(unavailable: DatabaseUnavailable(url: url, reason: error.localizedDescription))
        }
    }

    static func migrate(_ db: SQLiteDatabase, _ migrations: [String]) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        let current = try db.query("SELECT coalesce(max(version), 0) FROM schema_version") { Int($0.int64(0)) }.first ?? 0
        for (index, sql) in migrations.enumerated() where index >= current {
            try db.transaction {
                try db.execute(sql)
                try db.run("INSERT INTO schema_version (version) VALUES (?)", [index + 1])
            }
        }
    }

    func schemaVersion() throws -> Int {
        try read { try db.query("SELECT max(version) FROM schema_version") { Int($0.int64(0)) }.first ?? 0 }
    }

    // MARK: Reading

    func meetings() throws -> [Meeting] {
        try read { try db.query("SELECT \(Self.meetingColumns) FROM meetings", [], Self.meeting) }
    }

    /// Meetings with a transcript whose summary is still to be made, newest first. Failed ones are left out.
    func awaitingSummary() throws -> [Meeting] {
        try read {
            try db.query("""
                SELECT \(Self.meetingColumns) FROM meetings
                WHERE transcribed AND NOT summarised AND status IN (?, ?) ORDER BY created DESC
                """, [ProcessingStatus.none.rawValue, ProcessingStatus.unavailable.rawValue], Self.meeting)
        }
    }

    func content(of audioFile: String) throws -> MeetingContent? {
        try read {
            guard let meeting = try meeting(audioFile) else { return nil }
            let segments = try db.query("SELECT start, text, speaker FROM transcript_segments WHERE meeting_id = ? ORDER BY position",
                                        [meeting.id]) {
                TranscriptSegment(start: $0.double(0), text: $0.string(1), speaker: $0.optionalString(2).flatMap(Speaker.init(rawValue:)))
            }
            let names = try db.query("SELECT label, name FROM speakers WHERE meeting_id = ? AND name IS NOT NULL", [meeting.id]) {
                (Speaker(rawValue: $0.string(0)), $0.string(1))
            }
            return MeetingContent(meeting: meeting, segments: segments, summary: try summary(of: meeting),
                                  names: SpeakerNames(names.compactMap { speaker, name in speaker.map { ($0, name) } }) { $1 })
        }
    }

    /// The audio files of the meetings matching every word of `query` (as a word prefix); nil for an empty query.
    func search(_ query: String) throws -> Set<String>? {
        guard let match = LibraryLogic.ftsQuery(query) else { return nil }
        return try read {
            Set(try db.query("""
                SELECT m.audio_file FROM meetings_fts JOIN meetings m ON m.id = meetings_fts.rowid
                WHERE meetings_fts MATCH ?
                """, [match]) { $0.string(0) })
        }
    }

    // MARK: Writing

    /// Gives every listed audio file a row. A new row takes in what the file's old sidecar files hold, so this
    /// imports each recording once; the sidecar files themselves are only read. Returns the number of new rows.
    @discardableResult
    func sync(folder: URL, files: [FolderItem], timeZone: TimeZone = .current) throws -> Int {
        let known = Set(try read { try db.query("SELECT audio_file FROM meetings") { $0.string(0) } })
        let new = files.filter { LibraryLogic.isListed($0.name) && !known.contains($0.name) }
        guard !new.isEmpty else { return 0 }
        return try write {
            for item in new {
                let audio = folder.appendingPathComponent(item.name)
                func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
                let sidecars = LibraryLogic.sidecars(
                    transcript: text(ProcessingLogic.transcriptURL(for: audio)),
                    summary: text(ProcessingLogic.summaryURL(for: audio)),
                    notes: text(ProcessingLogic.notesURL(for: audio)),
                    meta: try? Data(contentsOf: ProcessingLogic.metaURL(for: audio)))
                let id = try ensure(item.name, created: RecordingLogic.date(fromFileName: item.name, timeZone: timeZone) ?? item.created)
                try db.run("UPDATE meetings SET language = ?, title_override = ?, notes = ?, transcript_engine = ? WHERE id = ?",
                           [sidecars.language?.rawValue, sidecars.titleOverride, sidecars.notes, sidecars.engine, id])
                try replaceSegments(id, sidecars.segments)
                if let summary = sidecars.summary { try replaceSummary(id, summary) }
                try reindex(id)
            }
            return new.count
        }
    }

    /// Replaces the transcript and the meeting's speakers.
    func saveTranscript(_ audioFile: String, segments: [TranscriptSegment], language: MeetingLanguage, detected: Bool = false,
                        engine: String, speakers: [SpeakerProfile] = []) throws {
        try write {
            let id = try ensure(audioFile)
            try db.run("UPDATE meetings SET language = ?, language_detected = ?, transcript_engine = ? WHERE id = ?",
                       [language.rawValue, detected, engine, id])
            try replaceSegments(id, segments)
            try db.run("DELETE FROM speakers WHERE meeting_id = ?", [id])
            for profile in speakers {
                try db.run("INSERT INTO speakers (meeting_id, label, name, embedding) VALUES (?, ?, ?, ?)",
                           [id, profile.speaker.rawValue, profile.name, profile.embedding.map(SpeakerLogic.encode)])
            }
            try reindex(id)
        }
    }

    /// Names a speaker of one meeting, or gives it back its label when `name` is empty. A named speaker's voice is
    /// remembered under that name, so later meetings recognise it.
    func renameSpeaker(_ audioFile: String, _ speaker: Speaker, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? nil : trimmed
        try write {
            let id = try ensure(audioFile)
            try db.run("""
                INSERT INTO speakers (meeting_id, label, name) VALUES (?, ?, ?)
                ON CONFLICT (meeting_id, label) DO UPDATE SET name = excluded.name
                """, [id, speaker.rawValue, name])
            let voice = try db.query("SELECT embedding FROM speakers WHERE meeting_id = ? AND label = ?",
                                     [id, speaker.rawValue]) { $0.optionalData(0) }.first ?? nil
            guard let name, let voice else { return }
            try rememberVoice(name, SpeakerLogic.decode(voice))
        }
    }

    func knownVoices() throws -> [KnownVoice] {
        try read {
            try db.query("SELECT id, name, embedding, updated FROM known_voices ORDER BY name COLLATE NOCASE") {
                KnownVoice(id: $0.int64(0), name: $0.string(1), embedding: SpeakerLogic.decode($0.optionalData(2) ?? Data()),
                           updated: Date(timeIntervalSince1970: $0.double(3)))
            }
        }
    }

    func deleteKnownVoice(_ id: Int64) throws {
        try write { try db.run("DELETE FROM known_voices WHERE id = ?", [id]) }
    }

    /// Replaces the summary; a summary with `unavailable` set clears it and records why. Items checked before stay
    /// checked when the new summary has the same owner and task.
    func saveSummary(_ audioFile: String, _ summary: ParsedSummary) throws {
        try write {
            let id = try ensure(audioFile)
            try replaceSummary(id, summary)
            try reindex(id)
        }
    }

    func setFailed(_ audioFile: String, message: String) throws {
        try write {
            try db.run("UPDATE meetings SET status = ?, status_message = ? WHERE id = ?",
                       [ProcessingStatus.failed.rawValue, message, try ensure(audioFile)])
        }
    }

    func setNotes(_ audioFile: String, _ notes: String) throws {
        try write {
            let id = try ensure(audioFile)
            try db.run("UPDATE meetings SET notes = ? WHERE id = ?", [notes, id])
            try reindex(id)
        }
    }

    func setTitleOverride(_ audioFile: String, _ title: String?) throws {
        try write {
            let id = try ensure(audioFile)
            try db.run("UPDATE meetings SET title_override = ? WHERE id = ?", [title, id])
            try reindex(id)
        }
    }

    func setChecked(actionItem id: Int64, _ checked: Bool) throws {
        try write { try db.run("UPDATE action_items SET checked = ? WHERE id = ?", [checked, id]) }
    }

    func setDurations(_ durations: [String: TimeInterval]) throws {
        try queue.sync {
            try db.transaction {
                for (audioFile, seconds) in durations {
                    try db.run("UPDATE meetings SET duration = ? WHERE audio_file = ?", [seconds, audioFile])
                }
            }
        }
    }

    func delete(_ audioFile: String) throws {
        try write { try db.run("DELETE FROM meetings WHERE audio_file = ?", [audioFile]) }
    }

    // MARK: Internals (on the queue)

    func read<T>(_ body: () throws -> T) throws -> T {
        try queue.sync(execute: body)
    }

    func write<T>(notify: Notification.Name = MeetingStore.didChange, _ body: () throws -> T) throws -> T {
        let result = try queue.sync { try db.transaction(body) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: notify, object: self) }
        return result
    }

    private func ensure(_ audioFile: String, created: Date? = nil) throws -> Int64 {
        let date = created ?? RecordingLogic.date(fromFileName: audioFile) ?? Date()
        try db.run("INSERT OR IGNORE INTO meetings (audio_file, created) VALUES (?, ?)", [audioFile, date.timeIntervalSince1970])
        guard let id = try db.query("SELECT id FROM meetings WHERE audio_file = ?", [audioFile], { $0.int64(0) }).first else {
            throw SQLiteError(message: "no row for \(audioFile)")
        }
        return id
    }

    private func meeting(_ audioFile: String) throws -> Meeting? {
        try db.query("SELECT \(Self.meetingColumns) FROM meetings WHERE audio_file = ?", [audioFile], Self.meeting).first
    }

    private static func meeting(_ row: SQLRow) -> Meeting {
        Meeting(id: row.int64(0), audioFile: row.string(1), created: Date(timeIntervalSince1970: row.double(2)),
                duration: row.optionalDouble(3), language: row.optionalString(4).flatMap(MeetingLanguage.init),
                titleOverride: row.optionalString(5), aiTitle: row.optionalString(6), notes: row.string(7),
                status: ProcessingStatus(rawValue: row.string(8)) ?? .none, statusMessage: row.optionalString(9),
                transcriptEngine: row.optionalString(10), transcribed: row.bool(11), summarised: row.bool(12),
                languageDetected: row.bool(13))
    }

    private func summary(of meeting: Meeting) throws -> ParsedSummary {
        var summary = ParsedSummary(title: meeting.aiTitle)
        summary.unavailable = meeting.status == .unavailable ? meeting.statusMessage : nil
        summary.actionItems = try db.query("SELECT id, owner, task, checked FROM action_items WHERE meeting_id = ? ORDER BY position",
                                           [meeting.id]) {
            ChecklistItem(key: String($0.int64(0)), task: $0.string(2), owner: $0.optionalString(1), done: $0.bool(3))
        }
        let topics = try db.query("SELECT id, title FROM summary_topics WHERE meeting_id = ? ORDER BY position", [meeting.id]) {
            (id: $0.int64(0), title: $0.string(1))
        }
        let points = Dictionary(grouping: try db.query("""
            SELECT p.topic_id, p.text FROM summary_points p JOIN summary_topics t ON t.id = p.topic_id
            WHERE t.meeting_id = ? ORDER BY p.position
            """, [meeting.id]) { (topic: $0.int64(0), text: $0.string(1)) }, by: \.topic)
        summary.sections = topics.map { topic in
            SummarySection(heading: topic.title, lines: (points[topic.id] ?? []).map { .bullet($0.text) })
        }
        return summary
    }

    private func rememberVoice(_ name: String, _ voice: [Float]) throws {
        let known = try db.query("SELECT embedding FROM known_voices WHERE name = ?", [name]) { $0.optionalData(0) }.first ?? nil
        let blended = known.map { SpeakerLogic.blend(SpeakerLogic.decode($0), voice) } ?? voice
        try db.run("""
            INSERT INTO known_voices (name, embedding, updated) VALUES (?, ?, ?)
            ON CONFLICT (name) DO UPDATE SET embedding = excluded.embedding, updated = excluded.updated
            """, [name, SpeakerLogic.encode(blended), Date().timeIntervalSince1970])
    }

    private func replaceSegments(_ id: Int64, _ segments: [TranscriptSegment]) throws {
        try db.run("DELETE FROM transcript_segments WHERE meeting_id = ?", [id])
        try db.run("UPDATE meetings SET transcribed = ? WHERE id = ?", [!segments.isEmpty, id])
        for (position, segment) in segments.enumerated() {
            try db.run("INSERT INTO transcript_segments (meeting_id, position, start, text, speaker) VALUES (?, ?, ?, ?, ?)",
                       [id, position, segment.start, segment.text, segment.speaker?.rawValue])
        }
    }

    private func replaceSummary(_ id: Int64, _ summary: ParsedSummary) throws {
        let checked = Set(try db.query("SELECT coalesce(owner, ''), task FROM action_items WHERE meeting_id = ? AND checked = 1",
                                       [id]) { [$0.string(0), $0.string(1)] })
        try db.run("DELETE FROM action_items WHERE meeting_id = ?", [id])
        try db.run("DELETE FROM summary_topics WHERE meeting_id = ?", [id])
        let status: ProcessingStatus = summary.unavailable != nil ? .unavailable : summary.isEmpty ? .none : .summarised
        try db.run("UPDATE meetings SET ai_title = ?, status = ?, status_message = ?, summarised = ? WHERE id = ?",
                   [summary.unavailable == nil ? summary.title : nil, status.rawValue, summary.unavailable, status == .summarised, id])
        guard summary.unavailable == nil else { return }
        for (position, item) in summary.actionItems.enumerated() {
            try db.run("INSERT INTO action_items (meeting_id, position, owner, task, checked) VALUES (?, ?, ?, ?, ?)",
                       [id, position, item.owner, item.task, item.done || checked.contains([item.owner ?? "", item.task])])
        }
        for (position, section) in summary.sections.enumerated() {
            try db.run("INSERT INTO summary_topics (meeting_id, position, title) VALUES (?, ?, ?)", [id, position, section.heading])
            let topic = try db.lastInsertID
            for (index, line) in section.lines.enumerated() {
                try db.run("INSERT INTO summary_points (topic_id, position, text) VALUES (?, ?, ?)", [topic, index, line.text])
            }
        }
    }

    private func reindex(_ id: Int64) throws {
        try db.run("DELETE FROM meetings_fts WHERE rowid = ?", [id])
        try db.run("""
            INSERT INTO meetings_fts (rowid, title, transcript, summary, notes)
            SELECT id, coalesce(title_override, '') || ' ' || coalesce(ai_title, ''),
                   (SELECT group_concat(text, ' ') FROM transcript_segments WHERE meeting_id = ?1),
                   (SELECT group_concat(text, ' ') FROM (
                        SELECT coalesce(owner || ' ', '') || task AS text FROM action_items WHERE meeting_id = ?1
                        UNION ALL SELECT title FROM summary_topics WHERE meeting_id = ?1
                        UNION ALL SELECT p.text FROM summary_points p JOIN summary_topics t ON t.id = p.topic_id
                                  WHERE t.meeting_id = ?1)),
                   notes
            FROM meetings WHERE id = ?1
            """, [id])
    }
}
