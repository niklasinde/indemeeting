import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func tempFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func withStore(_ body: (MeetingStore, URL) throws -> Void) throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(try MeetingStore.open(at: folder.appendingPathComponent("db/meetings.sqlite")), folder)
}

private func count(_ table: String, in folder: URL) throws -> Int64 {
    let db = try SQLiteDatabase(path: folder.appendingPathComponent("db/meetings.sqlite").path)
    return try db.query("SELECT count(*) FROM \(table)") { $0.int64(0) }.first ?? -1
}

private let standup = MeetingSummary(
    title: "Daglig standup",
    actionItems: [.init(task: "Skicka rapporten", owner: "Anna"), .init(task: "Boka rum", owner: nil)],
    topics: [.init(title: "Release", points: ["Releasen är på tisdag.", "Kundteamet informeras."])])

private let segments = [TranscriptSegment(start: 4, text: "Vi har sex öppna tickets."),
                        TranscriptSegment(start: 12, text: "Testdata saknas.")]

let storeTests: [(name: String, run: () throws -> Void)] = [
    ("the database is created with WAL, foreign keys and the latest schema", {
        try withStore { store, folder in
            check(try store.schemaVersion() == MeetingStore.migrations.count, "schema version")
            let db = try SQLiteDatabase(path: folder.appendingPathComponent("db/meetings.sqlite").path)
            check(try db.query("PRAGMA journal_mode") { $0.string(0) } == ["wal"], "wal")
            check(try db.query("PRAGMA foreign_keys") { $0.int64(0) } == [1], "foreign keys")
            try store.setNotes("Meeting-2026-10-15-1430.m4a", "kept")
            let reopened = try MeetingStore.open(at: folder.appendingPathComponent("db/meetings.sqlite"))
            check(try reopened.meetings().map(\.notes) == ["kept"], "data survives reopening")
            check(try reopened.schemaVersion() == MeetingStore.migrations.count, "no migration ran twice")
        }
    }),

    ("a database that cannot be opened makes the store unavailable instead of keeping data in memory", {
        let folder = try tempFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        for url in [folder.appendingPathComponent("meetings.sqlite"), folder.appendingPathComponent("db/meetings.sqlite")] {
            let store = MeetingStore.openDefault(at: url)
            check(!store.isAvailable && store.openError?.url == url, "unavailable for \(url.path)")
            check(store.openError?.existingLocation == folder, "reveals the folder that exists")
            check(store.openError?.errorDescription?.contains("could not be opened") == true, "says why")
            var refused = 0
            for write in [{ try store.setNotes("Meeting-2026-10-15-1430.m4a", "lost") },
                          { try store.saveTranscript("Meeting-2026-10-15-1430.m4a", segments: segments, language: .swedish, engine: "x") },
                          { _ = try store.meetings() }] as [() throws -> Void] {
                do { try write() } catch is DatabaseUnavailable { refused += 1 } catch {}
            }
            check(refused == 3, "reads and writes throw, \(refused)")
        }
        check(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "nothing created")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let store = MeetingStore.openDefault(at: folder.appendingPathComponent("meetings.sqlite"))
        check(store.isAvailable && store.openError == nil, "opens once the folder is writable")
    }),

    ("migrations run forward once each", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try SQLiteDatabase(path: folder.appendingPathComponent("m.sqlite").path)
        let first = "CREATE TABLE t (a TEXT); INSERT INTO t VALUES ('x')"
        try MeetingStore.migrate(db, [first])
        try MeetingStore.migrate(db, [first, "ALTER TABLE t ADD COLUMN b TEXT DEFAULT 'y'"])
        try MeetingStore.migrate(db, [first, "ALTER TABLE t ADD COLUMN b TEXT DEFAULT 'y'"])
        check(try db.query("SELECT a, b FROM t") { $0.string(0) + $0.string(1) } == ["xy"], "v1 then v2 applied once")
        check(try db.query("SELECT version FROM schema_version ORDER BY version") { $0.int64(0) } == [1, 2], "versions")
        var failed = false
        do { try MeetingStore.migrate(db, [first, "SELECT 1", "CREATE TABLE u (a); SELEKT"]) } catch { failed = true }
        check(try failed && db.query("SELECT count(*) FROM sqlite_master WHERE name = 'u'") { $0.int64(0) } == [0],
              "a failing migration is rolled back")
    }),

    ("migration 2 adds a speaker to transcript segments and keeps old rows without one", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meetings.sqlite")
        let old = try SQLiteDatabase(path: url.path)
        try MeetingStore.migrate(old, Array(MeetingStore.migrations.prefix(1)))
        try old.run("INSERT INTO meetings (id, audio_file, created) VALUES (1, 'Meeting-2026-10-14-0900.m4a', 0)")
        try old.run("INSERT INTO transcript_segments (meeting_id, position, start, text) VALUES (1, 0, 3, 'Gammal.')")
        let store = try MeetingStore.open(at: url)
        check(try store.schemaVersion() == 2, "migrated to v2")
        check(try store.content(of: "Meeting-2026-10-14-0900.m4a")?.segments == [TranscriptSegment(start: 3, text: "Gammal.")],
              "old row has no speaker")
        let labelled = [TranscriptSegment(start: 1, text: "Hej.", speaker: .you),
                        TranscriptSegment(start: 2, text: "Hallå.", speaker: .others)]
        try store.saveTranscript("Meeting-2026-10-15-1430.m4a", segments: labelled, language: .swedish, engine: "x")
        let content = try store.content(of: "Meeting-2026-10-15-1430.m4a")
        check(content?.segments == labelled, "speakers read back")
        check(ProcessingLogic.exportMarkdown(content!).contains("[00:00:01] Du: Hej.\n\n[00:00:02] Övriga: Hallå."), "export")
    }),

    ("transcript, summary, notes, title and checks are stored and read back", {
        try withStore { store, _ in
            let name = "Meeting-2026-10-15-1430.m4a"
            try store.saveTranscript(name, segments: segments, language: .swedish, engine: "DictationTranscriber")
            try store.saveSummary(name, ParsedSummary(standup))
            try store.setNotes(name, "Fråga Johan.")
            try store.setTitleOverride(name, "Standup")
            var content = try store.content(of: name)
            check(content?.segments == segments, "segments")
            let meeting = content?.meeting
            check(meeting?.language == .swedish && meeting?.transcriptEngine == "DictationTranscriber", "language and engine")
            check(meeting?.title == "Standup" && meeting?.aiTitle == "Daglig standup", "titles")
            check(meeting?.notes == "Fråga Johan." && meeting?.status == .summarised, "notes and status")
            check(meeting?.created == RecordingLogic.date(fromFileName: name), "created from the name")
            let items = content?.summary.actionItems ?? []
            check(items.map(\.owner) == ["Anna", nil] && items.map(\.task) == ["Skicka rapporten", "Boka rum"], "action items")
            check(content?.summary.sections == [SummarySection(heading: "Release", lines: [.bullet("Releasen är på tisdag."),
                                                                                          .bullet("Kundteamet informeras.")])],
                  "topics and points")

            try store.setChecked(actionItem: Int64(items[0].key)!, true)
            try store.saveSummary(name, ParsedSummary(MeetingSummary(title: "Ny", actionItems: standup.actionItems + [
                .init(task: "Ny punkt", owner: nil)], topics: [])))
            content = try store.content(of: name)
            check(content?.summary.actionItems.map(\.done) == [true, false, false], "checks survive a new summary")

            try store.saveSummary(name, ParsedSummary(unavailable: "Apple Intelligence is off"))
            content = try store.content(of: name)
            check(content?.summary.isEmpty == true && content?.meeting.aiTitle == nil, "unavailable clears the summary")
            check(content?.meeting.status == .unavailable && content?.meeting.statusMessage == "Apple Intelligence is off", "reason")
            check(content?.segments == segments && content?.meeting.notes == "Fråga Johan.", "transcript and notes kept")

            try store.setFailed(name, message: "No speech")
            check(try store.content(of: name)?.meeting.status == .failed, "failure recorded")
            try store.setDurations([name: 61.5, "unknown.m4a": 3])
            check(try store.meetings().map(\.duration) == [61.5], "duration, unknown files ignored")
            check(try store.content(of: "unknown.m4a") == nil, "no row for an unknown file")
        }
    }),

    ("full-text search covers titles, transcript, summary and notes", {
        try withStore { store, _ in
            let a = "Meeting-2026-10-15-1430.m4a", b = "Meeting-2026-10-16-0900.m4a"
            try store.saveTranscript(a, segments: segments, language: .swedish, engine: "x")
            try store.saveSummary(a, ParsedSummary(standup))
            try store.setNotes(b, "Kaffe med kundteamet")
            try store.setTitleOverride(b, "Budget Q4")
            check(try store.search("") == nil, "empty query")
            check(try store.search("STANDUP") == [a], "ai title, case")
            check(try store.search("oppna") == [a], "transcript, diacritics")
            check(try store.search("tisdag") == [a], "summary point")
            check(try store.search("anna") == [a], "action item owner")
            check(try store.search("kaffe") == [b], "notes")
            check(try store.search("budg") == [b], "title prefix")
            check(try store.search("kundteamet") == [a, b], "both")
            check(try store.search("kundteamet kaffe") == [b], "every word")
            check(try store.search("\"or") == [], "quotes are harmless")
            try store.setNotes(b, "Te")
            check(try store.search("kaffe") == [], "index follows edits")
        }
    }),

    ("sidecar files are imported once and left untouched", {
        try withStore { store, folder in
            let recordings = folder.appendingPathComponent("rec", isDirectory: true)
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            let first = recordings.appendingPathComponent("Meeting-2026-10-15-1430.m4a")
            let second = recordings.appendingPathComponent("Meeting-2026-10-14-0900.m4a")
            let sidecars: [URL: String] = [
                ProcessingLogic.transcriptURL(for: first): ProcessingLogic.transcriptMarkdown(
                    audioName: first.lastPathComponent, language: .swedish, engine: "DictationTranscriber", segments: segments),
                ProcessingLogic.summaryURL(for: first): ProcessingLogic.summaryMarkdown(standup, audioName: first.lastPathComponent,
                                                                                        language: .swedish),
                ProcessingLogic.notesURL(for: first): "Mina anteckningar\n",
                ProcessingLogic.metaURL(for: first): String(decoding: MeetingMeta(title: "Retro", checked: ["Boka rum": true]).encoded(),
                                                            as: UTF8.self),
                ProcessingLogic.summaryURL(for: second): ProcessingLogic.unavailableMarkdown(
                    .appleIntelligenceOff, audioName: second.lastPathComponent, language: .english),
            ]
            for (url, text) in sidecars { try text.write(to: url, atomically: true, encoding: .utf8) }
            let audio = ["Meeting-2026-10-15-1430.m4a", "Meeting-2026-10-14-0900.m4a", "Interview.mp3",
                         "Meeting-2026-10-16-0800.recording.m4a"]
            for name in audio { try Data("audio".utf8).write(to: recordings.appendingPathComponent(name)) }
            let created = Date(timeIntervalSince1970: 2_000_000_000)
            let files = try FileManager.default.contentsOfDirectory(atPath: recordings.path).map { FolderItem(name: $0, created: created) }

            check(try store.sync(folder: recordings, files: files) == 3, "three recordings imported")
            try store.setNotes(first.lastPathComponent, "Ändrad")
            check(try store.sync(folder: recordings, files: files) == 0, "second sync imports nothing")
            check(try store.meetings().count == 3, "one row each")

            let content = try store.content(of: first.lastPathComponent)
            check(content?.segments == segments && content?.meeting.language == .swedish, "transcript")
            check(content?.meeting.transcriptEngine == "DictationTranscriber", "engine")
            check(content?.meeting.title == "Retro" && content?.meeting.aiTitle == "Daglig standup", "titles")
            check(content?.summary.actionItems.map(\.done) == [false, true], "checked from meta")
            check(content?.summary.sections.first?.lines.count == 2, "topics")
            check(content?.meeting.notes == "Ändrad", "edits are not overwritten by a later sync")
            let unavailable = try store.content(of: second.lastPathComponent)?.meeting
            check(unavailable?.status == .unavailable && unavailable?.statusMessage == SummaryUnavailable.appleIntelligenceOff.message,
                  "reason \(unavailable?.statusMessage ?? "nil")")
            let plain = try store.content(of: "Interview.mp3")?.meeting
            check(plain?.status == ProcessingStatus.none && plain?.created == created, "no sidecars, dated by the file")
            for (url, text) in sidecars {
                check((try? String(contentsOf: url, encoding: .utf8)) == text, "\(url.lastPathComponent) unchanged")
            }
        }
    }),

    ("deleting a meeting removes its rows and search entries", {
        try withStore { store, folder in
            let name = "Meeting-2026-10-15-1430.m4a"
            try store.saveTranscript(name, segments: segments, language: .swedish, engine: "x")
            try store.saveSummary(name, ParsedSummary(standup))
            try store.setNotes("Meeting-2026-10-16-0900.m4a", "other")
            try store.delete(name)
            check(try store.content(of: name) == nil, "meeting gone")
            check(try store.search("tickets") == [], "not found")
            for table in ["transcript_segments", "action_items", "summary_topics", "summary_points"] {
                check(try count(table, in: folder) == 0, "\(table) emptied")
            }
            check(try count("meetings_fts", in: folder) == 1 && store.meetings().count == 1, "other meeting kept")
        }
    }),

    ("a meeting exports summary, action items, notes and transcript as one markdown file", {
        try withStore { store, _ in
            let name = "Meeting-2026-10-15-1430.m4a"
            try store.saveTranscript(name, segments: segments, language: .swedish, engine: "DictationTranscriber")
            try store.saveSummary(name, ParsedSummary(standup))
            try store.setNotes(name, "Fråga Johan.\n")
            let items = try store.content(of: name)?.summary.actionItems ?? []
            try store.setChecked(actionItem: Int64(items[1].key)!, true)
            let markdown = ProcessingLogic.exportMarkdown(try store.content(of: name)!)
            check(markdown.hasPrefix("# Daglig standup\n"), "title")
            check(markdown.contains("## Åtgärdspunkter\n\n- [ ] Anna: Skicka rapporten\n- [x] Boka rum\n"), "action items \(markdown)")
            check(markdown.contains("## Release\n\n- Releasen är på tisdag."), "topics")
            check(markdown.contains("## Anteckningar\n\nFråga Johan.\n"), "notes")
            check(markdown.contains("[00:00:04] Vi har sex öppna tickets."), "transcript")
            check(LibraryLogic.parseSummary(markdown).actionItems.map(\.done) == [false, true], "parses back")

            try store.saveSummary(name, ParsedSummary(unavailable: "Apple Intelligence is off"))
            let fallback = ProcessingLogic.exportMarkdown(try store.content(of: name)!)
            check(fallback.hasPrefix("# Meeting\n\nApple Intelligence is off\n"), "no summary \(fallback)")
        }
    }),
]
