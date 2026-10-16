import Foundation

/// The on-device speaker diarization models (FluidAudio's offline pyannote pipeline), downloaded from Hugging Face
/// into `AppPaths.models` when the user turns speaker recognition on in Settings.
enum SpeakerModel {
    static let name = "Speaker recognition"
    static let folderName = "speaker-diarization"
    static let requiredFiles = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc",
                                "plda-parameters.json"]
    static let bytes: Int64 = 21_600_000

    static var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func folder(in models: URL = AppPaths.models) -> URL { models.appendingPathComponent(folderName, isDirectory: true) }

    static func isInstalled(in models: URL = AppPaths.models) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: folder(in: models).appendingPathComponent($0).path) }
    }

    static func remove(in models: URL = AppPaths.models) {
        try? FileManager.default.removeItem(at: folder(in: models))
    }
}

/// A stretch of audio the diarizer gave to one of its speakers, with that speaker's voice embedding.
struct VoiceSegment: Equatable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    var embedding: [Float] = []
}

struct SpeakerSpan: Equatable {
    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
}

/// A speaker of one meeting: the name the user gave it and its voice.
struct SpeakerProfile: Equatable {
    let speaker: Speaker
    var name: String?
    var embedding: [Float]?
}

/// A named voice remembered across meetings.
struct KnownVoice: Equatable, Identifiable {
    let id: Int64
    let name: String
    let embedding: [Float]
    let updated: Date
}

struct TranscriptRow: Equatable {
    let paragraph: TranscriptSegment
    /// The speaker's label is shown on the first paragraph and whenever the speaker changes.
    let showsSpeaker: Bool
}

enum SpeakerLogic {
    /// A known voice names a speaker when their embeddings are at most FluidAudio's "same speaker (high confidence)"
    /// cosine distance of 0.5 apart.
    static let recognitionThreshold = 0.5
    /// How long a transcript segment is taken to last when the next one starts later or there is none.
    static let maxSegmentLength: TimeInterval = 15

    /// The diarized segments as Speaker 1, Speaker 2, … in order of first appearance, and each speaker's voice as the
    /// mean of their segment embeddings.
    static func numbered(_ segments: [VoiceSegment]) -> (spans: [SpeakerSpan], voices: [Speaker: [Float]]) {
        var numbers: [String: Int] = [:]
        var groups: [Speaker: [[Float]]] = [:]
        let spans = segments.sorted { $0.start < $1.start }.map { segment in
            let number = numbers[segment.id] ?? numbers.count + 1
            numbers[segment.id] = number
            if !segment.embedding.isEmpty { groups[.numbered(number), default: []].append(segment.embedding) }
            return SpeakerSpan(speaker: .numbered(number), start: segment.start, end: segment.end)
        }
        return (spans, groups.compactMapValues(mean))
    }

    /// Gives each segment not spoken by you the speaker it overlaps most, or the nearest one when it overlaps none.
    static func assign(_ segments: [TranscriptSegment], to spans: [SpeakerSpan]) -> [TranscriptSegment] {
        guard !spans.isEmpty else { return segments }
        let theirs = segments.indices.filter { segments[$0].speaker != .you }
        var result = segments
        for (offset, index) in theirs.enumerated() {
            let start = segments[index].start
            let next = offset + 1 < theirs.count ? segments[theirs[offset + 1]].start : .infinity
            let end = max(min(next, start + maxSegmentLength), start + 0.5)
            let best = spans.max { score($0, start, end) < score($1, start, end) }
            result[index] = segments[index].with(speaker: best?.speaker)
        }
        return result
    }

    /// The overlap in seconds, or minus the gap when the span does not overlap.
    private static func score(_ span: SpeakerSpan, _ start: TimeInterval, _ end: TimeInterval) -> Double {
        min(span.end, end) - max(span.start, start)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, left = 0.0, right = 0.0
        for (x, y) in zip(a, b) {
            dot += Double(x) * Double(y)
            left += Double(x) * Double(x)
            right += Double(y) * Double(y)
        }
        return left > 0 && right > 0 ? dot / (left.squareRoot() * right.squareRoot()) : 0
    }

    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        return (0..<first.count).map { index in vectors.reduce(0) { $0 + $1[index] } / Float(vectors.count) }
    }

    /// A known voice updated with a new recording of it: the mean of both, each scaled to unit length first.
    static func blend(_ old: [Float], _ new: [Float]) -> [Float] {
        guard old.count == new.count else { return new }
        return mean([normalized(old), normalized(new)]) ?? new
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    /// Names the speakers whose voice matches a known one, best matches first, so each voice names at most one speaker.
    static func recognise(_ voices: [Speaker: [Float]], known: [KnownVoice],
                          threshold: Double = recognitionThreshold) -> SpeakerNames {
        let pairs = voices.flatMap { speaker, voice in
            known.map { (speaker: speaker, name: $0.name, similarity: cosine(voice, $0.embedding)) }
        }
        .filter { $0.similarity >= 1 - threshold }
        .sorted { $0.similarity > $1.similarity }
        var names: SpeakerNames = [:]
        for pair in pairs where names[pair.speaker] == nil && !names.values.contains(pair.name) {
            names[pair.speaker] = pair.name
        }
        return names
    }

    /// The speakers of a meeting after diarization, named by the known voices they match.
    static func profiles(voices: [Speaker: [Float]], known: [KnownVoice]) -> [SpeakerProfile] {
        let names = recognise(voices, known: known)
        return voices.keys.sorted { $0.rawValue < $1.rawValue }.map {
            SpeakerProfile(speaker: $0, name: names[$0], embedding: voices[$0])
        }
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        var vector = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = vector.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return vector
    }

    /// The transcript as paragraphs, labelled with their speaker whenever it changes.
    static func rows(_ segments: [TranscriptSegment], span: TimeInterval = 30) -> [TranscriptRow] {
        let paragraphs = LibraryLogic.paragraphs(segments, span: span)
        return paragraphs.enumerated().map { index, paragraph in
            TranscriptRow(paragraph: paragraph, showsSpeaker: paragraph.speaker != nil
                          && (index == 0 || paragraphs[index - 1].speaker != paragraph.speaker))
        }
    }
}
