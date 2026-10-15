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

    ("system audio only attempted with screen recording granted", {
        check(RecordingLogic.attemptsSystemAudio(screenRecordingGranted: true), "granted")
        check(!RecordingLogic.attemptsSystemAudio(screenRecordingGranted: false), "not granted")
        check(RecordingLogic.notice(systemAudioActive: true) == nil, "no notice when active")
        check(RecordingLogic.notice(systemAudioActive: false) == RecordingLogic.microphoneOnlyNotice, "mic-only notice")
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
]
