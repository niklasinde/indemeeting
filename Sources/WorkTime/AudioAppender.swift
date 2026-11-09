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

    /// Appends the part's stems to the meeting's. Stems that would not line up with the meeting (it has none, or an
    /// append failed) are removed, so the meeting falls back to transcribing its mix.
    static func appendStems(of part: URL, to meeting: URL) async {
        let pairs = AudioSource.allCases.map {
            (part: RecordingLogic.stemURL(for: part, source: $0), meeting: RecordingLogic.stemURL(for: meeting, source: $0))
        }
        do {
            guard RecordingLogic.stems(of: part) != nil, RecordingLogic.stems(of: meeting) != nil else {
                throw CocoaError(.fileNoSuchFile)
            }
            for pair in pairs { try await append(pair.part, to: pair.meeting) }
        } catch {
            for pair in pairs {
                try? FileManager.default.removeItem(at: pair.part)
                try? FileManager.default.removeItem(at: pair.meeting)
            }
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
        try await encode(composition, to: output)
    }

    /// Decodes the composition to 48 kHz mono PCM and writes it with the recorder's AAC settings.
    private static func encode(_ asset: AVAsset, to output: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: PCMNormalizer.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        nonisolated(unsafe) let source = AVAssetReaderAudioMixOutput(audioTracks: try await asset.loadTracks(withMediaType: .audio), audioSettings: pcm)
        reader.add(source)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        nonisolated(unsafe) let input = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioMixer.encoderSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        let queue = DispatchQueue(label: "audio-appender")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = source.copyNextSampleBuffer(), input.append(buffer) else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? writer.error ?? CocoaError(.fileReadUnknown)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
