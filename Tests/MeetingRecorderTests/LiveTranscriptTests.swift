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

    ("a stem is cut into chunks as it arrives just where the whole recording would be cut", {
        let rate = 1_000.0
        let speech = [Float](repeating: 0.1, count: 10_000), pause = [Float](repeating: 0, count: 1_000)
        let audio = speech + pause + [Float](repeating: 0.1, count: 31_000) + pause + [Float](repeating: 0, count: 3_000)
        var chunker = LiveChunker(speaker: .others, start: 0, sampleRate: rate)
        var chunks: [LiveChunk] = []
        for start in stride(from: 0, to: audio.count, by: 250) { chunks += chunker.add(Array(audio[start..<min(audio.count, start + 250)])) }
        let streamed = chunks.count
        chunks += chunker.flush()
        let frame = Int(SpeechChunks.frameLength * rate)
        let levels = stride(from: 0, to: audio.count, by: frame).map { start in
            var meter = LevelMeter()
            meter.add(Array(audio[start..<start + frame]))
            return meter.rms
        }
        let whole = SpeechChunks.chunks(levels: levels).map { Double($0.lowerBound) / 10..<Double($0.upperBound) / 10 }
        check(chunks.map { $0.start..<$0.end } == whole, "\(chunks.map { $0.start..<$0.end }) vs \(whole)")
        check(streamed == whole.count - 1, "all but the last are cut while recording")
        check(chunks[0].start == 0 && abs(chunks[0].end - 10.3) < 0.001 && chunks[0].spoken, "cut in the pause \(chunks[0].end)")
        check(chunks.dropLast().allSatisfy { $0.duration >= SpeechChunks.minimumChunk && $0.duration <= SpeechChunks.maximumChunk },
              "8 to 28 s")
        check(chunks.map(\.samples.count).reduce(0, +) == audio.count, "no audio lost")
        check(!chunks.last!.spoken, "the silent tail is not worth transcribing")
        check(chunks[1].shifted(by: 60).start == chunks[1].start + 60, "shifted into the recording")
    }),

    ("Whisper's text replaces Apple's for the stretch it transcribed, and Apple's waiting text is pending", {
        var live = LiveTranscript()
        live.expectWhisper(true)
        live.hear([said(1, "We should move the demo."), said(5, "It clashes.")], from: .others, isFinal: true)
        live.hear([said(12, "With the review.")], from: .others, isFinal: true)
        live.hear([said(3, "Okay.")], from: .you, isFinal: true)
        check(live.lines.allSatisfy(\.isPending), "Apple's lines wait for Whisper")
        live.settle(LiveSpan(speaker: .others, start: 0, end: 10,
                             outcome: .whisper(model: "ggml-large-v3", segments: [said(1.2, "We should move the demo, it clashes.")])))
        check(live.lines.map(\.text) == ["We should move the demo, it clashes.", "Okay.", "With the review."], "\(live.lines.map(\.text))")
        check(live.lines.map(\.model) == ["ggml-large-v3", nil, nil], "models")
        check(live.lines.map(\.isPending) == [false, true, true], "only Apple's text is pending")
        live.settle(LiveSpan(speaker: .others, start: 10, end: 20, outcome: .kept))
        check(live.lines.last == LiveLine(speaker: .others, start: 12, text: "With the review.", isFinal: true), "Apple's text kept for a skipped stretch")
        live.expectWhisper(false)
        check(!live.lines.contains(where: \.isPending), "nothing pending once Whisper is done")
    }),

    ("the microphone's echo is left out of Whisper's lines too", {
        let echo = "We need to move the release to next week because of the audit."
        var live = LiveTranscript()
        live.settle(LiveSpan(speaker: .you, start: 0, end: 20, outcome: .whisper(model: "m", segments: [said(10.3, echo)])))
        check(live.lines.count == 1, "kept until the system says it")
        live.settle(LiveSpan(speaker: .others, start: 0, end: 20, outcome: .whisper(model: "m", segments: [said(10, echo)])))
        check(live.lines.map(\.speaker) == [.others], "\(live.lines)")
    }),

    ("when Whisper falls more than a minute behind the oldest chunks keep Apple's text", {
        func chunk(_ start: TimeInterval, _ length: TimeInterval) -> LiveChunk {
            LiveChunk(speaker: .others, start: start, end: start + length, samples: [], spoken: true)
        }
        let pending = [chunk(0, 20), chunk(20, 20), chunk(40, 20), chunk(60, 20)]
        let backlog = LiveTranscriptLogic.backlog(pending)
        check(backlog.skipped == [chunk(0, 20)] && backlog.waiting == Array(pending.dropFirst()), "\(backlog)")
        check(LiveTranscriptLogic.backlog(Array(pending.prefix(3))).skipped.isEmpty, "a minute may wait")
        check(LiveTranscriptLogic.backlog([chunk(0, 28), chunk(28, 28), chunk(56, 28)]).skipped.count == 1, "")
        check(LiveTranscriptLogic.backlog([]).waiting.isEmpty, "nothing waiting")
    }),

    ("the live model is Best by default and follows the final transcript's Whisper model", {
        let defaults = UserDefaults(suiteName: "live-model-tests")!
        defaults.removePersistentDomain(forName: "live-model-tests")
        check(LiveModel.stored(defaults: defaults) == .best, "default")
        defaults.set(LiveModel.light.rawValue, forKey: LiveModel.storageKey)
        check(LiveModel.stored(defaults: defaults) == .light, "light")
        let large = WhisperModel.with(id: "ggml-large-v3")!
        check(LiveTranscriptLogic.whisperModel(.best, engine: .whisper(large)) == large, "same model as the final transcript")
        check(LiveTranscriptLogic.whisperModel(.light, engine: .whisper(large)) == nil, "Apple only")
        check(LiveTranscriptLogic.whisperModel(.best, engine: .apple) == nil, "no Whisper model chosen")
        check(LiveModel.best.title == "Best (Whisper, same as final)" && LiveModel.light.title == "Light (Apple Speech only)", "titles")
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

    ("the meeting's Transcript tab shows live lines unless they are off or cannot be heard", {
        check(LiveTranscriptLogic.showsInline(enabled: true, note: nil), "on")
        check(!LiveTranscriptLogic.showsInline(enabled: false, note: nil), "off in Settings")
        check(!LiveTranscriptLogic.showsInline(enabled: true, note: "needs the speech model"), "model missing")
    }),

    ("the empty live view says whether it is off, paused or listening", {
        check(LiveTranscriptLogic.placeholder(enabled: false, note: "x", paused: false, recording: true).contains("is off"), "off")
        check(LiveTranscriptLogic.placeholder(enabled: true, note: "x", paused: true, recording: true) == "x", "note")
        check(LiveTranscriptLogic.placeholder(enabled: true, note: nil, paused: true, recording: true) == "Paused", "paused")
        check(LiveTranscriptLogic.placeholder(enabled: true, note: nil, paused: false, recording: true).hasPrefix("Listening"), "listening")
        check(LiveTranscriptLogic.placeholder(enabled: true, note: nil, paused: false, recording: false).hasPrefix("Start"), "idle")
    }),
]
