import Foundation

enum SystemAudioAccess {
    case granted
    case denied
    case unknown
}

enum RecordingLogic {
    static let microphoneOnlyNotice = "Microphone only \u{2014} system audio off"
    static let partialSuffix = ".recording"

    static func elapsedText(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "'Meeting-'yyyy-MM-dd-HHmm'.m4a'"
        return formatter.string(from: date)
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

    static func attemptsSystemAudio(_ access: SystemAudioAccess) -> Bool {
        access != .denied
    }

    static func notice(systemAudioActive: Bool) -> String? {
        systemAudioActive ? nil : microphoneOnlyNotice
    }

    static func recordArguments(_ arguments: [String]) -> (seconds: Double, output: URL?)? {
        guard let index = arguments.firstIndex(of: "--record"), index + 1 < arguments.count,
              let seconds = Double(arguments[index + 1]), seconds > 0
        else { return nil }
        let output = arguments.firstIndex(of: "--out").flatMap {
            $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil
        }
        return (seconds, output)
    }
}
