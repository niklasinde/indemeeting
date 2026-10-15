import Foundation

enum RecordingLogic {
    static let microphoneOnlyNotice = "Microphone only \u{2014} system audio off"

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

    static func attemptsSystemAudio(screenRecordingGranted: Bool) -> Bool {
        screenRecordingGranted
    }

    static func notice(systemAudioActive: Bool) -> String? {
        systemAudioActive ? nil : microphoneOnlyNotice
    }
}
