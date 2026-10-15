import Foundation

enum SystemAudioAccess {
    case granted
    case denied
    case unknown
}

enum RecordingLogic {
    static let microphoneOnlyNotice = "Microphone only \u{2014} system audio off"
    static let partialSuffix = ".recording"
    static let partMarker = ".part-"
    static let combinedSuffix = ".combined"
    static let stemMarker = ".stem-"

    static func elapsedText(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func statusText(paused: Bool, elapsed: TimeInterval) -> String {
        "\(paused ? "Paused" : "Recording")  \(elapsedText(elapsed))"
    }

    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        nameFormatter(timeZone).string(from: date) + ".m4a"
    }

    /// The minute a `Meeting-YYYY-MM-DD-HHmm…` file name was started in.
    static func date(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        nameFormatter(timeZone).date(from: String(name.prefix("Meeting-YYYY-MM-DD-HHmm".count)))
    }

    private static func nameFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "'Meeting-'yyyy-MM-dd-HHmm"
        return formatter
    }

    /// The first `Meeting-…-HHmm.m4a`, `Meeting-…-HHmm-2.m4a`, … in `folder` that is free, counting in-progress files.
    static func availableURL(in folder: URL, for date: Date, timeZone: TimeZone = .current,
                             exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(fileName(for: date, timeZone: timeZone))
        let base = first.deletingPathExtension().lastPathComponent
        return (1...).lazy
            .map { $0 == 1 ? first : folder.appendingPathComponent("\(base)-\($0).m4a") }
            .first { !exists($0) && !exists(partialURL(for: $0)) }!
    }

    static func partialURL(for url: URL) -> URL {
        url.deletingPathExtension()
            .appendingPathExtension(String(partialSuffix.dropFirst()))
            .appendingPathExtension(url.pathExtension)
    }

    /// Where a continued meeting's new part is recorded before it is appended: `<base>.part-<unix time>.m4a`.
    static func partURL(for meeting: URL, at date: Date) -> URL {
        sibling(of: meeting, suffix: "\(partMarker)\(Int(date.timeIntervalSince1970))")
    }

    /// Where the meeting plus its new part is exported before it replaces the meeting.
    static func combinedURL(for meeting: URL) -> URL {
        sibling(of: meeting, suffix: combinedSuffix)
    }

    /// One source on its own next to the mix, for telling the speakers apart: `<base>.stem-mic.m4a`.
    static func stemURL(for url: URL, source: AudioSource) -> URL {
        sibling(of: url, suffix: stemMarker + source.stemName)
    }

    /// The meeting's stems when it has one for every source.
    static func stems(of url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL]? {
        let stems = AudioSource.allCases.map { stemURL(for: url, source: $0) }
        return stems.allSatisfy(exists) ? stems : nil
    }

    private static func sibling(of url: URL, suffix: String) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix + "." + url.pathExtension)
    }

    /// In-progress recordings, parts waiting to be appended, combined files waiting to replace a meeting and stems.
    static func isWorkFile(baseName: String) -> Bool {
        baseName.hasSuffix(partialSuffix) || baseName.hasSuffix(combinedSuffix) || baseName.contains(partMarker)
            || baseName.contains(stemMarker)
    }

    static func combinedDurationTolerance(_ expected: TimeInterval) -> TimeInterval {
        max(0.5, expected * 0.001)
    }

    static func isCombinedDurationValid(_ combined: TimeInterval, meeting: TimeInterval, part: TimeInterval) -> Bool {
        let expected = meeting + part
        return abs(combined - expected) <= combinedDurationTolerance(expected)
    }

    static func attemptsSystemAudio(_ access: SystemAudioAccess) -> Bool {
        access != .denied
    }

    static func notice(systemAudioActive: Bool) -> String? {
        systemAudioActive ? nil : microphoneOnlyNotice
    }

    static func recordArguments(_ arguments: [String]) -> RecordJob? {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        func seconds(_ flag: String) -> Double? { value(flag).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } }
        guard let total = seconds("--record") else { return nil }
        let pause = seconds("--pause-after").map { RecordJob.Pause(after: $0, duration: seconds("--resume-after") ?? 1) }
        return RecordJob(seconds: total, output: value("--out").map(URL.init(fileURLWithPath:)), pause: pause,
                         continuing: value("--continue").map(URL.init(fileURLWithPath:)))
    }
}

struct RecordJob: Equatable {
    struct Pause: Equatable {
        let after: Double
        let duration: Double
    }

    let seconds: Double
    var output: URL?
    var pause: Pause?
    var continuing: URL?
}

/// Recorded time: wall time since the start minus the time spent paused.
struct ElapsedClock: Equatable {
    let started: Date
    private var pausedTotal: TimeInterval = 0
    private(set) var pausedAt: Date?

    init(started: Date) {
        self.started = started
    }

    var isPaused: Bool { pausedAt != nil }

    func elapsed(at now: Date) -> TimeInterval {
        max(0, (pausedAt ?? now).timeIntervalSince(started) - pausedTotal)
    }

    mutating func pause(at now: Date) {
        if pausedAt == nil { pausedAt = now }
    }

    mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        pausedTotal += now.timeIntervalSince(pausedAt)
        self.pausedAt = nil
    }
}
