import Foundation

private let now = Date(timeIntervalSince1970: 1_000_000)

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func userLine(_ content: Any, extra: [String: Any] = [:]) -> String {
    line(["type": "user", "message": ["role": "user", "content": content]].merging(extra) { $1 })
}

private func assistantLine(_ blocks: [[String: Any]]) -> String {
    line(["type": "assistant", "message": ["role": "assistant", "content": blocks]])
}

private func assistantEntry(_ text: String) -> TranscriptEntry {
    TranscriptEntry(id: "a", kind: .assistant, text: text)
}

private func row(_ id: String, _ url: String, kind: SessionRow.Kind = .terminal, state: SessionState = .done,
                 title: String = "Review", updated: TimeInterval = 0) -> SessionRow {
    SessionRow(id: id, url: url, title: title, kind: kind, state: state, updated: Date(timeIntervalSince1970: updated), sessionID: nil)
}

private let app12 = "https://github.com/acme/app/pull/12"
private let api7 = "https://github.com/acme/api/pull/7"

private func temporaryFile(_ text: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("session.jsonl")
    try Data(text.utf8).write(to: url)
    return url
}

let sessionsTests: [(name: String, run: () throws -> Void)] = [
    ("transcript lines become user, assistant and tool entries", {
        check(SessionTranscript.entries(line: userLine("Fix the build"), id: "1") == [TranscriptEntry(id: "1", kind: .user, text: "Fix the build")],
              "plain user text")
        let array = userLine([["type": "text", "text": "Look at this"], ["type": "image"]])
        check(SessionTranscript.entries(line: array, id: "2").map(\.text) == ["Look at this"], "user blocks keep their text")
        let toolResult = userLine([["type": "tool_result", "tool_use_id": "t1", "content": "ok"]])
        check(SessionTranscript.entries(line: toolResult, id: "3").isEmpty, "a tool result is not a user bubble")
        let mixed = assistantLine([["type": "text", "text": "Checking the PR."],
                                   ["type": "tool_use", "name": "Bash", "input": ["command": "gh pr view 12"]],
                                   ["type": "thinking", "thinking": "hmm"]])
        let parsed = SessionTranscript.entries(line: mixed, id: "4")
        check(parsed.map(\.kind) == [.assistant, .tool(name: "Bash")], "assistant text then one tool, thinking skipped: \(parsed)")
        check(parsed.last?.text == "gh pr view 12", "tool detail is its command")
    }),

    ("lines that are not transcript messages give no entries", {
        check(SessionTranscript.entries(line: line(["type": "system", "message": ["content": "x"]]), id: "1").isEmpty, "system lines are hidden")
        check(SessionTranscript.entries(line: userLine("caveat", extra: ["isMeta": true]), id: "2").isEmpty, "meta lines are hidden")
        check(SessionTranscript.entries(line: userLine("side", extra: ["isSidechain": true]), id: "3").isEmpty, "sidechain lines are hidden")
        check(SessionTranscript.entries(line: "{not json", id: "4").isEmpty, "malformed JSON gives nothing")
        check(SessionTranscript.entries(line: line(["type": "summary", "summary": "x"]), id: "5").isEmpty, "unknown types give nothing")
        check(SessionTranscript.entries(line: "", id: "6").isEmpty, "an empty line gives nothing")
        check(SessionTranscript.entries(line: assistantLine([["type": "text", "text": "  "]]), id: "7").isEmpty, "blank text gives nothing")
    }),

    ("reminders and command plumbing are stripped", {
        check(SessionTranscript.visibleText("<system-reminder>Be brief</system-reminder>Fix it") == "Fix it", "reminder removed")
        check(SessionTranscript.visibleText("<system-reminder>only this</system-reminder>").isEmpty, "a reminder alone shows nothing")
        check(SessionTranscript.visibleText("<command-message>init</command-message>\n<command-name>/init</command-name>") == "/init",
              "a slash command shows its name")
        check(SessionTranscript.visibleText("<local-command-stdout>done</local-command-stdout>  ok ") == "ok", "command output removed")
    }),

    ("the tail reads whole lines and keeps a partial one for the next read", {
        var tail = TranscriptTail()
        _ = tail.readStart(size: 0, fileID: 1)
        check(tail.consume(Data("a\nb".utf8)) == ["a"], "only the complete line")
        check(tail.consume(Data("c\nd\n".utf8)) == ["bc", "d"], "the partial line completes")
        check(tail.consume(Data()).isEmpty, "nothing new gives nothing")
        check(tail.offset == 7, "offset counts every byte read: \(tail.offset)")
    }),

    ("the tail starts again when the file shrinks or is replaced", {
        var tail = TranscriptTail()
        _ = tail.readStart(size: 0, fileID: 1)
        _ = tail.consume(Data("one\ntwo\n".utf8))
        let shrunk = tail.readStart(size: 4, fileID: 1)
        check(shrunk.restarted && shrunk.from == 0, "a shorter file is read from the top")
        var replaced = TranscriptTail()
        _ = replaced.readStart(size: 8, fileID: 1)
        _ = replaced.consume(Data("one\ntwo\n".utf8))
        let renamed = replaced.readStart(size: 8, fileID: 2)
        check(renamed.restarted && renamed.from == 0, "a new file identity is read from the top")
        var same = TranscriptTail()
        _ = same.readStart(size: 8, fileID: 1)
        check(!same.readStart(size: 12, fileID: 1).restarted, "a growing file is not restarted")
    }),

    ("a long transcript is read from its last window, without a cut line", {
        var tail = TranscriptTail()
        let start = tail.readStart(size: TranscriptTail.window + 1000, fileID: 1)
        check(start.from == 1000, "starts a window from the end: \(start.from)")
        let lines = tail.consume(Data("cut off\nwhole\n".utf8))
        check(lines == ["whole"], "the line the window cut is dropped: \(lines)")
    }),

    ("a file on disk is read incrementally", {
        let url = try temporaryFile("one\ntwo\n")
        var tail = TranscriptTail()
        check(tail.read(url)?.lines == ["one", "two"], "first read")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("thr".utf8))
        try handle.close()
        check(tail.read(url)?.lines == [], "a partial line waits")
        let more = try FileHandle(forWritingTo: url)
        try more.seekToEnd()
        try more.write(contentsOf: Data("ee\n".utf8))
        try more.close()
        check(tail.read(url)?.lines == ["three"], "the line completes on the next read")
        try Data("x\n".utf8).write(to: url)
        let rotated = tail.read(url)
        check(rotated?.restarted == true && rotated?.lines == ["x"], "a rewritten file is read from the top: \(String(describing: rotated))")
        check(TailMissing.read() == nil, "a missing file gives nothing")
    }),

    ("a sent message is dropped once its transcript line arrives, and only from later lines", {
        let sent = PendingMessage(text: "run the tests", baseline: 2)
        let old = [TranscriptEntry(id: "1", kind: .user, text: "run the tests")]
        check(SessionTranscript.reconcile([sent], with: old + [assistantEntry("ok")]) == [sent], "an earlier identical line does not match")
        let written = old + [assistantEntry("a"), TranscriptEntry(id: "3", kind: .user, text: "run the tests")]
        check(SessionTranscript.reconcile([sent], with: written).isEmpty, "the new line reconciles it")
        let answer = [TranscriptEntry(id: "4", kind: .assistant, text: "run the tests")]
        check(SessionTranscript.reconcile([PendingMessage(text: "run the tests", baseline: 0)], with: answer).count == 1,
              "Claude's own words do not reconcile a sent message")
    }),

    ("a session that has ended is ended, one that is not running is done", {
        check(SessionStatus.derive(running: false, ended: true, lastOutput: nil, now: now, lastEntry: nil, screen: "") == .ended, "ended")
        check(SessionStatus.derive(running: false, ended: false, lastOutput: nil, now: now, lastEntry: nil, screen: "") == .done, "saved is done")
        check(SessionStatus.derive(running: true, ended: true, lastOutput: now, now: now, lastEntry: nil, screen: "") == .ended, "ended wins")
    }),

    ("a running session is working while it writes, waiting when it asks, and done otherwise", {
        let writing = SessionStatus.derive(running: true, ended: false, lastOutput: now.addingTimeInterval(-1), now: now,
                                           lastEntry: assistantEntry("Shall I go on?"), screen: "")
        check(writing == .working, "output in the last seconds is working even after a question")
        let asking = SessionStatus.derive(running: true, ended: false, lastOutput: now.addingTimeInterval(-30), now: now,
                                          lastEntry: assistantEntry("Shall I go on?"), screen: "")
        check(asking == .waiting, "a question and quiet is waiting")
        let finished = SessionStatus.derive(running: true, ended: false, lastOutput: now.addingTimeInterval(-30), now: now,
                                            lastEntry: assistantEntry("Done. The tests pass."), screen: "")
        check(finished == .done, "a finished turn is done")
        let tool = SessionStatus.derive(running: true, ended: false, lastOutput: now.addingTimeInterval(-30), now: now,
                                        lastEntry: TranscriptEntry(id: "t", kind: .tool(name: "Bash"), text: "ls"), screen: "")
        check(tool == .done, "a tool as the last line is not a question")
        let prompt = SessionStatus.derive(running: true, ended: false, lastOutput: now.addingTimeInterval(-30), now: now, lastEntry: nil,
                                          screen: "Bash command\n  rm -rf build\nDo you want to proceed?\n\u{276F} 1. Yes\n  2. No")
        check(prompt == .waiting, "a permission prompt on the screen is waiting")
    }),

    ("the waiting question is detected and quoted verbatim", {
        check(WaitingPrompt.isQuestion("Shall I continue?"), "a question")
        check(WaitingPrompt.isQuestion("Shall I continue? **"), "a bold question")
        check(WaitingPrompt.isQuestion("Overwrite the file (y/n)"), "a y/n question")
        check(!WaitingPrompt.isQuestion("Done."), "a statement is not")
        check(!WaitingPrompt.isQuestion("   "), "blank is not")
        check(WaitingPrompt.question(lastEntry: assistantEntry("I checked it.\nShall I merge the branch?"), screen: "")
              == "Shall I merge the branch?", "the last line is quoted")
        check(WaitingPrompt.question(lastEntry: assistantEntry("Done."), screen: "") == nil, "no question, no waiting")
        check(WaitingPrompt.question(lastEntry: nil, screen: "Would you like to make this edit?") == "Would you like to make this edit?",
              "the screen's prompt is quoted")
    }),

    ("rows group into running, waiting, saved and done, newest first", {
        let rows = [row("a", app12, state: .done, updated: 10),
                    row("b", api7, state: .waiting, updated: 5),
                    row("c", "https://github.com/acme/web/pull/1", kind: .saved, state: .done, updated: 20),
                    row("d", "https://github.com/acme/old/pull/3", state: .ended, updated: 1),
                    row("e", "https://github.com/acme/app/pull/9", state: .working, updated: 30),
                    row("f", "review:https://github.com/acme/app/pull/12", kind: .review, state: .done, updated: 40)]
        let groups = SessionList.grouped(rows)
        check(groups.map(\.group) == [.running, .waiting, .saved, .done], "group order \(groups.map(\.group))")
        check(groups[0].rows.map(\.id) == ["e", "a"], "running newest first")
        check(groups[3].rows.map(\.id) == ["f", "d"], "done holds reviews and ended sessions")
        check(SessionList.grouped([]).isEmpty, "no rows, no groups")
    }),

    ("saved sessions give way to a terminal of the same pull request", {
        let live = row("live", app12, state: .working)
        let saved = [row(app12, app12, kind: .saved), row(api7, api7, kind: .saved)]
        let merged = SessionList.merged(terminals: [live], saved: saved)
        check(merged.map(\.id) == ["live", api7], "one row per pull request: \(merged.map(\.id))")
    }),

    ("search matches title, pull request, address and state, every word", {
        let rows = [row("a", app12, state: .waiting, title: "Review fix"), row("b", api7, title: "Summary")]
        check(SessionList.matching(rows, query: "").count == 2, "empty query shows all")
        check(SessionList.matching(rows, query: "ACME/APP #12").map(\.id) == ["a"], "the pull request label, any case")
        check(SessionList.matching(rows, query: "waiting for").map(\.id) == ["a"], "the state title")
        check(SessionList.matching(rows, query: "summary api").map(\.id) == ["b"], "title and pull request together")
        check(SessionList.matching(rows, query: "summary app").isEmpty, "every word must match")
        check(SessionList.matching(rows, query: "No PR").isEmpty, "no pull request label does not match a PR")
    }),

    ("the PR chip opens the GitHub viewer on that pull request", {
        let target = SessionList.pullRequest(app12)
        check(target == GitHubLink.Target(repo: "acme/app", number: 12), "the chip's target: \(String(describing: target))")
        check(SessionList.pullRequest("https://example.com/acme/app/pull/12") == nil, "other hosts are not opened")
        check(SessionList.pullRequest("https://github.com/acme/app/issues/12") == nil, "issues are not pull requests")
        check(EmbeddedTerminal.pullRequestLabel(app12) == "acme/app #12", "the chip's label")
    }),

    ("sessions for a pull request are its own rows, the review run included", {
        let rows = [row("a", app12), row(SessionRow.reviewID(app12), app12, kind: .review), row("b", api7)]
        check(SessionList.sessions(for: app12, in: rows).map(\.id) == ["a", SessionRow.reviewID(app12)], "both of its rows")
        check(SessionList.sessions(for: "https://github.com/acme/none/pull/1", in: rows).isEmpty, "none for another pull request")
    }),

    ("the text sent is the text and a Return, an empty send is never sent", {
        check(SessionInput.submission("") == nil, "empty is not sent")
        check(SessionInput.submission(" \n\t ") == nil, "blank is not sent")
        check(SessionInput.submission("  run the tests  ") == "run the tests\r", "trimmed, then Return")
        check(SessionInput.submission("first\nsecond") == "\u{1B}[200~first\nsecond\u{1B}[201~\r", "several lines as one paste, then Return")
        check(SessionInput.answer(yes: true) == "y" && SessionInput.answer(yes: false) == "n", "the Yes and No answers")
        check(SessionInput.submission(SessionInput.answer(yes: true)) == "y\r", "an answer is sent with its Return")
    }),

    ("the pty write happens only in the send function", {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MeetingRecorder", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var writes: [(file: String, line: Int, text: String)] = []
        for file in files where file.pathExtension == "swift" {
            let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            for (index, text) in lines.enumerated() where text.contains("send(data:") || text.contains("send(txt:") {
                writes.append((file.lastPathComponent, index, text))
            }
        }
        check(writes.count == 1, "exactly one pty write in the sources: \(writes)")
        guard let write = writes.first else { return }
        check(write.file == "EmbeddedTerminalModel.swift", "the write lives in the terminal model: \(write.file)")
        let source = ((try? String(contentsOf: folder.appendingPathComponent(write.file), encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let submit = source.firstIndex { $0.contains("func submit(") } ?? -1
        check(submit >= 0 && write.line > submit && write.line - submit <= 6, "the write is inside func submit")
    }),
]

private enum TailMissing {
    static func read() -> (lines: [String], restarted: Bool)? {
        var tail = TranscriptTail()
        return tail.read(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl"))
    }
}
