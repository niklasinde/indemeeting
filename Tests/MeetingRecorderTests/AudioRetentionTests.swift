import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func withLibrary(_ body: (MeetingStore, URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
    let recordings = folder.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite")), recordings)
}

private func touch(_ names: [String], in folder: URL) {
    for name in names { FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8)) }
}

private func meeting(expires: Date? = nil, deleted: Date? = nil, transcribed: Bool = true, summarised: Bool = true,
                     file: String = "Meeting-2026-11-06-1000.m4a") -> Meeting {
    Meeting(id: 1, audioFile: file, created: Date(timeIntervalSince1970: 1000), notes: "", status: summarised ? .summarised : .none,
            transcribed: transcribed, summarised: summarised, audioExpiresAt: expires, audioDeletedAt: deleted)
}

private let saved = [TranscriptSegment(start: 0, text: "Hej")]
private let summary = MeetingSummary(title: "Standup", actionItems: [], topics: [.init(title: "Release", points: ["Tisdag"])])

let audioRetentionTests: [(name: String, run: () throws -> Void)] = [
    ("a new recording's audio expires when it starts, or never in developer mode", {
        let created = Date(timeIntervalSince1970: 1000)
        check(AudioRetention.expiry(created: created, developerMode: false) == created, "deleted after processing")
        check(AudioRetention.expiry(created: created, developerMode: true) == nil, "developer mode keeps it")
        let defaults = UserDefaults(suiteName: "retention-\(UUID().uuidString)")!
        check(!AudioRetention.developerMode(defaults: defaults), "off by default")
        defaults.set(true, forKey: AudioRetention.developerModeKey)
        check(AudioRetention.developerMode(defaults: defaults), "on")
    }),

    ("audio is due only once transcribed and summarised, and never without an expiry", {
        let now = Date(timeIntervalSince1970: 2000)
        let expired = Date(timeIntervalSince1970: 1000)
        check(AudioRetention.state(of: meeting(expires: expired), now: now) == .due, "processed")
        check(AudioRetention.state(of: meeting(), now: now) == .kept, "from before, or developer mode")
        check(AudioRetention.state(of: meeting(expires: Date(timeIntervalSince1970: 3000)), now: now) == .kept, "not yet")
        check(AudioRetention.state(of: meeting(expires: expired, transcribed: false, summarised: false), now: now)
              == .waiting("Audio kept: not transcribed yet"), "failed processing keeps it")
        check(AudioRetention.state(of: meeting(expires: expired, summarised: false), now: now)
              == .waiting("Audio kept: not summarised yet"), "no summary yet")
        check(AudioRetention.state(of: meeting(expires: expired, deleted: now), now: now) == .deleted(now), "gone")
        let busy = meeting(expires: expired, file: "Meeting-2026-11-06-1100.m4a")
        let due = AudioRetention.due([meeting(expires: expired), busy, meeting()], now: now, busy: [busy.audioFile])
        check(due.map(\.audioFile) == ["Meeting-2026-11-06-1000.m4a"], "busy and kept ones are skipped")
    }),

    ("a recording's files are its audio, stems, parts and combined file, nothing else", {
        let names = ["Meeting-2026-11-06-1000.m4a", "Meeting-2026-11-06-1000.stem-mic.m4a", "Meeting-2026-11-06-1000.stem-system.m4a",
                     "Meeting-2026-11-06-1000.part-1762419600.m4a", "Meeting-2026-11-06-1000.combined.m4a",
                     "Meeting-2026-11-06-1000.transcript.md", "Meeting-2026-11-06-1000.meta.json",
                     "Meeting-2026-11-06-1000-2.m4a", "Meeting-2026-11-06-1000-2.stem-mic.m4a", "Meeting-2026-11-06-10001.m4a"]
        check(AudioRetention.files(of: "Meeting-2026-11-06-1000.m4a", among: names) == Array(names.prefix(5)), "own audio only")
        check(AudioRetention.files(of: "Meeting-2026-11-06-1000-2.m4a", among: names)
              == ["Meeting-2026-11-06-1000-2.m4a", "Meeting-2026-11-06-1000-2.stem-mic.m4a"], "the second meeting that minute")
    }),

    ("the text for deleted audio names the day", {
        let date = ISO8601DateFormatter().date(from: "2026-11-13T09:00:00Z")!
        check(AudioRetention.deletedText(date, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
              == "Audio deleted on 13 Nov", "date")
    }),

    ("meetings without audio stay listed", {
        let gone = meeting(expires: Date(), deleted: Date())
        let listed = [FolderItem(name: "Meeting-2026-11-06-0900.m4a", created: Date())]
        check(LibraryLogic.withoutAudio([gone, meeting(file: "Meeting-2026-11-06-0900.m4a")], files: listed).map(\.name)
              == [gone.audioFile], "only deleted ones are added")
        check(LibraryLogic.withoutAudio([meeting(deleted: Date(), file: "Meeting-2026-11-06-0900.m4a")], files: listed).isEmpty,
              "not twice")
    }),

    ("the sweep deletes processed new recordings for good and leaves the rest", {
        try withLibrary { store, folder in
            let done = "Meeting-2026-11-06-1000.m4a", failed = "Meeting-2026-11-06-1100.m4a"
            let old = "Meeting-2026-10-01-0900.m4a", developer = "Meeting-2026-11-06-1200.m4a", busy = "Meeting-2026-11-06-1300.m4a"
            touch([done, "Meeting-2026-11-06-1000.stem-mic.m4a", "Meeting-2026-11-06-1000.stem-system.m4a", failed, old, developer, busy],
                  in: folder)
            let created = Date(timeIntervalSince1970: 1_000_000)
            try store.sync(folder: folder, files: [FolderItem(name: old, created: created)])
            for file in [done, failed, busy] { try store.beginRecording(file, created: created, audioExpiresAt: created) }
            try store.beginRecording(developer, created: created, audioExpiresAt: nil)
            try store.beginRecording(old, created: created, audioExpiresAt: created)
            check(try store.meetings().first { $0.audioFile == old }?.audioExpiresAt == nil, "an existing meeting keeps no expiry")
            for file in [done, old, developer, busy] {
                try store.saveTranscript(file, segments: saved, language: .swedish, engine: "test")
                try store.saveSummary(file, ParsedSummary(summary))
            }
            try store.setFailed(failed, message: "no speech")
            let now = Date()
            let deleted = try AudioRetention.sweep(store: store, folder: folder, now: now, busy: [busy])
            check(deleted == [done], "only the processed new recording")
            let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
            check(left == [failed, old, developer, busy], "its stems went too: \(left.sorted())")
            let stored = try store.meetings().first { $0.audioFile == done }
            check(stored?.audioDeletedAt.map { abs($0.timeIntervalSince(now)) < 1 } == true, "deleted at")
            check(stored?.transcribed == true && stored?.summarised == true, "transcript and summary stay")
            check(try store.content(of: done)?.segments == saved, "segments stay")
            check(try AudioRetention.sweep(store: store, folder: folder, now: now, busy: []) == [busy], "once not busy")
            check(try AudioRetention.sweep(store: store, folder: folder, now: now, busy: []).isEmpty, "nothing twice")
        }
    }),

    ("deleting audio by hand works without the file", {
        try withLibrary { store, folder in
            let file = "Meeting-2026-11-06-1000.m4a"
            try store.saveTranscript(file, segments: saved, language: .swedish, engine: "test")
            try AudioRetention.deleteAudio(of: file, in: folder, store: store, now: Date())
            check(try store.meetings().first?.audioDeletedAt != nil, "marked")
        }
    }),
]
