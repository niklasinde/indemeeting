import AVFoundation

enum AudioFiles {
    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

struct AppendError: LocalizedError {
    let part: URL
    let reason: String

    var errorDescription: String? {
        "Could not add the new part to the meeting (\(reason)). The meeting is unchanged and the new part is kept at \(part.path)."
    }
}

/// Appends a newly recorded part to a meeting: exports both into a combined file next to it, checks its length and
/// only then replaces the meeting. On any failure the meeting and the part are left as they were.
enum AudioAppender {
    static func append(_ part: URL, to meeting: URL) async throws {
        let combined = RecordingLogic.combinedURL(for: meeting)
        do {
            let meetingDuration = try AudioFiles.duration(of: meeting)
            let partDuration = try AudioFiles.duration(of: part)
            try? FileManager.default.removeItem(at: combined)
            try await export([meeting, part], to: combined)
            let combinedDuration = try AudioFiles.duration(of: combined)
            guard RecordingLogic.isCombinedDurationValid(combinedDuration, meeting: meetingDuration, part: partDuration) else {
                throw AppendError(part: part, reason: String(format: "combined file is %.1fs, expected %.1fs",
                                                             combinedDuration, meetingDuration + partDuration))
            }
            _ = try FileManager.default.replaceItemAt(meeting, withItemAt: combined)
            try? FileManager.default.removeItem(at: part)
        } catch {
            try? FileManager.default.removeItem(at: combined)
            throw error as? AppendError ?? AppendError(part: part, reason: error.localizedDescription)
        }
    }

    private static func export(_ sources: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileWriteUnknown) }
        let assets = sources.map { AVURLAsset(url: $0) }
        defer { withExtendedLifetime(assets) {} }
        var cursor = CMTime.zero
        for asset in assets {
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: asset.url.path])
            }
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = cursor + range.duration
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.outputURL = output
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
    }
}
