import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private let t0 = Date(timeIntervalSince1970: 1_792_300_000)

private func tempFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func line(_ event: String, _ id: String = "s1", at offset: TimeInterval = 0, extra: String = "") -> String {
    #"{"time":\#(Int(t0.timeIntervalSince1970 + offset)),"event":"\#(event)","session_id":"\#(id)","cwd":"/Users/me/git/repo","transcript_path":"/t/\#(id).jsonl"\#(extra)}"#
        + "\n"
}

private func event(_ kind: ClaudeHookEvent.Kind, _ id: String = "s1", at offset: TimeInterval) -> ClaudeHookEvent {
    ClaudeHookEvent(time: t0.addingTimeInterval(offset), kind: kind, sessionID: id, cwd: "/Users/me/git/repo")
}

private func append(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

private func json(_ text: String?) -> [String: Any] {
    (text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
}

private func call(_ server: MCPServer, _ tool: String, _ arguments: String = "{}", id: Int = 9) -> (text: String, isError: Bool) {
    let response = json(server.handle(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#))
    let result = response["result"] as? [String: Any] ?? [:]
    let content = result["content"] as? [[String: Any]] ?? []
    return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? true)
}

let pluginTests: [(name: String, run: () throws -> Void)] = [
    ("hook events parse from inbox lines and bad lines are skipped", {
        let events = ClaudeHookEvent.parse(Substring(line("UserPromptSubmit", extra: #","prompt_bytes":12,"prompt":"Fix it""#)
                                                     + "not json\n" + #"{"time":1,"event":"Bogus","session_id":"x"}"# + "\n"
                                                     + #"{"time":1,"event":"Stop","session_id":""}"# + "\n" + line("Stop", at: 5)))
        check(events.count == 2, "two events \(events)")
        check(events.first == ClaudeHookEvent(time: t0, kind: .prompt, sessionID: "s1", cwd: "/Users/me/git/repo",
                                               transcriptPath: "/t/s1.jsonl", prompt: "Fix it"), "prompt \(events)")
        check(events.last?.kind == .stop && events.last?.prompt == nil, "stop")
    }),

    ("the inbox reads whole lines once, survives truncation and rotates", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("claude-events.jsonl")
        var inbox = ClaudeInbox(url: url, rotateBytes: 300)
        check(inbox.read().isEmpty && ClaudeInbox.lastWrite(at: url) == nil, "no file yet")
        let first = line("SessionStart")
        try append(first + String(line("UserPromptSubmit").prefix(20)), to: url)
        check(inbox.read().map(\.kind) == [.sessionStart] && inbox.offset == UInt64(first.utf8.count), "partial line waits")
        try append(String(line("UserPromptSubmit").dropFirst(20)), to: url)
        check(inbox.read().map(\.kind) == [.prompt], "rest of the line")
        check(inbox.read().isEmpty, "nothing new")
        try Data(line("Stop").utf8).write(to: url)
        check(inbox.read().map(\.kind) == [.stop], "truncated file is read from the start")
        try append(line("PostToolUse") + line("PostToolUse") + line("Stop"), to: url)
        check(inbox.read().count == 3 && inbox.offset == 0, "past the limit it rotates")
        check(!FileManager.default.fileExists(atPath: url.path) && FileManager.default.fileExists(atPath: inbox.rotated.path), "moved aside")
        check(ClaudeInbox.lastWrite(at: url) != nil, "last write from the rotated file")
        try append(line("SessionEnd"), to: url)
        check(inbox.read().map(\.kind) == [.sessionEnd], "hooks start a new file")
    }),

    ("hook events drive working, waiting and ended sessions", {
        var sessions = ClaudeSessions()
        let lookback: TimeInterval = 120
        sessions.apply([event(.sessionStart, at: 0)])
        check(sessions.active(now: t0, lookback: lookback).isEmpty, "a started session is not working")
        sessions.apply([event(.prompt, at: 10), event(.tool, at: 40)])
        check(sessions.active(now: t0.addingTimeInterval(500), lookback: lookback).map(\.working) == [true], "working after a prompt")
        check(sessions.active(now: t0.addingTimeInterval(40 + 601), lookback: lookback).isEmpty, "quiet for ten minutes is not working")
        sessions.apply([event(.stop, at: 60)])
        let stopped = sessions.active(now: t0.addingTimeInterval(70), lookback: lookback)
        check(stopped.map(\.working) == [false] && stopped.first?.state.lastPrompt == t0.addingTimeInterval(10),
              "stopped but prompted lately, so it can still be the one typed into")
        check(sessions.active(now: t0.addingTimeInterval(200), lookback: lookback).isEmpty, "stopped and not prompted lately")
        sessions.apply([event(.prompt, at: 300), event(.notification, at: 320)])
        check(sessions.active(now: t0.addingTimeInterval(330), lookback: lookback).map(\.working) == [false], "waiting for the user")
        sessions.apply([event(.tool, at: 340), event(.prompt, "s2", at: 345)])
        check(sessions.active(now: t0.addingTimeInterval(350), lookback: lookback).map { "\($0.state.id) \($0.working)" } == ["s1 true", "s2 true"],
              "two sessions working")
        sessions.apply([event(.sessionEnd, at: 360)])
        check(sessions.active(now: t0.addingTimeInterval(361), lookback: lookback).map(\.state.id) == ["s2"], "ended session is gone")
        check(sessions.lastEvent == t0.addingTimeInterval(360) && sessions.ids == ["s1", "s2"], "last event")
        sessions.forget(before: t0.addingTimeInterval(350))
        check(sessions.ids == ["s1"], "old sessions are forgotten")
    }),

    ("the context summary splits Claude time into working and with you", {
        let claude = ClaudeSession(id: "s1", folder: "/Users/me/git/repo", title: "Plugin")
        var focused = ActivityBlock(id: 1, start: t0, end: t0.addingTimeInterval(600),
                                    key: ActivityKey(appName: "Terminal", claude: [claude], idle: false), projectID: nil)
        focused.key.claudeFocus = "s1"
        let background = ActivityBlock(id: 2, start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(1800),
                                       key: ActivityKey(appName: "Safari", claude: [claude], idle: false), projectID: nil)
        let markdown = ActivityLogic.contextMarkdown(blocks: [focused, background], meetings: [], range: t0..<t0.addingTimeInterval(3600))
        check(markdown.contains("## Claude sessions\n- Plugin (repo) \u{00B7} 30 min \u{00B7} with you 10 min\n"), markdown)
    }),

    ("the MCP server answers initialize, ping, tools/list and errors", {
        let server = MCPServer(tools: MCPServer.meetingTools(.failure(SQLiteError(message: "missing"))))
        let initialize = json(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        let result = initialize["result"] as? [String: Any] ?? [:]
        check(initialize["id"] as? Int == 1 && result["protocolVersion"] as? String == "2025-06-18", "negotiates \(initialize)")
        check((result["serverInfo"] as? [String: Any])?["name"] as? String == "meetingrecorder" && result["capabilities"] is [String: Any], "info")
        let unknown = json(server.handle(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        check((unknown["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersions[0] && unknown["id"] as? String == "a",
              "offers its latest version")
        check(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "notifications get no answer")
        check(json(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#))["result"] is [String: Any], "ping")
        let tools = (json(server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        check(tools.compactMap { $0["name"] as? String } == ["activity_context", "time_report", "search_meetings", "get_meeting", "recent_meetings"],
              "tools \(tools)")
        check(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" }, "schemas")
        check((json(server.handle(#"{"jsonrpc":"2.0","id":4,"method":"nope"}"#))["error"] as? [String: Any])?["code"] as? Int == -32601, "unknown method")
        check((json(server.handle("{oops"))["error"] as? [String: Any])?["code"] as? Int == -32700, "parse error")
        check((json(server.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"x"}}"#))["error"] as? [String: Any])?["code"] as? Int
              == -32602, "unknown tool")
        let failed = call(server, "recent_meetings")
        check(failed.isError && failed.text.contains("could not be opened"), "a missing database is a tool error \(failed)")
    }),

    ("the MCP tools read meetings and activity from a read-only database", {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meetings.sqlite")
        let writer = try MeetingStore.open(at: url)
        let name = "Meeting-2026-10-15-1430.m4a"
        try writer.saveTranscript(name, segments: [TranscriptSegment(start: 4, text: "Vi släpper releasen på tisdag.", speaker: .numbered(1)),
                                                   TranscriptSegment(start: 12, text: "Jag skickar rapporten.", speaker: .you)],
                                  language: .swedish, engine: "x")
        try writer.renameSpeaker(name, .numbered(1), to: "Anna")
        try writer.saveSummary(name, ParsedSummary(title: "Daglig standup",
                                                   actionItems: [ChecklistItem(key: "a", task: "Skicka rapporten", owner: "Niklas", done: false)],
                                                   sections: [SummarySection(heading: "Release", lines: [.bullet("Releasen är på tisdag.")])]))
        try writer.setTitleOverride("Meeting-2026-10-16-0900.m4a", "Planering")
        let now = Date()
        try writer.saveBlock(ActivityBlock(id: 0, start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(-600),
                                           key: ActivityKey(appName: "Xcode", repo: "indemeeting", branch: "main", claude: [], idle: false), projectID: nil))

        let store = try MeetingStore.openReadOnly(at: url)
        check((try? store.setNotes(name, "x")) == nil, "read-only store refuses writes")
        let server = MCPServer(tools: MCPServer.meetingTools(.success(store), now: { now }))
        let recent = call(server, "recent_meetings", #"{"limit":5}"#)
        check(!recent.isError && recent.text.hasPrefix("- id 2 \u{00B7} 2026-10-16") && recent.text.contains("Planering")
              && recent.text.contains("- id 1 \u{00B7} 2026-10-15") && recent.text.contains("Daglig standup"), recent.text)
        let found = call(server, "search_meetings", #"{"query":"releas"}"#)
        check(!found.isError && found.text.hasPrefix("- id 1 ") && found.text.contains("**"), found.text)
        check(call(server, "search_meetings", #"{"query":"zebra"}"#).text.contains("No meetings match"), "no match")
        check(call(server, "search_meetings").isError, "query required")
        let meeting = call(server, "get_meeting", #"{"id":1}"#)
        check(!meeting.isError && meeting.text.contains("# Daglig standup") && meeting.text.contains("- [ ] Niklas: Skicka rapporten")
              && meeting.text.contains("Anna: Vi släpper releasen på tisdag."), meeting.text)
        check(call(server, "get_meeting", #"{"id":1,"max_characters":1000}"#).text.count <= 1100, "cut")
        check(call(server, "get_meeting", #"{"id":99}"#).isError, "unknown meeting")
        let context = call(server, "activity_context", #"{"hours":1}"#)
        check(!context.isError && context.text.hasPrefix("# Activity") && context.text.contains("Active: 20 min")
              && context.text.contains("indemeeting (main)"), context.text)
        let week = call(server, "time_report", #"{"week_start":"\#(ActivityLogic.dateText(now))"}"#)
        check(!week.isError && week.text.hasPrefix("# Week ") && week.text.contains("Total: 20 min"), week.text)
        check(call(server, "time_report").text == week.text, "this week by default")
        check(call(server, "time_report", #"{"week_start":"last week"}"#).isError, "bad date")
    }),

    ("the claude CLI is found in PATH, then the installer's, Homebrew's and the Claude app's locations", {
        let home = try tempFolder().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        for version in ["2.1.9", "2.1.10"] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("\(version)/abc/claude.app/Contents/MacOS"), withIntermediateDirectories: true)
        }
        let versions = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
        let candidates = ClaudePlugin.cliCandidates(path: "/a/bin:/b:/a/bin", home: home, appVersions: versions)
            .map { $0.path.replacingOccurrences(of: "/private/var/", with: "/var/") }
        check(candidates == ["/a/bin/claude", "/b/claude", home.path + "/.claude/local/claude", home.path + "/.local/bin/claude",
                             "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                             app.path.replacingOccurrences(of: "/private/var/", with: "/var/") + "/2.1.10/abc/claude.app/Contents/MacOS/claude", app.path.replacingOccurrences(of: "/private/var/", with: "/var/") + "/2.1.9/abc/claude.app/Contents/MacOS/claude"],
              "order \(candidates)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try "#!/bin/sh\necho \"args: $*\"\n[ \"$2\" = uninstall ] && { echo nope >&2; exit 3; }\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        check(ClaudePlugin.findCLI(environment: ["PATH": "/nonexistent"], home: home)?.path == fake.path, "installer location")
        let installed = ClaudePluginModel.run(fake, ClaudePlugin.installArguments(source: "/repo"))
        check(installed == "$ claude plugin install meetingrecorder --marketplace /repo\nargs: plugin install meetingrecorder --marketplace /repo", installed)
        let removed = ClaudePluginModel.run(fake, ClaudePlugin.removeArguments)
        check(removed == "$ claude plugin uninstall meetingrecorder@indemeeting\nargs: plugin uninstall meetingrecorder@indemeeting\nnope\nFailed with exit code 3",
              "stops at the first failure \(removed)")
    }),

    ("the plugin's state comes from Claude Code's plugin files and the inbox", {
        let installed = Data(#"{"version":2,"plugins":{"github@claude-plugins-official":[{"scope":"user"}],"meetingrecorder@indemeeting":[{"scope":"user","version":"1.0.0"}]}}"#.utf8)
        check(ClaudePlugin.isInstalled(installedPlugins: installed), "listed")
        check(!ClaudePlugin.isInstalled(installedPlugins: Data(#"{"version":2,"plugins":{"meetingrecorder@indemeeting":[]}}"#.utf8)), "no installs")
        check(!ClaudePlugin.isInstalled(installedPlugins: nil) && !ClaudePlugin.isInstalled(installedPlugins: Data("x".utf8)), "missing file")
        let known = Data(#"{"indemeeting":{"source":{"source":"github","repo":"niklasinde/indemeeting"}},"local":{"source":{"source":"directory","path":"/x"}}}"#.utf8)
        check(ClaudePlugin.marketplaceSource(knownMarketplaces: known) == "niklasinde/indemeeting", "github source")
        check(ClaudePlugin.marketplaceSource(knownMarketplaces: Data(#"{"indemeeting":{"source":{"source":"directory","path":"/r"}}}"#.utf8)) == "/r", "folder")
        let now = t0.addingTimeInterval(3600)
        check(ClaudePlugin.statusText(ClaudePlugin.status(cli: nil, installed: false, lastEvent: nil), now: now) == "Claude CLI not found", "no cli")
        check(ClaudePlugin.statusText(ClaudePlugin.status(cli: URL(fileURLWithPath: "/c"), installed: false, lastEvent: t0), now: now) == "Not installed", "not installed")
        check(ClaudePlugin.statusText(ClaudePlugin.status(cli: nil, installed: true, lastEvent: nil), now: now) == "Installed", "installed")
        check(ClaudePlugin.statusText(.installed(lastEvent: now.addingTimeInterval(-120)), now: now) == "Installed \u{00B7} last event 2 min ago", "last event")
        let home = try tempFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appendingPathComponent("git/inde/indemeeting")
        check(ClaudePlugin.localCheckout(app: home.appendingPathComponent("Applications/MeetingRecorder.app"), home: home) == nil, "no checkout")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("plugin/.claude-plugin"), withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent(".claude-plugin/marketplace.json"))
        try Data().write(to: repo.appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        check(ClaudePlugin.localCheckout(app: home.appendingPathComponent("Applications/MeetingRecorder.app"), home: home)?.path == repo.standardizedFileURL.path,
              "checkout under ~/git")
        check(ClaudePlugin.localCheckout(app: repo.appendingPathComponent("MeetingRecorder.app"), home: home)?.path == repo.standardizedFileURL.path,
              "checkout next to the app")
    }),
]
