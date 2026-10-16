import AVFoundation
import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

nonisolated(unsafe) var failures: [String] = []

func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
    do {
        if try !condition() { failures.append("line \(line): \(message)") }
    } catch {
        failures.append("line \(line): \(message), threw \(error)")
    }
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

func blocking(_ body: @escaping @Sendable () async throws -> Void) throws {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var failure: Error?
    Task.detached {
        do { try await body() } catch { failure = error }
        done.signal()
    }
    done.wait()
    if let failure { throw failure }
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

let allTests: [(name: String, run: () throws -> Void)] = logicTests + speakerTests + autoStopTests + storeTests

private let logicTests: [(name: String, run: () throws -> Void)] = [
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
        check(RecordingLogic.recordArguments(["app", "--record", "2"])?.pause == nil, "no pause by default")
        let paused = RecordingLogic.recordArguments(["app", "--record", "4", "--pause-after", "2", "--resume-after", "1.5"])
        check(paused?.pause == RecordJob.Pause(after: 2, duration: 1.5), "pause \(String(describing: paused?.pause))")
        check(RecordingLogic.recordArguments(["app", "--record", "4", "--pause-after", "2"])?.pause?.duration == 1, "resume defaults to 1s")
        let continued = RecordingLogic.recordArguments(["app", "--continue", "/tmp/m.m4a", "--record", "3"])
        check(continued?.continuing?.path == "/tmp/m.m4a" && continued?.seconds == 3, "continue")
    }),

    ("elapsed clock leaves out paused time", {
        let start = Date(timeIntervalSince1970: 1000)
        var clock = ElapsedClock(started: start)
        check(clock.elapsed(at: start + 10) == 10, "running")
        clock.pause(at: start + 10)
        check(clock.isPaused && clock.elapsed(at: start + 25) == 10, "frozen while paused")
        clock.pause(at: start + 20)
        clock.resume(at: start + 30)
        check(!clock.isPaused && clock.elapsed(at: start + 35) == 15, "resumes without the gap, got \(clock.elapsed(at: start + 35))")
        clock.resume(at: start + 40)
        check(clock.elapsed(at: start + 40) == 20, "resume when running is ignored")
        clock.pause(at: start + 40)
        clock.resume(at: start + 50)
        check(clock.elapsed(at: start + 60) == 30, "second pause, got \(clock.elapsed(at: start + 60))")
        check(RecordingLogic.statusText(paused: true, elapsed: 754) == "Paused  00:12:34", "paused text")
        check(RecordingLogic.statusText(paused: false, elapsed: 12) == "Recording  00:00:12", "recording text")
    }),

    ("continued parts and combined files are named next to the meeting and not listed", {
        let meeting = URL(fileURLWithPath: "/tmp/rec/Meeting-2026-10-15-1430.m4a")
        let part = RecordingLogic.partURL(for: meeting, at: Date(timeIntervalSince1970: 1_760_000_000))
        check(part.path == "/tmp/rec/Meeting-2026-10-15-1430.part-1760000000.m4a", "part \(part.path)")
        check(RecordingLogic.partialURL(for: part).lastPathComponent == "Meeting-2026-10-15-1430.part-1760000000.recording.m4a",
              "part while recording")
        let combined = RecordingLogic.combinedURL(for: meeting)
        check(combined.path == "/tmp/rec/Meeting-2026-10-15-1430.combined.m4a", "combined \(combined.path)")
        for url in [part, combined, RecordingLogic.partialURL(for: part)] {
            check(!LibraryLogic.isListed(url.lastPathComponent), "\(url.lastPathComponent) not listed")
        }
        check(LibraryLogic.isListed(meeting.lastPathComponent), "meeting listed")
        check(ProcessingLogic.notesURL(for: meeting).lastPathComponent == "Meeting-2026-10-15-1430.notes.md", "same sidecars")
    }),

    ("combined duration has to match the meeting plus the part", {
        check(RecordingLogic.isCombinedDurationValid(30.02, meeting: 20, part: 10), "close enough")
        check(RecordingLogic.isCombinedDurationValid(29.6, meeting: 20, part: 10), "within half a second")
        check(!RecordingLogic.isCombinedDurationValid(20, meeting: 20, part: 10), "part missing")
        check(!RecordingLogic.isCombinedDurationValid(10, meeting: 20, part: 10), "meeting missing")
        check(RecordingLogic.combinedDurationTolerance(7200) == 7.2, "scales for long meetings")
        check(RecordingLogic.isCombinedDurationValid(7205, meeting: 3600, part: 3600), "long meeting")
    }),

    ("the meeting being recorded is listed first until its file exists", {
        let zone = TimeZone(identifier: "Europe/Stockholm")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 16, minute: 47))!
        let old = RecordingEntry(audio: URL(fileURLWithPath: "/tmp/Meeting-2026-10-15-0900.m4a"), date: now - 3600,
                                 duration: 60)
        check(LibraryLogic.withRecording(nil, in: [old], now: now) == [old], "nothing recording")
        let new = URL(fileURLWithPath: "/tmp/Meeting-2026-10-15-1646.m4a")
        let listed = LibraryLogic.withRecording(new, in: [old], now: now, timeZone: zone)
        check(listed.map(\.audio) == [new, old.audio] && listed[0].inProgress && listed[0].duration == nil, "added on top")
        check(listed[0].date == calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 16, minute: 46))!,
              "dated by its name")
        check(LibraryLogic.withRecording(old.audio, in: [old], now: now) == [old], "a continued meeting is not added twice")
    }),

    ("paused audio is left out of the file", {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(to: url) { mixer in
            feed(mixer, .microphone, sine(440, seconds: 0.5))
            mixer.pause()
            feed(mixer, .microphone, sine(440, seconds: 0.7))
            mixer.resume()
            feed(mixer, .microphone, sine(440, seconds: 0.5))
        }
        let duration = try seconds(of: url)
        check(abs(duration - 1.0) < 0.1, "duration \(duration) should be about 1.0s")
    }),

    ("a part is appended to the meeting in place", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = folder.appendingPathComponent("Meeting-2026-10-15-1430.m4a")
        let part = RecordingLogic.partURL(for: meeting, at: Date())
        try write(to: meeting) { feed($0, .microphone, sine(440, seconds: 1.2)) }
        try write(to: part) { feed($0, .microphone, sine(660, seconds: 0.8)) }
        try blocking { try await AudioAppender.append(part, to: meeting) }
        let duration = try seconds(of: meeting)
        check(abs(duration - 2.0) < 0.1, "combined duration \(duration)")
        check(!FileManager.default.fileExists(atPath: part.path), "part removed")
        check(!FileManager.default.fileExists(atPath: RecordingLogic.combinedURL(for: meeting).path), "no combined file left")
        let level = rms(try decode(meeting))
        check(level > 0.1, "audio kept, rms \(level)")
        let bitRate = Double(try Data(contentsOf: meeting).count) * 8 / duration
        check(bitRate < 120_000, "encoded like a recording, \(Int(bitRate)) bit/s")
    }),

    ("a failed append keeps the meeting and the part", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = folder.appendingPathComponent("Meeting-2026-10-15-1430.m4a")
        let part = RecordingLogic.partURL(for: meeting, at: Date())
        let original = Data("not audio".utf8)
        try original.write(to: meeting)
        try write(to: part) { feed($0, .microphone, sine(660, seconds: 0.5)) }
        var failed = false
        do { try blocking { try await AudioAppender.append(part, to: meeting) } } catch { failed = error is AppendError }
        check(failed, "throws an AppendError")
        check((try? Data(contentsOf: meeting)) == original, "meeting untouched")
        check(FileManager.default.fileExists(atPath: part.path), "part kept")
        check(!FileManager.default.fileExists(atPath: RecordingLogic.combinedURL(for: meeting).path), "no combined file left")
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
        check(TranscriptSegment(start: 61, text: "Hej").line(.swedish) == "[00:01:01] Hej", "segment line")
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

    ("chunk size follows the model context and falls back when it is unknown", {
        check(ProcessingLogic.chunkCharacters(contextSize: 4096) == 5688, "macOS 26 window")
        check(ProcessingLogic.chunkCharacters(contextSize: 8192) == 17976, "larger window")
        check(ProcessingLogic.chunkCharacters(contextSize: 0) == 5688, "not ready reports 0")
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

    ("summary markdown has a title, owner-first action items and topic sections", {
        let summary = MeetingSummary(title: "Budget Q4",
                                     actionItems: [.init(task: "Send report", owner: "Anna"), .init(task: "Book room", owner: " ")],
                                     topics: [.init(title: "Costs", points: ["Up 8 %"]), .init(title: "Empty", points: [])])
        let english = ProcessingLogic.summaryMarkdown(summary, audioName: "a.m4a", language: .english)
        check(english.hasPrefix("# Budget Q4\n\n_a.m4a \u{00B7} English"), "title and source")
        check(english.contains("## Action items\n\n- [ ] Anna: Send report\n- [ ] Book room\n"), "action items, got \(english)")
        check(english.contains("## Costs\n\n- Up 8 %\n") && !english.contains("## Empty"), "topics")
        let swedish = ProcessingLogic.summaryMarkdown(summary, audioName: nil, language: .swedish)
        check(swedish.contains("## Åtgärdspunkter") && !swedish.contains("_"), "swedish heading, no source line")
        let none = ProcessingLogic.summaryMarkdown(MeetingSummary(title: "T", actionItems: [], topics: []), audioName: nil, language: .english)
        check(none == "# T\n", "no empty sections, got \(none)")
    }),

    ("summary decodes from model JSON", {
        let json = #"{"title":"T","actionItems":[{"task":"x","owner":"Bo"},{"task":"y"}],"topics":[{"title":"A","points":["p"]}]}"#
        let summary = try MeetingSummary.decode(json: json)
        check(summary.actionItems == [.init(task: "x", owner: "Bo"), .init(task: "y", owner: nil)], "optional owner")
        check(summary.topics == [.init(title: "A", points: ["p"])], "topics")
    }),

    ("unavailable summary says why there is none", {
        let markdown = ProcessingLogic.unavailableMarkdown(.appleIntelligenceOff, audioName: "Meeting-x.m4a", language: .english)
        check(markdown.hasPrefix("# No summary: Meeting-x\n"), "title")
        check(markdown.contains("No summary \u{2014} Apple Intelligence is turned off"), "reason")
        check(markdown.contains("`Meeting-x.transcript.md`"), "points to transcript")
        check(SummaryUnavailable.unsupportedLanguage(.swedish).message.contains("Swedish"), "language named")
        check(SummaryUnavailable.modelNotReady.message == "No summary yet \u{2014} Apple Intelligence is still downloading", "downloading")
    }),

    ("error details keep the description, type and code", {
        enum Sample: Error { case broke(Int) }
        let ns = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Went wrong"])
        let nsDetails = ProcessingLogic.errorDetails(ns)
        check(nsDetails.hasPrefix("Went wrong\n") && nsDetails.contains("Domain=Test Code=7"), nsDetails)
        let swiftDetails = ProcessingLogic.errorDetails(Sample.broke(3))
        check(swiftDetails.contains("Sample.broke(3)") && swiftDetails.contains("code 0"), swiftDetails)
    }),

    ("the summary notice follows the current reason, not the saved text", {
        let legacy = "The Apple Intelligence model is not ready yet (it may still be downloading)."
        func notice(_ status: ProcessingStatus?, _ message: String? = legacy, reason: SummaryUnavailable? = nil) -> SummaryNotice {
            .make(status: status, statusMessage: message, hasTranscript: true, currentReason: reason)
        }
        let downloading = notice(.unavailable, reason: .modelNotReady)
        check(downloading.title == "No summary yet \u{2014} Apple Intelligence is still downloading", downloading.title)
        check(downloading.canSummarise && !downloading.showsSettings, "summarise only")
        let off = notice(.unavailable, reason: .appleIntelligenceOff)
        check(off.title == "No summary \u{2014} Apple Intelligence is turned off" && off.showsSettings && off.canSummarise, off.title)
        let ineligible = notice(.unavailable, reason: .deviceNotEligible)
        check(ineligible.title == "No summary \u{2014} this Mac can\u{2019}t run Apple Intelligence" && !ineligible.canSummarise
              && !ineligible.showsSettings, ineligible.title)
        check(notice(.unavailable).title == "No summary yet" && notice(.unavailable).canSummarise, "available again")
        let failed = notice(.failed, "The model refused.")
        check(failed.title == "No summary \u{2014} summarising failed" && failed.details == "The model refused."
              && failed.canSummarise, failed.title)
        check(notice(.summarised, reason: .appleIntelligenceOff).title == "No summary yet", "reason only for unavailable")
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
    ("recording names parse back to their minute", {
        let zone = TimeZone(identifier: "Europe/Stockholm")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 14, minute: 30))!
        check(RecordingLogic.date(fromFileName: "Meeting-2026-10-15-1430.m4a", timeZone: zone) == date, "plain")
        check(RecordingLogic.date(fromFileName: "Meeting-2026-10-15-1430-2.m4a", timeZone: zone) == date, "numbered")
        check(RecordingLogic.date(fromFileName: "Interview.m4a", timeZone: zone) == nil, "other names")
    }),

    ("library lists finished audio newest first", {
        let zone = TimeZone(identifier: "Europe/Stockholm")!
        let folder = URL(fileURLWithPath: "/tmp/rec")
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let names = [
            "Meeting-2026-10-15-1430.m4a", "Meeting-2026-10-15-1430.transcript.md", "Meeting-2026-10-15-1430.summary.md",
            "Meeting-2026-10-15-1430-2.m4a", "Meeting-2026-10-15-1430-10.m4a", "Meeting-2026-10-14-0900.m4a",
            "Meeting-2026-10-14-0900.transcript.md", "Meeting-2026-10-16-0800.recording.m4a", "notes.txt", "Interview.MP3",
            "Meeting-2026-10-15-1430.notes.md", "Meeting-2026-10-15-1430.meta.json",
        ]
        let entries = LibraryLogic.recordings(in: folder, files: names.map { FolderItem(name: $0, created: created) },
                                              durations: ["Meeting-2026-10-14-0900.m4a": 61], timeZone: zone)
        check(entries.map(\.audio.lastPathComponent) == [
            "Interview.MP3", "Meeting-2026-10-15-1430-10.m4a", "Meeting-2026-10-15-1430-2.m4a",
            "Meeting-2026-10-15-1430.m4a", "Meeting-2026-10-14-0900.m4a",
        ], "order \(entries.map(\.audio.lastPathComponent))")
        check(entries[3].duration == nil && entries[4].duration == 61, "durations")
        check(entries[0].date == created, "creation date when the name has no date")
    }),

    ("library hides in-progress recordings", {
        check(LibraryLogic.isListed("Meeting-2026-10-15-1430.m4a"), "finished")
        check(!LibraryLogic.isListed("Meeting-2026-10-15-1430.recording.m4a"), "in progress")
        check(!LibraryLogic.isListed("Meeting-2026-10-15-1430.summary.md"), "markdown")
        check(LibraryLogic.isListed("call.WAV"), "other audio")
    }),

    ("durations show m:ss below an hour and h:mm:ss above", {
        check(LibraryLogic.durationText(0) == "0:00", "zero")
        check(LibraryLogic.durationText(59.6) == "1:00", "rounds")
        check(LibraryLogic.durationText(42 * 60 + 5) == "42:05", "minutes")
        check(LibraryLogic.durationText(3600 + 2 * 60 + 3) == "1:02:03", "hours")
    }),

    ("markdown is split into headings, lists and paragraphs", {
        let blocks = LibraryLogic.markdownBlocks("# Plan\n\n## Topic\n- Budget\n- [ ] Ann: Send it\n- [x] Done\nWe met.")
        check(blocks == [.heading(level: 1, text: "Plan"), .heading(level: 2, text: "Topic"), .bullet("Budget"),
                         .task("Ann: Send it", done: false), .task("Done", done: true), .paragraph("We met.")], "got \(blocks)")
        check(LibraryLogic.markdownBlocks("#hashtag\n\n* star") == [.paragraph("#hashtag"), .bullet("star")], "edge cases")
    }),

    ("summary parses into action items and topic sections", {
        let summary = MeetingSummary(title: "Standup", actionItems: [.init(task: "Validera 6 tickets innan kl. 16:00", owner: "Elin"),
                                                                     .init(task: "Boka rum", owner: nil)],
                                     topics: [.init(title: "Bugg \u{2013} Article rows", points: ["Fel avrundning", "Fix i dag"])])
        let parsed = LibraryLogic.parseSummary(ProcessingLogic.summaryMarkdown(summary, audioName: "a.m4a", language: .swedish))
        check(parsed.title == "Standup" && parsed.unavailable == nil, "title")
        check(parsed.actionItems == [
            ChecklistItem(key: "Elin: Validera 6 tickets innan kl. 16:00", task: "Validera 6 tickets innan kl. 16:00", owner: "Elin", done: false),
            ChecklistItem(key: "Boka rum", task: "Boka rum", owner: nil, done: false),
        ], "items \(parsed.actionItems)")
        check(parsed.sections == [SummarySection(heading: "Bugg \u{2013} Article rows", lines: [.bullet("Fel avrundning"), .bullet("Fix i dag")])],
              "sections \(parsed.sections)")
    }),

    ("checked state from the sidecar overrides the file", {
        let markdown = "# T\n\n## Action items\n\n- [ ] Anna: Send report\n- [x] Book room\n- [ ] Call Bo\n"
        let meta = MeetingMeta(checked: ["Anna: Send report": true, "Book room": false])
        let items = LibraryLogic.parseSummary(markdown, meta: meta).actionItems
        check(items.map(\.done) == [true, false, false], "merged \(items.map(\.done))")
        check(LibraryLogic.parseSummary(markdown).actionItems.map(\.done) == [false, true, false], "file state without sidecar")
    }),

    ("older summary files still render", {
        let legacy = """
        # Budget Q4

        _a.m4a \u{00B7} Svenska \u{00B7} on-device Apple Intelligence_

        ## Sammanfattning

        Vi gick igenom budgeten.

        ## Viktiga punkter

        - Kostnaderna ökar

        ## Åtgärder

        - [ ] Skicka rapporten \u{2014} **Anna**
        """
        let parsed = LibraryLogic.parseSummary(legacy)
        check(parsed.title == "Budget Q4", "title")
        check(parsed.actionItems.map(\.owner) == ["Anna"] && parsed.actionItems.first?.task == "Skicka rapporten", "legacy owner")
        check(parsed.sections.map(\.heading) == ["Sammanfattning", "Viktiga punkter"], "sections \(parsed.sections)")
        check(parsed.sections.first?.lines == [.paragraph("Vi gick igenom budgeten.")], "paragraph kept")
        check(LibraryLogic.checklistItem("Ring kunden innan kl. 16: viktigt", done: false).owner == nil, "a sentence before the colon is no owner")
    }),

    ("the no-summary note is recognised with its reason", {
        let markdown = ProcessingLogic.unavailableMarkdown(.appleIntelligenceOff, audioName: "Meeting-x.m4a", language: .swedish)
        let parsed = LibraryLogic.parseSummary(markdown)
        check(parsed.title == nil && parsed.isEmpty, "no title or content")
        check(parsed.unavailable == SummaryUnavailable.appleIntelligenceOff.message, "reason \(parsed.unavailable ?? "nil")")
    }),

    ("title prefers the rename, then the summary title, then Meeting", {
        check(LibraryLogic.title(override: "Mitt namn", aiTitle: "AI") == "Mitt namn", "override")
        check(LibraryLogic.title(override: "  ", aiTitle: "AI") == "AI", "blank override")
        check(LibraryLogic.title(override: nil, aiTitle: nil) == "Meeting", "fallback")
        check(LibraryLogic.titleOverride(" AI ", aiTitle: "AI") == nil, "same as shown is not stored")
        check(LibraryLogic.titleOverride("", aiTitle: "AI") == nil, "empty resets")
        check(LibraryLogic.titleOverride("Meeting", aiTitle: nil) == nil, "fallback is not stored")
        check(LibraryLogic.titleOverride(" Retro ", aiTitle: "AI") == "Retro", "trimmed rename")
    }),

    ("sidecar round-trips and tolerates missing or bad data", {
        let meta = MeetingMeta(title: "Retro", checked: ["Anna: Send": true])
        check(MeetingMeta.decode(meta.encoded()) == meta, "round trip")
        check(String(decoding: meta.encoded(), as: UTF8.self).contains("\"title\" : \"Retro\""), "readable json")
        check(MeetingMeta.decode(Data(#"{"title":"T"}"#.utf8)) == MeetingMeta(title: "T"), "missing checked")
        check(MeetingMeta.decode(Data("nope".utf8)) == MeetingMeta(), "bad json")
        check(MeetingMeta.decode(nil) == MeetingMeta(), "no file")
        let audio = URL(fileURLWithPath: "/tmp/rec/Meeting-2026-10-15-1430.m4a")
        check(ProcessingLogic.metaURL(for: audio).lastPathComponent == "Meeting-2026-10-15-1430.meta.json", "meta name")
        check(ProcessingLogic.notesURL(for: audio).lastPathComponent == "Meeting-2026-10-15-1430.notes.md", "notes name")
    }),

    ("meetings are grouped by Today, Yesterday, This week and Earlier", {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        calendar.firstWeekday = 2
        func date(_ day: Int, _ hour: Int = 10) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let now = date(15, 12)
        check(LibraryLogic.dateGroup(date(15, 8), now: now, calendar: calendar) == .today, "today")
        check(LibraryLogic.dateGroup(date(15, 20), now: now, calendar: calendar) == .today, "later today")
        check(LibraryLogic.dateGroup(date(14), now: now, calendar: calendar) == .yesterday, "yesterday")
        check(LibraryLogic.dateGroup(date(12), now: now, calendar: calendar) == .thisWeek, "monday")
        check(LibraryLogic.dateGroup(date(11), now: now, calendar: calendar) == .earlier, "last sunday")
        let monday = date(12, 9)
        check(LibraryLogic.dateGroup(date(11), now: monday, calendar: calendar) == .yesterday, "yesterday wins over last week")
        let entries = [15, 14, 13, 1].map { RecordingEntry(audio: URL(fileURLWithPath: "/tmp/\($0).m4a"), date: date($0), duration: nil) }
        let groups = LibraryLogic.grouped(entries, now: now, calendar: calendar)
        check(groups.map(\.group) == [.today, .yesterday, .thisWeek, .earlier], "order \(groups.map(\.group))")
        check(groups.map(\.entries.count) == [1, 1, 1, 1], "one each")
        check(LibraryLogic.grouped([], now: now, calendar: calendar).isEmpty, "empty groups left out")
    }),

    ("search text becomes a prefix query needing every word", {
        check(LibraryLogic.ftsQuery("  ") == nil, "empty query")
        check(LibraryLogic.ftsQuery("standup öppna") == #""standup"* "öppna"*"#, "words")
        check(LibraryLogic.ftsQuery(#"say "hi" OR"#) == #""say"* """hi"""* "OR"*"#, "quotes and operators are literal")
    }),

    ("transcripts parse back into timed paragraphs", {
        let markdown = ProcessingLogic.transcriptMarkdown(
            audioName: "Meeting-x.m4a", language: .swedish, engine: "DictationTranscriber",
            segments: [TranscriptSegment(start: 1, text: "Hej."), TranscriptSegment(start: 20, text: "Vi börjar."),
                       TranscriptSegment(start: 3725, text: "Slut.")])
        let segments = LibraryLogic.transcriptSegments(markdown)
        check(segments.map(\.start) == [1, 20, 3725] && segments.last?.text == "Slut.", "segments \(segments)")
        check(LibraryLogic.paragraphs(segments) == [TranscriptSegment(start: 1, text: "Hej. Vi börjar."),
                                                     TranscriptSegment(start: 3725, text: "Slut.")], "paragraphs")
        check(LibraryLogic.language(in: markdown) == .swedish, "language")
        check(LibraryLogic.language(in: "# T") == nil, "no language")
        check(LibraryLogic.minutesText(25 * 60 + 10) == "25 min" && LibraryLogic.minutesText(20) == "<1 min"
              && LibraryLogic.minutesText(65 * 60) == "1 h 5 min", "minutes")
    }),
]

private func segment(_ start: TimeInterval, _ text: String, _ speaker: Speaker? = nil) -> TranscriptSegment {
    TranscriptSegment(start: start, text: text, speaker: speaker)
}

private let speakerTests: [(name: String, run: () throws -> Void)] = [
    ("stems are named next to the meeting and not listed", {
        let meeting = URL(fileURLWithPath: "/tmp/rec/Meeting-2026-10-15-1430.m4a")
        let mic = RecordingLogic.stemURL(for: meeting, source: .microphone)
        let system = RecordingLogic.stemURL(for: meeting, source: .system)
        check(mic.lastPathComponent == "Meeting-2026-10-15-1430.stem-mic.m4a", "mic \(mic.lastPathComponent)")
        check(system.lastPathComponent == "Meeting-2026-10-15-1430.stem-system.m4a", "system \(system.lastPathComponent)")
        let part = RecordingLogic.partURL(for: meeting, at: Date(timeIntervalSince1970: 5))
        for url in [mic, system, RecordingLogic.partialURL(for: mic), RecordingLogic.stemURL(for: part, source: .system)] {
            check(!LibraryLogic.isListed(url.lastPathComponent), "\(url.lastPathComponent) hidden")
        }
        check(RecordingLogic.stems(of: meeting) { _ in true } == [mic, system], "both stems")
        check(RecordingLogic.stems(of: meeting) { $0 == mic } == nil, "only with every stem")
    }),

    ("the mixer writes stems that line up with the mix", {
        let url = tempURL()
        let stems = AudioSource.allCases.map { RecordingLogic.stemURL(for: url, source: $0) }
        defer { ([url] + stems).forEach { try? FileManager.default.removeItem(at: $0) } }
        let mixer = try AudioMixer(url: url, stems: true)
        feed(mixer, .microphone, sine(440, seconds: 0.6))
        mixer.pause()
        feed(mixer, .system, sine(660, seconds: 0.5))
        mixer.resume()
        feed(mixer, .system, sine(660, seconds: 0.4))
        mixer.finish()
        let mix = try seconds(of: url)
        for stem in stems {
            check(!FileManager.default.fileExists(atPath: RecordingLogic.partialURL(for: stem).path), "partial moved")
            let duration = try seconds(of: stem)
            check(abs(duration - mix) < 0.05, "\(stem.lastPathComponent) \(duration)s vs mix \(mix)s")
        }
        check(abs(mix - 1.0) < 0.15, "paused audio left out of the mix, \(mix)")
        let mic = try decode(stems[0]), system = try decode(stems[1])
        check(rms(Array(mic.prefix(24_000))) > 0.1 && rms(Array(system.prefix(24_000))) < 0.01, "first half is mine")
        check(rms(Array(mic.suffix(14_400))) < 0.01 && rms(Array(system.suffix(14_400))) > 0.1, "the rest is theirs")
    }),

    ("a part's stems are appended to the meeting's, or dropped when they would not line up", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stems-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = folder.appendingPathComponent("Meeting-2026-10-15-1430.m4a")
        let part = RecordingLogic.partURL(for: meeting, at: Date())
        func record(_ url: URL, _ length: Double) throws {
            let mixer = try AudioMixer(url: url, stems: true)
            feed(mixer, .microphone, sine(440, seconds: length))
            mixer.finish()
        }
        try record(meeting, 1.2)
        try record(part, 0.8)
        try blocking {
            try await AudioAppender.append(part, to: meeting)
            await AudioAppender.appendStems(of: part, to: meeting)
        }
        let stems = RecordingLogic.stems(of: meeting) ?? []
        check(stems.count == 2, "stems kept")
        for stem in stems { check(abs(((try? seconds(of: stem)) ?? 0) - 2.0) < 0.1, "\(stem.lastPathComponent) appended") }
        check(RecordingLogic.stems(of: part) == nil, "part stems consumed")

        let next = RecordingLogic.partURL(for: meeting, at: Date().addingTimeInterval(60))
        try record(next, 0.5)
        try FileManager.default.removeItem(at: stems[1])
        try blocking { await AudioAppender.appendStems(of: next, to: meeting) }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(RecordingLogic.stemMarker) }
        check(left.isEmpty, "a meeting without every stem falls back to its mix, left \(left)")
    }),

    ("stems merge by start time with a speaker each", {
        let merged = ProcessingLogic.mergeSpeakers(
            you: [segment(1, "Hi everyone."), segment(20, "I will send the report.")],
            others: [segment(5, "Hello, let us start."), segment(20, "Great."), segment(30, "Thanks.")])
        check(merged == [segment(1, "Hi everyone.", .you), segment(5, "Hello, let us start.", .others),
                         segment(20, "Great.", .others), segment(20, "I will send the report.", .you),
                         segment(30, "Thanks.", .others)], "merged \(merged)")
        check(ProcessingLogic.mergeSpeakers(you: [], others: []).isEmpty, "empty")
    }),

    ("speaker bleed into the microphone is dropped in favour of the system audio", {
        let others = [segment(10, "The release is on Tuesday, right?"), segment(40, "Yes.")]
        let you = [segment(10.6, "the release is on tuesday right"), segment(12, "Right, Tuesday it is."),
                   segment(20, "The release is on Tuesday, right?"), segment(41, "Yes, I think so, I agree.")]
        let merged = ProcessingLogic.mergeSpeakers(you: you, others: others)
        check(merged.map(\.start) == [10, 12, 20, 40, 41], "echo at 10.6 dropped, \(merged.map(\.start))")
        check(merged.filter { $0.speaker == .others }.count == 2, "system segments kept")
        check(ProcessingLogic.similarity("Är du där?", "ar DU dar") == 1, "case, accents and punctuation ignored")
        check(ProcessingLogic.similarity("Yes.", "Yes, I think so, I agree.") < ProcessingLogic.echoSimilarity, "different")
        check(ProcessingLogic.similarity("", "Yes") == 0, "nothing to compare")
    }),

    ("transcript paragraphs are grouped by speaker", {
        let segments = [segment(0, "Hej.", .you), segment(4, "Hur går det?", .you), segment(8, "Bra.", .others),
                        segment(12, "Vi börjar.", .others), segment(60, "Punkt två.", .others), segment(65, "Okej.", .you)]
        let turns = LibraryLogic.speakerTurns(segments)
        check(turns.map(\.speaker) == [.you, .others, .you], "turns \(turns.map(\.speaker))")
        check(turns[0].paragraphs == [segment(0, "Hej. Hur går det?", .you)], "same speaker joined")
        check(turns[1].paragraphs == [segment(8, "Bra. Vi börjar.", .others), segment(60, "Punkt två.", .others)],
              "a turn keeps its paragraphs")
        check(LibraryLogic.paragraphs([segment(0, "A.", .you), segment(2, "B.", .others)]).count == 2, "speaker breaks a paragraph")
        let plain = LibraryLogic.speakerTurns([segment(0, "A."), segment(5, "B.")])
        check(plain == [SpeakerTurn(speaker: nil, paragraphs: [segment(0, "A. B.")])], "without speakers as before")
    }),

    ("lines name the speaker in the meeting language", {
        check(segment(4, "Hej.", .you).line(.swedish) == "[00:00:04] Du: Hej.", "Du")
        check(segment(4, "Hej.", .others).line(.swedish) == "[00:00:04] Övriga: Hej.", "Övriga")
        check(segment(4, "Hi.", .others).line(.english) == "[00:00:04] Others: Hi.", "Others")
        check(segment(4, "Hi.").line(.english) == "[00:00:04] Hi.", "no speaker")
        let markdown = ProcessingLogic.transcriptMarkdown(audioName: "Meeting-x.m4a", language: .english, engine: "x",
                                                          segments: [segment(1, "Hi.", .you), segment(3, "Hello.", .others)])
        check(markdown.contains("[00:00:01] You: Hi.\n\n[00:00:03] Others: Hello."), "markdown \(markdown)")
    }),
]

private let autoStopTests: [(name: String, run: () throws -> Void)] = {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    func step(_ stop: inout AutoStop, _ seconds: TimeInterval, others: Bool, sound: TimeInterval = 0,
              paused: Bool = false, enabled: Bool = true) -> AutoStop.Decision {
        stop.update(enabled: enabled, othersUsingMic: others, paused: paused, lastSound: at(sound), now: at(seconds))
    }
    return [
        ("auto-stop asks when the other app releases the mic and stops after two minutes of silence", {
            var stop = AutoStop()
            check(step(&stop, 1, others: true) == .idle, "meeting running")
            check(step(&stop, 600, others: false, sound: 590) == .ask, "meeting ended")
            check(step(&stop, 601, others: false, sound: 590) == .idle, "asked once")
            check(step(&stop, 719, others: false, sound: 590) == .idle, "not two minutes since the end yet")
            check(step(&stop, 720, others: false, sound: 590) == .stop, "two minutes of silence since the end")
            check(step(&stop, 721, others: false, sound: 590) == .idle, "stops once")
        }),

        ("sound restarts the silence countdown", {
            var stop = AutoStop()
            _ = step(&stop, 1, others: true)
            check(step(&stop, 10, others: false, sound: 10) == .ask, "ended")
            check(step(&stop, 100, others: false, sound: 90) == .idle, "someone still talking")
            check(step(&stop, 209, others: false, sound: 90) == .idle, "119 s of silence")
            check(step(&stop, 210, others: false, sound: 90) == .stop, "120 s of silence")
        }),

        ("auto-stop needs another app to have held the mic", {
            var stop = AutoStop()
            for second in [1.0, 200, 400] { check(step(&stop, second, others: false) == .idle, "own recording at \(second)") }
        }),

        ("the meeting picking the mic back up withdraws the question", {
            var stop = AutoStop()
            _ = step(&stop, 1, others: true)
            check(step(&stop, 5, others: false) == .ask, "ended")
            check(step(&stop, 6, others: true) == .withdraw, "back")
            check(step(&stop, 7, others: true) == .idle, "withdrawn once")
            check(step(&stop, 300, others: true) == .idle, "no stop while the meeting runs")
            check(step(&stop, 301, others: false, sound: 301) == .ask, "asks again")
        }),

        ("keep recording and the menu switch turn auto-stop off", {
            var kept = AutoStop()
            _ = step(&kept, 1, others: true)
            check(step(&kept, 5, others: false) == .ask, "ended")
            kept.keepRecording()
            check(step(&kept, 1000, others: false) == .idle, "kept")
            _ = step(&kept, 1001, others: true)
            check(step(&kept, 1002, others: false) == .idle, "kept for the rest of the recording")

            var off = AutoStop()
            _ = step(&off, 1, others: true, enabled: false)
            check(step(&off, 5, others: false, enabled: false) == .idle, "switched off")
            check(step(&off, 6, others: false) == .ask, "switched on while the meeting is over")
            check(step(&off, 7, others: false, enabled: false) == .withdraw, "switched off again")
            check(step(&off, 500, others: false, enabled: false) == .idle, "never stops while off")
        }),

        ("the mixer notes when either source last had sound", {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let mixer = try AudioMixer(url: url)
            let started = mixer.lastSound
            Thread.sleep(forTimeInterval: 0.05)
            feed(mixer, .system, sine(440, seconds: 0.2, amplitude: 0.002))
            check(mixer.lastSound == started, "below the threshold is silence")
            feed(mixer, .microphone, sine(440, seconds: 0.2))
            check(mixer.lastSound > started, "speech-level audio is sound")
            mixer.finish()
        }),

        ("a paused recording is not stopped", {
            var stop = AutoStop()
            _ = step(&stop, 1, others: true)
            check(step(&stop, 5, others: false) == .ask, "ended")
            check(step(&stop, 500, others: false, paused: true) == .idle, "paused")
            check(step(&stop, 501, others: false, sound: 500) == .idle, "resuming counts as sound")
            check(step(&stop, 620, others: false, sound: 500) == .stop, "then silence")
        }),
    ]
}()
