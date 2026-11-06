import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func said(_ start: TimeInterval, _ text: String) -> TranscriptSegment { TranscriptSegment(start: start, text: text) }

let liveTranscriptTests: [(name: String, run: () throws -> Void)] = [
    ("live lines from both stems are ordered by when they were said, whichever arrived first", {
        var live = LiveTranscript()
        live.hear([said(4, "Then we ship on Friday.")], from: .others, isFinal: true)
        live.hear([said(1, "Shall we start?")], from: .you, isFinal: true)
        live.hear([said(4, "Sounds good to me.")], from: .you, isFinal: true)
        check(live.lines.map(\.text) == ["Shall we start?", "Then we ship on Friday.", "Sounds good to me."], "\(live.lines.map(\.text))")
        check(live.lines.map(\.speaker) == [.you, .others, .you], "speakers")
        check(live.lines.allSatisfy(\.isFinal), "all final")
    }),

    ("a partial result replaces the one before it and is cleared when its stem's final result arrives", {
        var live = LiveTranscript()
        live.hear([said(2, "We should")], from: .others, isFinal: false)
        live.hear([said(2, "We should move the")], from: .others, isFinal: false)
        check(live.lines == [LiveLine(speaker: .others, start: 2, text: "We should move the", isFinal: false)], "latest partial only")
        live.hear([said(2, "We should move the demo."), said(5, "It clashes.")], from: .others, isFinal: true)
        check(live.lines.map(\.text) == ["We should move the demo.", "It clashes."], "\(live.lines.map(\.text))")
        check(live.volatile.isEmpty, "partial cleared")
    }),

    ("partial results follow the finished lines and each stem keeps its own", {
        var live = LiveTranscript()
        live.hear([said(1, "Hello everyone.")], from: .others, isFinal: true)
        live.hear([said(9, "and the budget")], from: .others, isFinal: false)
        live.hear([said(8, "I think")], from: .you, isFinal: false)
        check(live.lines.map(\.text) == ["Hello everyone.", "I think", "and the budget"], "\(live.lines.map(\.text))")
        check(live.lines.map(\.isFinal) == [true, false, false], "partials are not final")
        live.hear([], from: .you, isFinal: false)
        check(live.lines.map(\.text) == ["Hello everyone.", "and the budget"], "an empty partial clears it")
    }),

    ("the microphone's echo of system speech is left out of the live lines, whichever stem finishes first", {
        let echo = "We need to move the release to next week because of the audit."
        var micFirst = LiveTranscript()
        micFirst.hear([said(10, echo)], from: .you, isFinal: true)
        micFirst.hear([said(10.4, echo)], from: .others, isFinal: true)
        check(micFirst.lines.map(\.speaker) == [.others], "echo removed when system speech arrives later: \(micFirst.lines)")
        var systemFirst = LiveTranscript()
        systemFirst.hear([said(10, echo)], from: .others, isFinal: true)
        systemFirst.hear([said(10.5, echo + " Yes, that works for me.")], from: .you, isFinal: true)
        check(systemFirst.lines.map(\.text) == [echo, "Yes, that works for me."], "\(systemFirst.lines.map(\.text))")
        var partial = LiveTranscript()
        partial.hear([said(10, echo)], from: .others, isFinal: true)
        partial.hear([said(10.2, echo)], from: .you, isFinal: false)
        check(partial.lines.count == 1, "a partial echo is hidden too")
    }),

    ("a reply long after the system speech is kept even when it repeats it", {
        let words = "We need to move the release to next week."
        var live = LiveTranscript()
        live.hear([said(10, words)], from: .others, isFinal: true)
        live.hear([said(200, words)], from: .you, isFinal: true)
        check(live.lines.count == 2, "\(live.lines)")
    }),

    ("live transcription defaults to on, runs in the first language listened for and labels the stems", {
        let defaults = UserDefaults(suiteName: "live-transcript-tests")!
        defaults.removePersistentDomain(forName: "live-transcript-tests")
        check(LiveTranscriptLogic.isEnabled(defaults: defaults), "default on")
        defaults.set(false, forKey: LiveTranscriptLogic.enabledKey)
        check(!LiveTranscriptLogic.isEnabled(defaults: defaults), "turned off")
        check(LiveTranscriptLogic.language(among: [.swedish, .english]) == .swedish, "first listened")
        check(LiveTranscriptLogic.language(among: [.english]) == .english, "chosen")
        check(LiveTranscriptLogic.speaker(of: .microphone) == .you && LiveTranscriptLogic.speaker(of: .system) == .others, "speakers")
        check(Speaker.you.name(in: .swedish) == "Du", "Du")
    }),

    ("live times after a pause continue from where the recording was", {
        let shifted = LiveTranscriptLogic.shifted([said(1.5, "Back again.")], by: 60)
        check(shifted == [said(61.5, "Back again.")], "\(shifted)")
    }),

    ("a live line names its speaker only when the speaker changes", {
        let lines = [LiveLine(speaker: .you, start: 0, text: "a", isFinal: true), LiveLine(speaker: .you, start: 1, text: "b", isFinal: true),
                     LiveLine(speaker: .others, start: 2, text: "c", isFinal: false)]
        check((0..<3).map { LiveTranscriptLogic.showsSpeaker(lines, at: $0) } == [true, false, true], "labels")
    }),

    ("the live transcript follows new lines only while it is scrolled to the end", {
        check(LiveTranscriptLogic.isAtBottom(offset: 600, visibleHeight: 400, contentHeight: 1000), "at the end")
        check(LiveTranscriptLogic.isAtBottom(offset: 570, visibleHeight: 400, contentHeight: 1000), "close enough")
        check(!LiveTranscriptLogic.isAtBottom(offset: 200, visibleHeight: 400, contentHeight: 1000), "scrolled up")
        check(LiveTranscriptLogic.isAtBottom(offset: 0, visibleHeight: 400, contentHeight: 100), "short content")
    }),

    ("a live transcript note says why it is not showing anything", {
        check(LiveTranscriptError.notInstalled(.swedish).note.contains("Swedish speech model"), "not installed")
        check(LiveTranscriptError.unsupported(.english).note.contains("not available in English"), "unsupported")
    }),
]
