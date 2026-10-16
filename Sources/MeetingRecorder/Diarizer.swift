import Foundation
#if canImport(FluidAudio)
import FluidAudio

/// Tells the speakers of a recording apart on this Mac with FluidAudio's offline pyannote/WeSpeaker pipeline.
enum Diarizer {
    static let isAvailable = true

    /// Downloads the models from Hugging Face into `AppPaths.models` and checks they load.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await OfflineDiarizerModels.load(from: AppPaths.models) { progress($0.fractionCompleted) }
    }

    static func diarize(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [VoiceSegment] {
        let manager = OfflineDiarizerManager()
        manager.initialize(models: try await OfflineDiarizerModels.load(from: AppPaths.models))
        let result = try await manager.process(audio) { done, total in progress(Double(done) / Double(max(total, 1))) }
        return result.segments.map {
            VoiceSegment(id: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds),
                         embedding: $0.embedding)
        }
    }
}
#else
enum Diarizer {
    static let isAvailable = false

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws { throw DiarizerUnavailable() }

    static func diarize(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [VoiceSegment] {
        throw DiarizerUnavailable()
    }
}

struct DiarizerUnavailable: LocalizedError {
    var errorDescription: String? { "This build of Meeting Recorder does not include speaker recognition." }
}
#endif

extension Diarizer {
    /// Whether meetings get numbered speakers: the models are downloaded and this build can run them.
    static var isReady: Bool { isAvailable && SpeakerModel.isInstalled() }

    /// The audio to tell the other participants apart in: the system stem, or the mix for meetings without stems.
    static func source(of audio: URL) -> URL {
        RecordingLogic.stems(of: audio)?[AudioSource.system.rawValue] ?? audio
    }

    /// The transcript with the other participants' segments given to Speaker 1, Speaker 2, …, and those speakers named
    /// by the known voices they match.
    static func recognise(_ segments: [TranscriptSegment], in audio: URL, known: [KnownVoice],
                          progress: @escaping @Sendable (Double) -> Void) async throws
    -> (segments: [TranscriptSegment], speakers: [SpeakerProfile]) {
        let diarized = SpeakerLogic.numbered(try await diarize(source(of: audio), progress: progress))
        guard !diarized.spans.isEmpty else { return (segments, []) }
        return (SpeakerLogic.assign(segments, to: diarized.spans), SpeakerLogic.profiles(voices: diarized.voices, known: known))
    }
}
