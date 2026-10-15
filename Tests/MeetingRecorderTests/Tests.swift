import AVFoundation
import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

nonisolated(unsafe) var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() { failures.append("line \(line): \(message)") }
}

private let rate = PCMNormalizer.format.sampleRate

private func sine(_ frequency: Double, seconds: Double, amplitude: Float = 0.2) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
}

private func rms(_ samples: [Float]) -> Double {
    sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1)))
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mixer-\(UUID().uuidString).m4a")
}

private func decode(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

private func seconds(of url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

private func feed(_ mixer: AudioMixer, _ source: AudioSource, _ samples: [Float], chunk: Int = 4800, interval: TimeInterval = 0) {
    var start = 0
    while start < samples.count {
        mixer.append(Array(samples[start..<min(start + chunk, samples.count)]), from: source)
        start += chunk
        if interval > 0 { Thread.sleep(forTimeInterval: interval) }
    }
}

private func write(to url: URL, _ body: (AudioMixer) throws -> Void) throws {
    let mixer = try AudioMixer(url: url)
    try body(mixer)
    mixer.finish()
}

private func mixedRMS(mic: [Float], system: [Float]) throws -> Double {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try write(to: url) { mixer in
        feed(mixer, .microphone, mic)
        feed(mixer, .system, system)
    }
    return rms(try decode(url))
}

let allTests: [(name: String, run: () throws -> Void)] = [
    ("elapsedText formats hh:mm:ss", {
        check(RecordingLogic.elapsedText(0) == "00:00:00", "zero")
        check(RecordingLogic.elapsedText(59.9) == "00:00:59", "truncates fractions")
        check(RecordingLogic.elapsedText(61) == "00:01:01", "minutes")
        check(RecordingLogic.elapsedText(3600 + 23 * 60 + 45) == "01:23:45", "hours")
        check(RecordingLogic.elapsedText(100 * 3600) == "100:00:00", "over 99 hours")
    }),

    ("file name matches Meeting-YYYY-MM-DD-HHmm.m4a", {
        let zone = TimeZone(identifier: "Europe/Stockholm")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9, minute: 5, second: 59))!
        check(RecordingLogic.fileName(for: date, timeZone: zone) == "Meeting-2026-03-07-0905.m4a", "padded fields")
        let evening = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59))!
        check(RecordingLogic.fileName(for: evening, timeZone: zone) == "Meeting-2026-12-31-2359.m4a", "24 hour clock")
    }),

    ("system audio is attempted unless access is denied", {
        check(RecordingLogic.attemptsSystemAudio(.granted), "granted")
        check(RecordingLogic.attemptsSystemAudio(.unknown), "unknown still asks")
        check(!RecordingLogic.attemptsSystemAudio(.denied), "denied")
        check(RecordingLogic.notice(systemAudioActive: true) == nil, "no notice when active")
        check(RecordingLogic.notice(systemAudioActive: false) == RecordingLogic.microphoneOnlyNotice, "mic-only notice")
    }),

    ("recordings are written under a partial name and moved into place on finish", {
        let url = tempURL()
        let partial = RecordingLogic.partialURL(for: url)
        defer { try? FileManager.default.removeItem(at: url) }
        check(partial.lastPathComponent == url.deletingPathExtension().lastPathComponent + ".recording.m4a", "partial name \(partial.lastPathComponent)")
        let mixer = try AudioMixer(url: url)
        feed(mixer, .microphone, sine(440, seconds: 0.5))
        Thread.sleep(forTimeInterval: 0.3)
        check(FileManager.default.fileExists(atPath: partial.path), "partial exists while recording")
        check(!FileManager.default.fileExists(atPath: url.path), "final name absent while recording")
        check(mixer.finish() == url, "finish returns the final url")
        check(!FileManager.default.fileExists(atPath: partial.path), "partial removed")
        let duration = try seconds(of: url)
        check(abs(duration - 0.5) < 0.1, "readable while the mixer is still alive, duration \(duration)")
        mixer.append(sine(440, seconds: 0.5), from: .microphone)
        Thread.sleep(forTimeInterval: 0.2)
        let after = try seconds(of: url)
        check(after == duration, "appends after finish are ignored, \(after) vs \(duration)")
    }),

    ("file names stay unique within a minute", {
        let folder = URL(fileURLWithPath: "/tmp/rec")
        let zone = TimeZone(identifier: "Europe/Stockholm")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 13, minute: 38))!
        let free = RecordingLogic.availableURL(in: folder, for: date, timeZone: zone) { _ in false }
        check(free.path == "/tmp/rec/Meeting-2026-10-15-1338.m4a", "free \(free.path)")
        let taken: Set<String> = ["Meeting-2026-10-15-1338.m4a", "Meeting-2026-10-15-1338-2.recording.m4a"]
        let next = RecordingLogic.availableURL(in: folder, for: date, timeZone: zone) { taken.contains($0.lastPathComponent) }
        check(next.lastPathComponent == "Meeting-2026-10-15-1338-3.m4a", "skips finished and in-progress, got \(next.lastPathComponent)")
    }),

    ("level meter reports rms and silence", {
        var meter = LevelMeter()
        check(meter.rms == 0 && meter.isSilent, "empty is silent")
        meter.add([Float](repeating: 0.0001, count: 480))
        check(meter.isSilent, "near-zero is silent")
        meter.add(sine(440, seconds: 1))
        check(!meter.isSilent && abs(meter.rms - rms([Float](repeating: 0.0001, count: 480) + sine(440, seconds: 1))) < 1e-6, "rms \(meter.rms)")
        check(meter.count == 480 + Int(rate), "counts samples")
    }),

    ("mixer tracks the level of each source", {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let mixer = try AudioMixer(url: url)
        feed(mixer, .system, sine(440, seconds: 0.5))
        mixer.finish()
        check(mixer.level(of: .microphone).isSilent, "no mic samples")
        check(abs(mixer.level(of: .system).rms - 0.2 / 2.0.squareRoot()) < 0.01, "system rms \(mixer.level(of: .system).rms)")
    }),

    ("record flag takes seconds and an optional output", {
        check(RecordingLogic.recordArguments(["app"]) == nil, "no flag")
        check(RecordingLogic.recordArguments(["app", "--record", "x"]) == nil, "not a number")
        check(RecordingLogic.recordArguments(["app", "--record", "0"]) == nil, "must be positive")
        let job = RecordingLogic.recordArguments(["app", "--record", "5", "--out", "/tmp/a.m4a"])
        check(job?.seconds == 5 && job?.output?.path == "/tmp/a.m4a", "with output")
        check(RecordingLogic.recordArguments(["app", "--record", "2.5"])?.output == nil, "output optional")
    }),

    ("mic-only output is written with the expected duration", {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(to: url) { feed($0, .microphone, sine(440, seconds: 1.5)) }
        check(FileManager.default.fileExists(atPath: url.path), "file exists")
        let duration = try seconds(of: url)
        check(abs(duration - 1.5) < 0.15, "duration \(duration) should be about 1.5s")
        let level = rms(try decode(url))
        check(abs(level - 0.2 / 2.0.squareRoot()) < 0.03, "mic level preserved, got \(level)")
    }),

    ("sources are summed sample by sample", {
        let tone = sine(440, seconds: 1)
        let single = try mixedRMS(mic: tone, system: [])
        let doubled = try mixedRMS(mic: tone, system: tone)
        check(abs(doubled / single - 2) < 0.15, "identical sources should double the level, ratio \(doubled / single)")
        let cancelled = try mixedRMS(mic: tone, system: tone.map { -$0 })
        check(cancelled < single * 0.2, "opposite sources should cancel, got \(cancelled)")
    }),

    ("summed output is clipped to full scale", {
        let loud = sine(440, seconds: 1, amplitude: 0.9)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(to: url) {
            feed($0, .microphone, loud)
            feed($0, .system, loud)
        }
        let decoded = try decode(url)
        let peak = decoded.map { abs($0) }.max() ?? 0
        check(peak < 1.2, "peak \(peak) should stay near full scale")
        check(rms(decoded) < 1.0, "unclipped sum would have rms 1.27, got \(rms(decoded))")
    }),

    ("a silent source does not stall the other", {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(to: url) { mixer in
            feed(mixer, .system, sine(880, seconds: 0.3))
            feed(mixer, .microphone, sine(440, seconds: 3), chunk: 4800, interval: 0.1)
            Thread.sleep(forTimeInterval: 0.2)
            let seconds = Double(mixer.framesWritten) / rate
            check(seconds > 1.5, "mic audio should keep flowing while system is silent, got \(seconds)s")
        }
        let total = try seconds(of: url)
        check(abs(total - 3) < 0.2, "total duration \(total) should be about 3s")
    }),

    ("meeting notification waits for the mic to stay busy", {
        var detector = MeetingDetector()
        let start = Date()
        check(detector.update(micBusy: false, recording: false, now: start) == .idle, "idle mic")
        check(detector.update(micBusy: true, recording: false, now: start) == .wait(MeetingDetector.threshold), "starts waiting")
        check(detector.update(micBusy: true, recording: false, now: start + 1) == .wait(MeetingDetector.threshold - 1), "still waiting")
        check(detector.update(micBusy: true, recording: false, now: start + 3) == .notify, "notifies after threshold")
    }),

    ("a short mic blip does not notify", {
        var detector = MeetingDetector()
        let start = Date()
        _ = detector.update(micBusy: true, recording: false, now: start)
        check(detector.update(micBusy: false, recording: false, now: start + 2) == .idle, "released early")
        check(detector.update(micBusy: true, recording: false, now: start + 4) == .wait(MeetingDetector.threshold), "timer restarts")
    }),

    ("notifies once per meeting and again after it ends", {
        var detector = MeetingDetector()
        let start = Date()
        _ = detector.update(micBusy: true, recording: false, now: start)
        check(detector.update(micBusy: true, recording: false, now: start + 3) == .notify, "first notify")
        check(detector.update(micBusy: true, recording: false, now: start + 60) == .idle, "no nagging")
        check(detector.update(micBusy: false, recording: false, now: start + 61) == .idle, "meeting ended")
        _ = detector.update(micBusy: true, recording: false, now: start + 100)
        check(detector.update(micBusy: true, recording: false, now: start + 103) == .notify, "next meeting notifies")
    }),

    ("own recording never triggers or re-triggers a notification", {
        var detector = MeetingDetector()
        let start = Date()
        _ = detector.update(micBusy: true, recording: false, now: start)
        check(detector.update(micBusy: true, recording: true, now: start + 1) == .idle, "recording started before threshold")
        check(detector.update(micBusy: true, recording: false, now: start + 30) == .idle, "stopping mid-meeting does not re-notify")
        _ = detector.update(micBusy: false, recording: false, now: start + 31)
        check(detector.update(micBusy: true, recording: true, now: start + 40) == .idle, "manual recording with idle mic")
        check(detector.update(micBusy: true, recording: false, now: start + 50) == .idle, "after manual stop")
    }),

    ("meeting app name prefers the frontmost known app", {
        let running = ["com.apple.finder", "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.google.Chrome"]
        check(MeetingApps.name(frontmost: "com.google.Chrome", running: running) == "Google Chrome", "frontmost browser")
        check(MeetingApps.name(frontmost: "com.tinyspeck.slackmacgap", running: running) == "Slack", "frontmost dedicated")
        check(MeetingApps.name(frontmost: "com.apple.finder", running: running) == "Zoom", "running dedicated by priority")
        check(MeetingApps.name(frontmost: nil, running: ["com.google.Chrome"]) == nil, "background browser ignored")
        check(MeetingApps.notificationBody(appName: nil) == "Microphone in use", "no app")
        check(MeetingApps.notificationBody(appName: "Zoom") == "Zoom \u{00B7} microphone in use", "with app")
    }),

    ("a source that never delivers does not block the other", {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(to: url) { mixer in
            feed(mixer, .microphone, sine(440, seconds: 2), chunk: 4800, interval: 0.1)
            Thread.sleep(forTimeInterval: 0.2)
            let seconds = Double(mixer.framesWritten) / rate
            check(seconds > 1.0, "mic audio should flow without a system source, got \(seconds)s")
        }
    }),

    ("timestamps are bracketed hh:mm:ss", {
        check(ProcessingLogic.timestamp(0) == "[00:00:00]", "zero")
        check(ProcessingLogic.timestamp(83.7) == "[00:01:23]", "truncates")
        check(ProcessingLogic.timestamp(3 * 3600 + 5) == "[03:00:05]", "hours")
        check(ProcessingLogic.timestamp(-1) == "[00:00:00]", "negative clamps")
        check(TranscriptSegment(start: 61, text: "Hej").line == "[00:01:01] Hej", "segment line")
    }),

    ("timed words are grouped into timestamped sentences", {
        let pieces: [(text: String, start: TimeInterval?)] = [
            ("Hej", 1.0), (" alla.", 1.4), (" ", nil), ("Nästa", 4.2), (" punkt", 4.6), ("?", nil), (" Sista", nil), (" ord", 9),
        ]
        let segments = ProcessingLogic.sentences(pieces, from: 0.5)
        check(segments == [TranscriptSegment(start: 1, text: "Hej alla."), TranscriptSegment(start: 4.2, text: "Nästa punkt?"),
                           TranscriptSegment(start: 4.6, text: "Sista ord")], "got \(segments)")
        check(ProcessingLogic.sentences([("Untimed text", nil)], from: 7) == [TranscriptSegment(start: 7, text: "Untimed text")], "fallback")
        check(ProcessingLogic.sentences([(" ", nil)], from: 0).isEmpty, "whitespace only")
    }),

    ("output files sit next to the recording", {
        let audio = URL(fileURLWithPath: "/tmp/rec/Meeting-2026-10-15-1430.m4a")
        check(ProcessingLogic.transcriptURL(for: audio).path == "/tmp/rec/Meeting-2026-10-15-1430.transcript.md", "transcript")
        check(ProcessingLogic.summaryURL(for: audio).path == "/tmp/rec/Meeting-2026-10-15-1430.summary.md", "summary")
        let dotted = URL(fileURLWithPath: "/tmp/team.sync.m4a")
        check(ProcessingLogic.summaryURL(for: dotted).lastPathComponent == "team.sync.summary.md", "keeps inner dots")
        check(ProcessingLogic.transcriptURL(for: audio) != audio && ProcessingLogic.summaryURL(for: audio) != audio, "never the audio")
    }),

    ("chunks keep lines whole and respect the limit", {
        let lines = (1...10).map { "[00:00:0\($0 % 10)] " + String(repeating: "a", count: 20) }
        let chunks = ProcessingLogic.chunks(lines, maxCharacters: 100)
        check(chunks.allSatisfy { $0.count <= 100 }, "limit, got \(chunks.map(\.count))")
        check(chunks.count == 4, "31-char lines, three per chunk: got \(chunks.count)")
        check(chunks.joined(separator: "\n") == lines.joined(separator: "\n"), "nothing lost or reordered")
        check(ProcessingLogic.chunks([], maxCharacters: 100).isEmpty, "empty")
        check(ProcessingLogic.chunks(["short"], maxCharacters: 100) == ["short"], "single")
    }),

    ("an overlong line is split on words, an overlong word hard", {
        let line = (1...30).map { "word\($0)" }.joined(separator: " ")
        let chunks = ProcessingLogic.chunks([line], maxCharacters: 40)
        check(chunks.allSatisfy { $0.count <= 40 }, "limit, got \(chunks.map(\.count))")
        check(chunks.joined(separator: " ").replacingOccurrences(of: "\n", with: " ") == line, "words preserved")
        let word = String(repeating: "x", count: 95)
        check(ProcessingLogic.chunks([word], maxCharacters: 40).map(\.count) == [40, 40, 15], "hard split")
    }),

    ("transcript markdown lists timestamped segments", {
        let markdown = ProcessingLogic.transcriptMarkdown(
            audioName: "Meeting-2026-10-15-1430.m4a", language: .swedish, engine: "DictationTranscriber",
            segments: [TranscriptSegment(start: 1, text: "Hej alla."), TranscriptSegment(start: 83, text: "Nästa punkt.")])
        check(markdown.hasPrefix("# Transkription: Meeting-2026-10-15-1430\n"), "title")
        check(markdown.contains("Svenska \u{00B7} on-device DictationTranscriber"), "language and engine")
        check(markdown.contains("[00:00:01] Hej alla.\n\n[00:01:23] Nästa punkt."), "segments")
    }),

    ("summary markdown renders every section in the meeting language", {
        let summary = MeetingSummary(title: "Budget Q4", summary: "We reviewed the budget.",
                                     keyPoints: ["Costs are up"], decisions: [],
                                     actionItems: [.init(task: "Send report", owner: "Anna"), .init(task: "Book room", owner: nil)])
        let english = ProcessingLogic.summaryMarkdown(summary, audioName: "a.m4a", language: .english)
        check(english.hasPrefix("# Budget Q4\n"), "title")
        check(english.contains("## Summary\n\nWe reviewed the budget."), "summary")
        check(english.contains("## Key points\n\n- Costs are up"), "key points")
        check(english.contains("## Decisions\n\nNone noted."), "empty decisions")
        check(english.contains("- [ ] Send report \u{2014} **Anna**\n- [ ] Book room\n"), "action items with owner")
        let swedish = ProcessingLogic.summaryMarkdown(summary, audioName: "a.m4a", language: .swedish)
        check(swedish.contains("## Sammanfattning") && swedish.contains("## Åtgärder") && swedish.contains("Inga noterade."), "swedish headings")
    }),

    ("summary decodes from model JSON and renders notes", {
        let json = #"{"title":"T","summary":"S","keyPoints":["k"],"decisions":["d"],"actionItems":[{"task":"x","owner":"Bo"},{"task":"y"}]}"#
        let summary = try MeetingSummary.decode(json: json)
        check(summary.actionItems == [.init(task: "x", owner: "Bo"), .init(task: "y", owner: nil)], "optional owner")
        check(summary.notes == "T\nS\n- k\n- Decision: d\n- Action: x (owner: Bo)\n- Action: y", "notes, got \(summary.notes)")
    }),

    ("unavailable summary explains how to enable Apple Intelligence", {
        let markdown = ProcessingLogic.unavailableMarkdown(.appleIntelligenceOff, audioName: "Meeting-x.m4a", language: .english)
        check(markdown.hasPrefix("# No summary: Meeting-x\n"), "title")
        check(markdown.contains("System Settings \u{2192} Apple Intelligence & Siri"), "settings path")
        check(markdown.contains("`Meeting-x.transcript.md`"), "points to transcript")
        check(SummaryUnavailable.unsupportedLanguage(.swedish).menuText.contains("Swedish"), "language named")
    }),

    ("meeting language defaults to Swedish and round-trips", {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: MeetingLanguage.storageKey)
        defer { defaults.set(saved, forKey: MeetingLanguage.storageKey) }
        defaults.removeObject(forKey: MeetingLanguage.storageKey)
        check(MeetingLanguage.current == .swedish, "default")
        defaults.set(MeetingLanguage.english.rawValue, forKey: MeetingLanguage.storageKey)
        check(MeetingLanguage.current == .english, "stored")
        check(MeetingLanguage.allCases.map(\.displayName) == ["Svenska", "English"], "picker names")
    }),

    ("stage text and command-line flag", {
        check(ProcessingStage.transcribing.text(for: "a.m4a") == "Transcribing a.m4a\u{2026}", "transcribing")
        check(ProcessingStage.summarising(part: 2, of: 3).text(for: "a.m4a") == "Summarising a.m4a\u{2026} (2/3)", "parts")
        check(ProcessingStage.summarising(part: 1, of: 1).text(for: "a.m4a") == "Summarising a.m4a\u{2026}", "single")
        check(ProcessingLogic.processArguments(["app"]) == nil, "no flag")
        let job = ProcessingLogic.processArguments(["app", "--process", "/x/a.m4a", "--language", "en-US"])
        check(job?.audio.path == "/x/a.m4a" && job?.language == .english, "flag with language")
        check(ProcessingLogic.processArguments(["app", "--process", "/x/a.m4a"])?.language == nil, "language optional")
    }),
]
