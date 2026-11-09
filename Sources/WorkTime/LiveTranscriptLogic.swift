import Foundation

struct LiveLine: Equatable {
    let speaker: Speaker
    let start: TimeInterval
    let text: String
    let isFinal: Bool
    /// The Whisper model that wrote the line, nil for Apple's speech model.
    var model: String? = nil
    /// Apple's finished sentence, shown until Whisper's text for its stretch is ready.
    var isPending = false
}

/// A stretch of one stem the Whisper pass is done with: Whisper's sentences replace Apple's in it, or Apple's are kept.
struct LiveSpan: Equatable {
    enum Outcome: Equatable {
        case whisper(model: String, segments: [TranscriptSegment])
        case kept
    }

    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
    let outcome: Outcome
}

/// What has been said while recording: the finished sentences of both stems by start time, then each stem's sentence
/// still being heard. Whisper's sentences replace Apple's in the stretches it has transcribed. Microphone sentences the
/// system audio already holds are dropped, as in the saved transcript.
struct LiveTranscript: Equatable {
    private(set) var finals: [LiveLine] = []
    private(set) var volatile: [Speaker: TranscriptSegment] = [:]
    private var apple: [TranscriptSegment] = []
    private var spans: [Speaker: [LiveSpan]] = [:]
    private var awaitsWhisper = false

    mutating func hear(_ segments: [TranscriptSegment], from speaker: Speaker, isFinal: Bool) {
        let segments = segments.map { $0.with(speaker: speaker) }.filter { !$0.text.isEmpty }
        guard isFinal else {
            volatile[speaker] = segments.first.map {
                TranscriptSegment(start: $0.start, text: segments.map(\.text).joined(separator: " "), speaker: speaker)
            }
            return
        }
        volatile[speaker] = nil
        segments.forEach { Self.insert($0, into: &apple, at: \.start) }
        rebuild()
    }

    /// Whisper is done with `span`: its sentences, or Apple's when it was skipped, are final there.
    mutating func settle(_ span: LiveSpan) {
        Self.insert(span, into: &spans[span.speaker, default: []], at: \.start)
        rebuild()
    }

    /// While Whisper runs, Apple's sentences it has not reached yet are pending.
    mutating func expectWhisper(_ expected: Bool) {
        awaitsWhisper = expected
        rebuild()
    }

    var lines: [LiveLine] {
        let others = finals.filter { $0.speaker != .you }
        let heard = volatile.values
            .compactMap { $0.speaker == .you ? ProcessingLogic.withoutEcho($0, others: Self.near($0.start, in: others)) : $0 }
            .sorted { $0.start < $1.start }
        return finals + heard.map { LiveLine(speaker: $0.speaker ?? .others, start: $0.start, text: $0.text, isFinal: false) }
    }

    var isEmpty: Bool { finals.isEmpty && volatile.isEmpty }

    private mutating func rebuild() {
        let settled = [Speaker.others, .you].flatMap { settledLines(of: $0) }.enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
        let others = settled.filter { $0.speaker != .you }
        finals = settled.compactMap { line in
            guard line.speaker == .you else { return line }
            return ProcessingLogic.withoutEcho(TranscriptSegment(start: line.start, text: line.text, speaker: line.speaker),
                                               others: Self.near(line.start, in: others))
                .map { LiveLine(speaker: line.speaker, start: line.start, text: $0.text, isFinal: true, model: line.model,
                                isPending: line.isPending) }
        }
    }

    private func settledLines(of speaker: Speaker) -> [LiveLine] {
        let spans = spans[speaker] ?? []
        let whisper = spans.flatMap { span -> [LiveLine] in
            guard case .whisper(let model, let segments) = span.outcome else { return [] }
            return segments.map { LiveLine(speaker: speaker, start: $0.start, text: $0.text, isFinal: true, model: model) }
        }
        let apple = apple.filter { $0.speaker == speaker }.compactMap { segment -> LiveLine? in
            let outcome = LiveTranscriptLogic.span(at: segment.start, in: spans)?.outcome
            guard outcome != .kept else { return LiveLine(speaker: speaker, start: segment.start, text: segment.text, isFinal: true) }
            guard outcome == nil else { return nil }
            return LiveLine(speaker: speaker, start: segment.start, text: segment.text, isFinal: true, isPending: awaitsWhisper)
        }
        return (whisper + apple).sorted { $0.start < $1.start }
    }

    private static func near(_ start: TimeInterval, in others: [LiveLine]) -> [TranscriptSegment] {
        others.filter { abs($0.start - start) <= LiveTranscriptLogic.echoWindow }
            .map { TranscriptSegment(start: $0.start, text: $0.text, speaker: $0.speaker) }
    }

    private static func insert<Element>(_ element: Element, into list: inout [Element], at time: KeyPath<Element, TimeInterval>) {
        let index = list.lastIndex { $0[keyPath: time] <= element[keyPath: time] }.map { $0 + 1 } ?? 0
        list.insert(element, at: index)
    }
}

enum LiveTranscriptError: Error, Equatable {
    case unsupported(MeetingLanguage)
    case notInstalled(MeetingLanguage)
    case failed(String)

    var note: String {
        switch self {
        case .unsupported(let language): return "Live transcript is not available in \(language.englishName) on this Mac."
        case .notInstalled(let language):
            return "Live transcript needs the \(language.englishName) speech model. Download it in Settings \u{2192} Meetings."
        case .failed(let reason): return "Live transcript stopped: \(reason)"
        }
    }
}

/// Which model writes the live transcript: Whisper behind Apple's instant text, or Apple's alone.
enum LiveModel: String, CaseIterable {
    case best
    case light

    static let storageKey = "liveTranscriptionModel"

    var title: String {
        switch self {
        case .best: return "Best (Whisper, same as final)"
        case .light: return "Light (Apple Speech only)"
        }
    }

    static func stored(defaults: UserDefaults = .standard) -> LiveModel {
        defaults.string(forKey: storageKey).flatMap(LiveModel.init(rawValue:)) ?? .best
    }
}

/// A stretch of one stem cut at a pause, with its audio at Whisper's sample rate. `spoken` is false when it holds too
/// little sound to be worth transcribing.
struct LiveChunk: Equatable {
    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
    let samples: [Float]
    let spoken: Bool

    var duration: TimeInterval { end - start }

    func shifted(by offset: TimeInterval) -> LiveChunk {
        LiveChunk(speaker: speaker, start: start + offset, end: end + offset, samples: samples, spoken: spoken)
    }
}

/// Cuts a stem's audio into chunks as it arrives, where `SpeechChunks` cuts a whole recording.
struct LiveChunker {
    let speaker: Speaker
    let sampleRate: Double
    private(set) var start: TimeInterval
    private var samples: [Float] = []
    private var levels: [Double] = []

    init(speaker: Speaker, start: TimeInterval, sampleRate: Double = WhisperLogic.sampleRate) {
        self.speaker = speaker
        self.start = start
        self.sampleRate = sampleRate
    }

    private var frame: Int { Int(SpeechChunks.frameLength * sampleRate) }

    /// The chunks that `more` finishes.
    mutating func add(_ more: [Float]) -> [LiveChunk] {
        samples += more
        while (levels.count + 1) * frame <= samples.count {
            var meter = LevelMeter()
            meter.add(Array(samples[levels.count * frame..<(levels.count + 1) * frame]))
            levels.append(meter.rms)
        }
        let ranges = SpeechChunks.chunks(levels: levels)
        guard ranges.count > 1 else { return [] }
        let finished = ranges.dropLast().map { chunk(frames: $0, through: $0.upperBound * frame) }
        cut(at: ranges[ranges.count - 1].lowerBound)
        return finished
    }

    /// What is left, as the last chunk.
    mutating func flush() -> [LiveChunk] {
        guard !samples.isEmpty else { return [] }
        let last = chunk(frames: 0..<levels.count, through: samples.count)
        start = last.end
        samples = []
        levels = []
        return [last]
    }

    private func chunk(frames: Range<Int>, through end: Int) -> LiveChunk {
        let begin = frames.lowerBound * frame
        return LiveChunk(speaker: speaker, start: start + Double(begin) / sampleRate, end: start + Double(end) / sampleRate,
                         samples: Array(samples[begin..<end]),
                         spoken: !SpeechChunks.spoken([frames], levels: levels).isEmpty)
    }

    private mutating func cut(at frames: Int) {
        samples.removeFirst(frames * frame)
        levels.removeFirst(frames)
        start += Double(frames * frame) / sampleRate
    }
}

enum LiveTranscriptLogic {
    static let enabledKey = "liveTranscription"
    /// How far apart in time a microphone and a system sentence can be and still be compared for echo.
    static let echoWindow: TimeInterval = 30
    /// How close to the end counts as following the latest line.
    static let bottomSlack = 40.0
    /// Seconds of audio waiting for Whisper beyond which the oldest is left to Apple's text.
    static let maximumBacklog: TimeInterval = 60

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }

    /// The Whisper model behind the live text: the one the final transcript uses, unless the live model is Light or
    /// meetings are transcribed with Apple.
    static func whisperModel(_ choice: LiveModel, engine: TranscriptionEngine) -> WhisperModel? {
        guard choice == .best, case .whisper(let model) = engine else { return nil }
        return model
    }

    /// The chunks to keep waiting for Whisper, and the oldest ones skipped so no more than `limit` seconds wait.
    static func backlog(_ pending: [LiveChunk], limit: TimeInterval = maximumBacklog) -> (waiting: [LiveChunk], skipped: [LiveChunk]) {
        var waiting = pending[...]
        var total = pending.reduce(0) { $0 + $1.duration }
        while total > limit, let oldest = waiting.first {
            total -= oldest.duration
            waiting = waiting.dropFirst()
        }
        return (Array(waiting), Array(pending[..<waiting.startIndex]))
    }

    /// The span `time` falls in; `spans` are ordered by start.
    static func span(at time: TimeInterval, in spans: [LiveSpan]) -> LiveSpan? {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, time < spans[low - 1].end else { return nil }
        return spans[low - 1]
    }

    /// The meeting's chosen language, or the first one listened for.
    static func language(among candidates: [MeetingLanguage]) -> MeetingLanguage { candidates.first ?? .current }

    static func speaker(of source: AudioSource) -> Speaker { source == .microphone ? .you : .others }

    static func shifted(_ segments: [TranscriptSegment], by offset: TimeInterval) -> [TranscriptSegment] {
        segments.map { TranscriptSegment(start: $0.start + offset, text: $0.text, speaker: $0.speaker) }
    }

    /// A line names its speaker when the line before it is someone else's.
    static func showsSpeaker(_ lines: [LiveLine], at index: Int) -> Bool {
        index == 0 || lines[index - 1].speaker != lines[index].speaker
    }

    /// What the live view says while no line has been heard.
    static func placeholder(enabled: Bool, note: String?, paused: Bool, recording: Bool) -> String {
        if !enabled { return "Live transcription is off. Turn it on in Settings \u{2192} Meetings." }
        if let note { return note }
        if paused { return "Paused" }
        return recording ? "Listening\u{2026} Text appears here as people speak." : "Start a recording to see what is said."
    }

    /// The meeting's Transcript tab shows the live lines while it records, unless they are off or cannot be heard.
    static func showsInline(enabled: Bool, note: String?) -> Bool { enabled && note == nil }

    static func isAtBottom(offset: Double, visibleHeight: Double, contentHeight: Double) -> Bool {
        offset + visibleHeight >= contentHeight - bottomSlack
    }
}
