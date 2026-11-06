import Foundation

struct LiveLine: Equatable {
    let speaker: Speaker
    let start: TimeInterval
    let text: String
    let isFinal: Bool
}

/// What has been said while recording: the finished sentences of both stems by start time, then each stem's sentence
/// still being heard. Microphone sentences the system audio already holds are dropped, as in the saved transcript.
struct LiveTranscript: Equatable {
    private(set) var finals: [TranscriptSegment] = []
    private(set) var volatile: [Speaker: TranscriptSegment] = [:]

    mutating func hear(_ segments: [TranscriptSegment], from speaker: Speaker, isFinal: Bool) {
        let segments = segments.map { $0.with(speaker: speaker) }.filter { !$0.text.isEmpty }
        guard isFinal else {
            volatile[speaker] = segments.first.map {
                TranscriptSegment(start: $0.start, text: segments.map(\.text).joined(separator: " "), speaker: speaker)
            }
            return
        }
        volatile[speaker] = nil
        for segment in segments {
            if speaker == .you {
                if let kept = ProcessingLogic.withoutEcho(segment, others: others(near: segment)) { insert(kept) }
            } else {
                insert(segment)
                dropEcho(near: segment)
            }
        }
    }

    var lines: [LiveLine] {
        let heard = volatile.values
            .compactMap { $0.speaker == .you ? ProcessingLogic.withoutEcho($0, others: others(near: $0)) : $0 }
            .sorted { $0.start < $1.start }
        return finals.map { LiveLine(segment: $0, isFinal: true) } + heard.map { LiveLine(segment: $0, isFinal: false) }
    }

    var isEmpty: Bool { finals.isEmpty && volatile.isEmpty }

    private mutating func insert(_ segment: TranscriptSegment) {
        let index = finals.lastIndex { $0.start <= segment.start }.map { $0 + 1 } ?? 0
        finals.insert(segment, at: index)
    }

    private func others(near segment: TranscriptSegment) -> [TranscriptSegment] {
        (finals + Array(volatile.values)).filter {
            $0.speaker != .you && abs($0.start - segment.start) <= LiveTranscriptLogic.echoWindow
        }
    }

    /// System speech that arrives after the microphone heard it as echo takes the echo out again.
    private mutating func dropEcho(near segment: TranscriptSegment) {
        for index in finals.indices.reversed()
        where finals[index].speaker == .you && abs(finals[index].start - segment.start) <= LiveTranscriptLogic.echoWindow {
            if let kept = ProcessingLogic.withoutEcho(finals[index], others: others(near: finals[index])) {
                finals[index] = kept
            } else {
                finals.remove(at: index)
            }
        }
    }
}

private extension LiveLine {
    init(segment: TranscriptSegment, isFinal: Bool) {
        self.init(speaker: segment.speaker ?? .others, start: segment.start, text: segment.text, isFinal: isFinal)
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

enum LiveTranscriptLogic {
    static let enabledKey = "liveTranscription"
    /// How far apart in time a microphone and a system sentence can be and still be compared for echo.
    static let echoWindow: TimeInterval = 30
    /// How close to the end counts as following the latest line.
    static let bottomSlack = 40.0

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }

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

    static func isAtBottom(offset: Double, visibleHeight: Double, contentHeight: Double) -> Bool {
        offset + visibleHeight >= contentHeight - bottomSlack
    }
}
