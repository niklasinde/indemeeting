import Foundation

/// A new recording's audio is deleted once its transcript and summary are saved. Recordings made in developer mode,
/// and those made before this rule, have no expiry and keep their audio.
enum AudioRetention {
    static let developerModeKey = "developerMode"

    enum State: Equatable {
        case kept
        case waiting(String)
        case due
        case deleted(Date)
    }

    static func developerMode(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: developerModeKey) }

    /// The expiry a recording gets when it starts: right away, or none in developer mode.
    static func expiry(created: Date, developerMode: Bool) -> Date? { developerMode ? nil : created }

    static func state(of meeting: Meeting, now: Date) -> State {
        if let deleted = meeting.audioDeletedAt { return .deleted(deleted) }
        guard let expires = meeting.audioExpiresAt else { return .kept }
        if !meeting.transcribed { return .waiting("Audio kept: not transcribed yet") }
        if !meeting.summarised { return .waiting("Audio kept: not summarised yet") }
        return expires <= now ? .due : .kept
    }

    static func due(_ meetings: [Meeting], now: Date, busy: Set<String>) -> [Meeting] {
        meetings.filter { state(of: $0, now: now) == .due && !busy.contains($0.audioFile) }
    }

    static func deletedText(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated)
        style.calendar = Calendar(identifier: .gregorian)
        return "Audio deleted on " + date.formatted(style)
    }

    /// The recording itself and the stems, parts and combined files next to it.
    static func files(of audioFile: String, among names: [String]) -> [String] {
        let base = (audioFile as NSString).deletingPathExtension
        return names.filter { name in
            if name == audioFile { return true }
            let url = URL(fileURLWithPath: name)
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix(base + "."), LibraryLogic.audioExtensions.contains(url.pathExtension.lowercased()) else { return false }
            return RecordingLogic.isWorkFile(baseName: String(stem.dropFirst(base.count)))
        }
    }

    static func existingFiles(of audioFile: String, in folder: URL, fileManager: FileManager = .default) -> [URL] {
        files(of: audioFile, among: (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .map { folder.appendingPathComponent($0) }
    }

    /// Removes the recording's audio for good (not to the Trash) and records when.
    static func deleteAudio(of audioFile: String, in folder: URL, store: MeetingStore, now: Date,
                            fileManager: FileManager = .default) throws {
        for url in existingFiles(of: audioFile, in: folder, fileManager: fileManager) { try fileManager.removeItem(at: url) }
        try store.setAudioDeleted(audioFile, at: now)
    }

    /// Deletes the audio of every due meeting that is not being recorded or processed; returns their files.
    @discardableResult
    static func sweep(store: MeetingStore, folder: URL, now: Date, busy: Set<String>,
                      fileManager: FileManager = .default) throws -> [String] {
        due(try store.meetings(), now: now, busy: busy).compactMap { meeting in
            do {
                try deleteAudio(of: meeting.audioFile, in: folder, store: store, now: now, fileManager: fileManager)
                return meeting.audioFile
            } catch {
                FileHandle.standardError.write(Data("Could not delete the audio of \(meeting.audioFile): \(error.localizedDescription)\n".utf8))
                return nil
            }
        }
    }
}
