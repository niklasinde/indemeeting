import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func withVersionStore(_ body: (MeetingStore, URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("versions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite")), folder)
}

private let name = "Meeting-2026-11-05-1400.m4a"
private let firstSegments = [TranscriptSegment(start: 1, text: "Releasen är på tisdag.", speaker: .numbered(1)),
                             TranscriptSegment(start: 5, text: "Bra.", speaker: .you)]
private let secondSegments = [TranscriptSegment(start: 1, text: "Release on Thursday.", speaker: .others)]
private let anna = [SpeakerProfile(speaker: .numbered(1), name: "Anna", embedding: [0.25, 0.5])]
private let firstSummary = ParsedSummary(MeetingSummary(
    title: "Standup", actionItems: [.init(task: "Skicka rapporten", owner: "Anna")],
    topics: [.init(title: "Release", points: ["Tisdag."])]))
private let firstDate = Date(timeIntervalSince1970: 1_793_887_320)

private func transcribeFirst(_ store: MeetingStore) throws {
    try store.saveTranscript(name, segments: firstSegments, language: .swedish, engine: "ggml-large-v3-turbo",
                             transcribedAt: firstDate, speakers: anna, keepingPrevious: true)
    try store.saveSummary(name, firstSummary)
}

private func retranscribe(_ store: MeetingStore) throws {
    try store.saveTranscript(name, segments: secondSegments, language: .english, detected: true, engine: "SpeechTranscriber",
                             transcribedAt: firstDate.addingTimeInterval(3600), keepingPrevious: true)
    try store.saveSummary(name, ParsedSummary(unavailable: "Apple Intelligence is off"))
}

let transcriptVersionTests: [(name: String, run: () throws -> Void)] = [
    ("a version is labelled with when and with which engine it was transcribed", {
        let utc = TimeZone(identifier: "UTC")!
        let british = Locale(identifier: "en_GB")
        let label = TranscriptVersionLogic.label(TranscriptVersionInfo(id: 1, transcribedAt: firstDate, engine: "ggml-large-v3-turbo"),
                                                 locale: british, timeZone: utc)
        check(label.contains("5 Nov") && label.contains("14:02") && label.hasSuffix(" \u{00B7} Whisper Large v3 Turbo")
              && !label.hasPrefix("Transcribed"), "label \(label)")
        check(TranscriptVersionLogic.label(TranscriptVersionInfo(id: 1, transcribedAt: nil, engine: nil)) == "Unknown date", "undated")
        check(LibraryLogic.transcriptionInfo(at: firstDate, engine: nil, locale: british, timeZone: utc)
              == "Transcribed " + LibraryLogic.transcriptionLabel(at: firstDate, engine: nil, locale: british, timeZone: utc),
              "info shares the label")
    }),

    ("restoring swaps the version with the current transcript, keeping the current one only when there is one", {
        let current = TranscriptSnapshot(segments: secondSegments, engine: "SpeechTranscriber")
        let earlier = TranscriptSnapshot(segments: firstSegments, engine: "ggml-large-v3-turbo", summary: firstSummary)
        check(TranscriptVersionLogic.restorePlan(current: current, restoring: earlier) == .init(current: earlier, archive: current),
              "swap")
        check(TranscriptVersionLogic.restorePlan(current: TranscriptSnapshot(segments: []), restoring: earlier)
              == .init(current: earlier, archive: nil), "nothing to keep")
    }),

    ("a snapshot round-trips through its stored form", {
        let snapshot = TranscriptSnapshot(segments: firstSegments,
                                          speakers: [SpeakerProfile(speaker: .numbered(1), name: "Anna", embedding: [0.1, -2.5])],
                                          language: .swedish, languageDetected: true, engine: "x", transcribedAt: firstDate,
                                          summary: firstSummary)
        let decoded = try TranscriptVersionLogic.decode(TranscriptVersionLogic.encode(snapshot), language: .swedish,
                                                        languageDetected: true, engine: "x", transcribedAt: firstDate)
        check(decoded.segments == snapshot.segments && decoded.speakers == snapshot.speakers, "transcript")
        check(decoded.summary.sections == firstSummary.sections && decoded.summary.title == "Standup"
              && decoded.summary.actionItems.map(\.task) == ["Skicka rapporten"], "summary")
        check(decoded.summary.actionItems.allSatisfy { Int64($0.key) == nil }, "keys never name an action item row")
        check(decoded.names == [.numbered(1): "Anna"], "names")
    }),

    ("re-transcribing keeps the old transcript and summary as a version; a first transcription and re-summarising do not", {
        try withVersionStore { store, _ in
            try transcribeFirst(store)
            check(try store.versions(of: name).isEmpty, "first transcription keeps nothing")
            try store.saveSummary(name, firstSummary)
            check(try store.versions(of: name).isEmpty, "re-summarising keeps nothing")
            try store.saveTranscript(name, segments: firstSegments, language: .swedish, engine: "ggml-large-v3-turbo", speakers: anna)
            check(try store.versions(of: name).isEmpty, "recognising speakers keeps nothing")

            try retranscribe(store)
            let versions = try store.versions(of: name)
            check(versions.map(\.transcribedAt) == [firstDate] && versions.map(\.engine) == ["ggml-large-v3-turbo"],
                  "one version \(versions)")
            let old = try store.version(versions[0].id)
            check(old?.segments == firstSegments && old?.names == [.numbered(1): "Anna"], "old transcript")
            check(old?.summary.title == "Standup" && old?.summary.sections == firstSummary.sections
                  && old?.summary.actionItems.map(\.task) == ["Skicka rapporten"], "old summary")
            check(old?.meeting.language == .swedish && old?.meeting.status == .summarised, "old meeting state")

            let current = try store.content(of: name)
            check(current?.segments == secondSegments && current?.meeting.status == .unavailable, "current is the new one")
            check(try store.search("tisdag") == [], "search leaves versions out")
            check(try store.search("thursday") == [name], "search finds the current")
        }
    }),

    ("restoring a version swaps it with the current transcript", {
        try withVersionStore { store, _ in
            try transcribeFirst(store)
            let first = try store.content(of: name)!
            if let id = first.summary.actionItems.first.flatMap({ Int64($0.key) }) { try store.setChecked(actionItem: id, true) }
            try retranscribe(store)
            let earlier = try store.versions(of: name)[0]
            try store.restoreVersion(earlier.id, of: name)

            let restored = try store.content(of: name)!
            check(restored.segments == firstSegments && restored.names == [.numbered(1): "Anna"], "transcript restored")
            check(restored.meeting.language == .swedish && restored.meeting.transcriptEngine == "ggml-large-v3-turbo"
                  && restored.meeting.transcribedAt == firstDate && restored.meeting.aiTitle == "Standup", "meeting restored")
            check(restored.meeting.status == .summarised && restored.summary.actionItems.map(\.done) == [true], "summary restored")
            check(try store.search("tisdag") == [name], "search follows the restore")

            let versions = try store.versions(of: name)
            check(versions.count == 1 && versions[0].engine == "SpeechTranscriber", "the replaced one became a version")
            let swapped = try store.version(versions[0].id)
            check(swapped?.segments == secondSegments && swapped?.meeting.status == .unavailable
                  && swapped?.meeting.languageDetected == true, "nothing lost")
            try store.restoreVersion(earlier.id, of: name)
            check(try store.versions(of: name).count == 1, "a version that is gone is not restored twice")
        }
    }),

    ("deleting a version or the meeting removes its versions", {
        try withVersionStore { store, folder in
            try transcribeFirst(store)
            try retranscribe(store)
            try retranscribe(store)
            let versions = try store.versions(of: name)
            check(versions.count == 2 && versions[0].engine == "SpeechTranscriber", "newest first \(versions)")
            try store.deleteVersion(versions[0].id)
            check(try store.versions(of: name).map(\.id) == [versions[1].id], "one deleted")
            try store.delete(name)
            let db = try SQLiteDatabase(path: folder.appendingPathComponent("meetings.sqlite").path)
            check(try db.query("SELECT count(*) FROM transcript_versions") { $0.int64(0) } == [0], "cascaded")
        }
    }),
]
