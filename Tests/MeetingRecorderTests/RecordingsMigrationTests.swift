import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func write(_ text: String, to folder: URL, _ name: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: folder.appendingPathComponent(name))
}

private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

let recordingsMigrationTests: [(name: String, run: () throws -> Void)] = [
    ("recordings live next to the database", {
        check(AppPaths.recordings.lastPathComponent == "Recordings", "folder name")
        check(AppPaths.recordings.deletingLastPathComponent() == AppPaths.database.deletingLastPathComponent(), "same folder")
    }),
    ("the migration plan moves every file but .DS_Store and leaves name clashes behind", {
        let plan = RecordingsMigration.plan(old: ["b.m4a", ".DS_Store", "a.m4a", "a.stem-mic.m4a", "c.summary.md"],
                                            new: ["b.m4a"])
        check(plan.moves == ["a.m4a", "a.stem-mic.m4a", "c.summary.md"], "moves \(plan.moves)")
        check(plan.clashes == ["b.m4a"], "clashes \(plan.clashes)")
        check(RecordingsMigration.plan(old: [], new: ["a.m4a"]) == .init(), "nothing left to move")
        check(RecordingsMigration.canRemove(remaining: [".DS_Store"]), ".DS_Store alone")
        check(!RecordingsMigration.canRemove(remaining: [".DS_Store", "b.m4a"]), "a file left behind")
    }),
    ("stored audio paths inside the old folder become bare file names", {
        let old = "/Users/me/Movies/MeetingRecordings"
        func rewrite(_ stored: String, leftBehind: Set<String> = []) -> String? {
            RecordingsMigration.rewrittenAudioFile(stored, oldFolder: old, leftBehind: leftBehind)
        }
        check(rewrite("Meeting-2026-10-15-1430.m4a") == nil, "bare names stay")
        check(rewrite(old + "/Meeting-2026-10-15-1430.m4a") == "Meeting-2026-10-15-1430.m4a", "absolute path")
        check(rewrite(old + "/b.m4a", leftBehind: ["b.m4a"]) == nil, "a file left behind keeps its path")
        check(rewrite(old + "/sub/a.m4a") == nil, "nested files are not ours")
        check(rewrite("/Users/me/Movies/MeetingRecordingsOld/a.m4a") == nil, "a sibling folder")
        let home = RecordingsMigration.rewrittenAudioFile("~/Movies/MeetingRecordings/a.m4a",
                                                          oldFolder: NSHomeDirectory() + "/Movies/MeetingRecordings",
                                                          leftBehind: [])
        check(home == "a.m4a", "tilde path")
    }),
    ("only the app's recording and processing jobs hold the migration back", {
        check(RecordingsMigration.isRecordingJob("/Applications/WorkTime.app/Contents/MacOS/MeetingRecorder --process /x/a.m4a"), "process")
        check(RecordingsMigration.isRecordingJob("/Users/me/Library/Application Support/MeetingRecorder/bin/meetingrecorder --record 60"), "record")
        check(RecordingsMigration.isRecordingJob("MeetingRecorder --resummarise a.m4a"), "resummarise")
        check(!RecordingsMigration.isRecordingJob("/Applications/WorkTime.app/Contents/MacOS/MeetingRecorder"), "the app itself")
        check(!RecordingsMigration.isRecordingJob("/usr/bin/other --process"), "another program")
        check(!RecordingsMigration.isRecordingJob("MeetingRecorder --processed"), "whole flags only")
    }),
    ("the migration renames files, never overwrites, rewrites stored paths and is safe to run again", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("Support/meetings.sqlite"))
        let old = folder.appendingPathComponent("Movies/MeetingRecordings", isDirectory: true)
        let new = folder.appendingPathComponent("Support/Recordings", isDirectory: true)
        for name in ["a.m4a", "a.stem-mic.m4a", "a.stem-system.m4a", "a.transcript.md", "b.m4a", ".DS_Store"] {
            try write("old \(name)", to: old, name)
        }
        try write("new b", to: new, "b.m4a")
        try write("moved earlier", to: new, "c.m4a")
        try store.setNotes(old.appendingPathComponent("a.m4a").path, "absolute")
        try store.setNotes(old.appendingPathComponent("b.m4a").path, "clash")
        try store.setNotes("c.m4a", "bare")

        let first = try RecordingsMigration.run(from: old, to: new, store: store)
        check(first.moved == ["a.m4a", "a.stem-mic.m4a", "a.stem-system.m4a", "a.transcript.md"], "moved \(first.moved)")
        check(first.clashes == ["b.m4a"] && first.failed.isEmpty, "clashes \(first.clashes) \(first.failed)")
        check(first.rewritten == 1 && !first.removedOldFolder, "outcome \(first)")
        check(names(in: old) == [".DS_Store", "b.m4a"], "left behind \(names(in: old))")
        check(try String(contentsOf: new.appendingPathComponent("b.m4a"), encoding: .utf8) == "new b", "not overwritten")
        check(try String(contentsOf: new.appendingPathComponent("a.m4a"), encoding: .utf8) == "old a.m4a", "moved content")
        let stored = Set(try store.meetings().map(\.audioFile))
        check(stored == ["a.m4a", old.appendingPathComponent("b.m4a").path, "c.m4a"], "stored \(stored)")

        let again = try RecordingsMigration.run(from: old, to: new, store: store)
        check(again.moved.isEmpty && again.rewritten == 0 && again.clashes == ["b.m4a"], "idempotent \(again)")

        try FileManager.default.removeItem(at: old.appendingPathComponent("b.m4a"))
        let last = try RecordingsMigration.run(from: old, to: new, store: store)
        check(last.removedOldFolder && !FileManager.default.fileExists(atPath: old.path), "old folder removed")
        check(names(in: new) == ["a.m4a", "a.stem-mic.m4a", "a.stem-system.m4a", "a.transcript.md", "b.m4a", "c.m4a"],
              "new folder \(names(in: new))")
    }),
]
