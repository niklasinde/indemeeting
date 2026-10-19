import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func withStore(_ body: (MeetingStore) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite")))
}

private let audio = "Meeting-2026-10-16-1002.m4a"
private let now = Date(timeIntervalSince1970: 1_792_300_000)

private func message(_ role: ChatRole, _ text: String, note: String? = nil) -> ChatMessage {
    ChatMessage(id: 0, role: role, text: text, toolNote: note, created: now)
}

private func seeded(_ store: MeetingStore) throws -> Int64 {
    let segments = [TranscriptSegment(start: 4, text: "Vi har sex öppna tickets.", speaker: .numbered(1)),
                    TranscriptSegment(start: 75, text: "Releasen är på tisdag.", speaker: .you),
                    TranscriptSegment(start: 700, text: "Testdata saknas fortfarande.", speaker: .numbered(1))]
    try store.saveTranscript(audio, segments: segments, language: .swedish, engine: "x",
                             speakers: [SpeakerProfile(speaker: .numbered(1), name: "Elin")])
    try store.saveSummary(audio, ParsedSummary(title: "Daglig standup",
                                               actionItems: [ChecklistItem(key: "", task: "Skicka rapporten", owner: "Anna", done: false)],
                                               sections: [SummarySection(heading: "Release", lines: [.bullet("Tisdag.")])]))
    try store.setNotes(audio, "Fråga Johan om kreditfakturor.")
    return try store.meetings()[0].id
}

private func run(_ tool: String, _ arguments: [String: Any], scope: ChatScope, store: MeetingStore) throws -> String {
    let tools = ChatToolbox.tools(for: scope, store: store, budget: ChatBudget(contextSize: 4096), now: { now })
    guard let found = tools.first(where: { $0.name == tool }) else { throw MCPToolError("no tool \(tool)") }
    return try found.run(arguments)
}

let chatTests: [(name: String, run: () throws -> Void)] = [
    ("a title falls back to the first words of the question, cut at a word", {
        check(ChatLogic.fallbackTitle("  Vad bestämdes   på standupen? ") == "Vad bestämdes på standupen?", "short stays")
        let long = ChatLogic.fallbackTitle("What did we decide about the release of the new invoicing flow in the last standup meeting")
        check(long == "What did we decide about the release of\u{2026}", long)
        check(ChatLogic.fallbackTitle("   ") == "New chat", "empty")
        check(ChatLogic.fallbackTitle(String(repeating: "x", count: 80)).count == 41, "one long word is cut hard")
    }),

    ("a title from the model loses quotes, breaks and the full stop", {
        check(ChatLogic.cleanTitle("\"Release plan\".\nMore text") == "Release plan", "quotes and line")
        check(ChatLogic.cleanTitle("**Standup**") == "Standup", "markdown")
        check(ChatLogic.cleanTitle("ok") == nil, "too short")
        check(ChatLogic.cleanTitle("") == nil, "empty")
        check(ChatLogic.cleanTitle(String(repeating: "a", count: 90))?.count == 61, "capped")
    }),

    ("the recap keeps the newest turns that fit and skips lookups", {
        let messages = [message(.user, "first question"), message(.tool, "", note: "Searched"), message(.assistant, "first answer"),
                        message(.user, "second question"), message(.assistant, String(repeating: "y", count: 1000))]
        let all = ChatLogic.recap(messages, maxCharacters: 5000)!
        check(all.hasPrefix("User: first question\nAssistant: first answer\nUser: second question\nAssistant: yyy"), all)
        check(all.hasSuffix("\u{2026}") && all.count < 700, "long messages are cut, \(all.count)")
        let tight = ChatLogic.recap(messages, maxCharacters: 440)!
        check(!tight.contains("first") && tight.hasPrefix("User: second question\nAssistant: yyy"), "the oldest turns go first: \(tight.prefix(60))")
        check(ChatLogic.recap([message(.tool, "", note: "x")], maxCharacters: 100) == nil, "nothing to recap")
        check(ChatLogic.recap(messages, maxCharacters: 5) == nil, "nothing fits")
    }),

    ("a long text is cut at a line break and marked", {
        let text = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let cut = ChatLogic.trim(text, maxCharacters: 100)
        check(cut.hasSuffix("\n[Cut]") && cut.count <= 106, cut)
        check(!cut.dropLast(6).hasSuffix("lin"), "no half line")
        check(ChatLogic.trim("short", maxCharacters: 100) == "short", "short stays")
    }),

    ("the context budget scales with the window but stays small", {
        let small = ChatBudget(contextSize: 4096), large = ChatBudget(contextSize: 8192)
        check(small.toolOutput == 4500 && small.overview == 2703 && small.recap == 2000, "4096 window: \(small)")
        check(large.toolOutput == 4500 && large.overview == 3000 && large.recap == 2000, "8192 window is capped")
        check(ChatBudget(contextSize: 0).contextSize == 4096, "unknown size falls back")
        check(small.chunk >= 1500, "chunks")
    }),

    ("times become links that seek and other numbers do not", {
        check(ChatLogic.seconds(from: "12:41") == 761 && ChatLogic.seconds(from: "1:02:03") == 3723, "parse")
        check(ChatLogic.seconds(from: "[00:00:07]") == 7 && ChatLogic.seconds(from: "90") == 90, "brackets and seconds")
        check(ChatLogic.seconds(from: "a:b") == nil && ChatLogic.seconds(from: "1:2:3:4") == nil, "rejects")
        let linked = ChatLogic.linkifiedTimestamps("Elin (12:41) and Du (1:02:03); not 2026-10-16 or 10:2 or v1.2:3x")
        check(linked.contains("[12:41](meetingrecorder-seek://761)") && linked.contains("[1:02:03](meetingrecorder-seek://3723)"), linked)
        check(linked.contains("2026-10-16 or 10:2"), "dates are left alone: \(linked)")
        check(ChatLogic.linkifiedTimestamps("Said at 2:26: yes").contains("[2:26](meetingrecorder-seek://146): yes"), "a colon after the time is fine")
        check(ChatLogic.seekTarget(URL(string: "meetingrecorder-seek://761")!) == 761, "seek target")
        check(ChatLogic.meetingTarget(URL(string: "meetingrecorder-meeting://7")!) == 7, "meeting target")
        check(ChatLogic.seekTarget(URL(string: "https://x.se")!) == nil, "other links")
    }),

    ("a lookup is noted with what it searched and the meetings it found", {
        let output = "- id 7 \u{00B7} 2026-10-16 10:02 \u{00B7} Daglig standup \u{00B7} 33 min\n  snippet\n- id 3 \u{00B7} 2026-10-15 \u{00B7} Planering \u{00B7} 5 min\n"
        let note = ChatLogic.note(tool: "search_meetings", arguments: ["query": "release"], output: output)
        check(ChatLogic.noteSummary(note) == "Searched meetings for \u{201C}release\u{201D}", note)
        check(ChatLogic.noteDetails(note).count == 2 && ChatLogic.meetingIDs(inNote: note) == [7, 3], "details \(note)")
        let read = ChatLogic.note(tool: "get_meeting", arguments: ["id": 7], output: output + "[00:00:01] transcript line")
        check(ChatLogic.noteSummary(read) == "Read \u{201C}Daglig standup\u{201D}" && ChatLogic.noteDetails(read).count == 1, read)
        let inMeeting = ChatLogic.note(tool: "search_in_meeting", arguments: ["query": "tickets"], output: "[0:04] Elin: Vi har tickets\n[1:15] Du: ok\n")
        check(ChatLogic.noteDetails(inMeeting) == ["[0:04] Elin: Vi har tickets", "[1:15] Du: ok"], "lines of the meeting")
        check(ChatLogic.noteSummary(ChatLogic.note(tool: "activity_on", arguments: [:], output: "")) == "Looked at the activity on today", "default day")
        check(ChatLogic.meetingIDs(inNote: "x") == [], "no ids")
    }),

    ("transcript lookups find the best lines and read a stretch of time", {
        let names: SpeakerNames = [.numbered(1): "Elin"]
        let segments = [TranscriptSegment(start: 4, text: "Vi har sex öppna tickets.", speaker: .numbered(1)),
                        TranscriptSegment(start: 75, text: "Releasen är på tisdag, tickets först.", speaker: .you),
                        TranscriptSegment(start: 700, text: "Testdata saknas.", speaker: .numbered(1))]
        let found = ChatLogic.search(segments, query: "tickets release", names: names, language: .swedish, maxCharacters: 1000)
        check(found == ["[1:15] Du: Releasen är på tisdag, tickets först.", "[0:04] Elin: Vi har sex öppna tickets."] || found.count == 2, "\(found)")
        check(found.first?.hasPrefix("[0:04]") == true, "in the order said: \(found)")
        check(ChatLogic.search(segments, query: "OPPNA", names: names, language: .swedish, maxCharacters: 1000).count == 1, "ignores case and accents")
        check(ChatLogic.search(segments, query: "zebra", names: names, language: .swedish, maxCharacters: 1000).isEmpty, "no match")
        check(ChatLogic.search(segments, query: "tickets", names: names, language: .swedish, limit: 8, maxCharacters: 30).count <= 1, "capped by size")
        let part = ChatLogic.excerpt(segments, from: 60, to: 800, names: names, language: .swedish, maxCharacters: 1000)
        check(part == "[1:15] Du: Releasen är på tisdag, tickets först.\n[11:40] Elin: Testdata saknas.", part)
    }),

    ("a question about a meeting brings its best transcript lines along, ignoring filler words", {
        try withStore { store in
            _ = try seeded(store)
            let content = try store.content(of: audio)!
            let found = ChatLogic.prefetch("Who said something about the release, and when?", content: content, maxCharacters: 1000)
            check(found?.lines == ["[1:15] Du: Releasen är på tisdag."], "\(String(describing: found?.lines))")
            check(found.map { ChatLogic.noteSummary($0.note).hasPrefix("Searched this meeting for") } == true, "noted as a lookup")
            check(ChatLogic.prefetch("Vem sa något om zebror?", content: content, maxCharacters: 1000) == nil, "nothing to bring")
            check(ChatLogic.prefetch("Vad sades om tickets?", content: content, maxCharacters: 1000)?.lines.count == 1, "swedish filler is ignored")
        }
    }),

    ("chats are grouped under their meeting, newest first", {
        func chat(_ id: Int64, _ age: TimeInterval, _ scope: ChatScope) -> Chat {
            Chat(id: id, title: "c\(id)", created: now, updated: now.addingTimeInterval(-age), scope: scope)
        }
        let groups = ChatLogic.groups([chat(1, 50, .general), chat(2, 10, .meeting(7, label: "old label")), chat(3, 30, .notes(7, label: nil)),
                                       chat(4, 20, .day(containing: now)), chat(5, 5, .meeting(9, label: "Gone"))],
                                      meetingTitles: [7: "Standup"])
        check(groups.map(\.title) == ["Gone", "Standup", "Activity", "General"], "\(groups.map(\.title))")
        check(groups[1].chats.map(\.id) == [2, 3], "notes chats join the meeting")
    }),

    ("answers are split into headings, bullets, numbers and paragraphs", {
        let blocks = ChatLogic.blocks("## Beslut\nIntro rad\nfortsättning\n\n- **Ett**\n  - nested\n* två\n1. första\n2) andra\n1.5 miljoner\n#nospace")
        check(blocks == [.heading("Beslut"), .paragraph("Intro rad\nfortsättning"), .bullet(level: 0, text: "**Ett**"),
                         .bullet(level: 1, text: "nested"), .bullet(level: 0, text: "två"), .numbered("1", text: "första"),
                         .numbered("2", text: "andra"), .paragraph("1.5 miljoner\n#nospace")], "\(blocks)")
    }),

    ("the instructions say what the chat is about and require tool results", {
        let date = Date(timeIntervalSince1970: 1_792_300_000)
        let general = ChatLogic.instructions(scope: .general, overview: nil, recap: nil, now: date)
        check(general.contains("meetings_on") && general.contains("Never invent") && general.contains("language of the user"), "general")
        let meeting = ChatLogic.instructions(scope: .meeting(7, label: nil), overview: "Meeting X", recap: "User: hej", now: date)
        check(meeting.contains("search_in_meeting") && meeting.contains("scan_transcript") && meeting.contains("Overview:\nMeeting X"), "meeting")
        check(meeting.contains("so far") && meeting.hasSuffix("User: hej"), "recap last")
        check(!meeting.contains("12:41"), "no example time for the model to copy")
        check(ChatLogic.instructions(scope: .day(containing: date), overview: nil, recap: nil, now: date).contains("blocks_in_range"), "day")
    }),

    ("quick actions depend on the subject and ask for the meeting's language", {
        check(ChatLogic.suggestions(for: .general).map(\.label).first == "What did we decide in the last standup?", "general")
        let meeting = ChatLogic.suggestions(for: .meeting(1, label: nil), language: .swedish)
        check(meeting.map(\.label) == ["Action items for me", "Decisions", "Open questions", "Draft follow-up email"], "meeting")
        check(meeting.allSatisfy { $0.prompt.hasSuffix("Reply in Swedish.") }, "language")
        check(ChatLogic.suggestions(for: .notes(1, label: nil)).map(\.label) == ["Clean up", "Turn into action items"], "notes")
        check(ChatLogic.suggestions(for: .day(containing: now)).map(\.label).contains("Write a worklog entry"), "worklog")
        check(ChatLogic.suggestions(for: .general).count == 4, "four prompts")
    }),

    ("an unavailable model is explained for the chat, with the same settings link", {
        let off = ChatLogic.unavailableNotice(SummaryNotice(.appleIntelligenceOff))
        check(off.title == "Apple Intelligence is turned off" && off.message == "Turn it on in System Settings." && off.settings == .appleIntelligence, "\(off)")
        let downloading = ChatLogic.unavailableNotice(SummaryNotice(.modelNotReady))
        check(downloading.title == "Apple Intelligence is still downloading" && downloading.message.hasPrefix("Chat works by itself"), "\(downloading)")
    }),

    ("the command line reads the question and the scope", {
        check(ChatLogic.chatArguments(["app", "--chat", "hej", "--meeting", "7"]) == .init(question: "hej", meeting: 7, day: nil), "meeting")
        check(ChatLogic.chatArguments(["app", "--day", "2026-10-16", "--chat", "q"]) == .init(question: "q", meeting: nil, day: "2026-10-16"), "day")
        check(ChatLogic.chatArguments(["app", "--mcp"]) == nil, "not a chat")
    }),

    ("the scope chip names the subject", {
        check(ChatScope.meeting(1, label: "Old").chipTitle(meetingTitle: "Standup") == "Standup", "meeting")
        check(ChatScope.meeting(1, label: "Old").chipTitle() == "Old", "label when the meeting is not loaded")
        check(ChatScope.notes(1, label: nil).chipTitle(meetingTitle: "Standup") == "Notes \u{00B7} Standup", "notes")
        check(ChatScope.day(containing: now).chipTitle(now: now) == "Today", "today")
        check(ChatScope.week(containing: now).chipTitle().hasPrefix("Week "), "week")
        check(ChatScope.general.isGeneral && ChatScope.meeting(1, label: nil).meetingID == 1 && ChatScope.day(containing: now).meetingID == nil, "ids")
    }),

    ("chats and messages round-trip through the database", {
        try withStore { store in
            let scope = ChatScope.block(4, from: now, to: now.addingTimeInterval(600), label: "10:15 PyCharm")
            let chat = try store.createChat(title: "Standup", scope: scope, now: now)
            let general = try store.createChat(title: "Allmänt", scope: .general, now: now.addingTimeInterval(-100))
            try store.addMessage(chat: chat.id, role: .user, text: "Vad hände?", now: now)
            try store.addMessage(chat: chat.id, role: .tool, text: "", toolNote: "Searched\n- id 7", now: now)
            try store.addMessage(chat: chat.id, role: .assistant, text: "Svar", now: now.addingTimeInterval(5))
            let back = try store.chat(id: chat.id)!
            check(back.scope == scope && back.title == "Standup", "scope and title: \(back)")
            check(back.updated == now.addingTimeInterval(5) && back.created == now, "updated moves with messages")
            check(try store.chats().map(\.id) == [chat.id, general.id], "newest first")
            let messages = try store.messages(ofChat: chat.id)
            check(messages.map(\.role) == [.user, .tool, .assistant] && messages[1].toolNote == "Searched\n- id 7" && messages[1].text.isEmpty, "messages \(messages)")
            try store.renameChat(chat.id, to: "  Ny titel ")
            try store.renameChat(chat.id, to: "   ")
            check(try store.chat(id: chat.id)?.title == "Ny titel", "rename trims and refuses empty")
            try store.setScope(ofChat: chat.id, .general)
            check(try store.chat(id: chat.id)?.scope == .general, "scope removed")
            try store.deleteChat(chat.id)
            check(try store.messages(ofChat: chat.id).isEmpty && (try store.chat(id: chat.id)) == nil, "messages go with the chat")
            check(try store.deleteAllChats() == 1 && (try store.chats()).isEmpty, "delete all reports the count")
        }
    }),

    ("chats about a meeting are counted and deleted with it", {
        try withStore { store in
            let id = try seeded(store)
            _ = try store.createChat(title: "a", scope: .meeting(id, label: nil))
            _ = try store.createChat(title: "b", scope: .notes(id, label: nil))
            _ = try store.createChat(title: "c", scope: .general)
            check(try store.chatCount(meeting: id) == 2, "count")
            try store.delete(audio)
            check(try store.chats().map(\.title) == ["c"], "only the general chat is left")
        }
    }),

    ("the tools for a meeting search, read and return notes from that meeting only", {
        try withStore { store in
            let id = try seeded(store)
            let scope = ChatScope.meeting(id, label: nil)
            let search = try run("search_in_meeting", ["query": "tickets"], scope: scope, store: store)
            check(search == "[0:04] Elin: Vi har sex öppna tickets.\n", search)
            check(try run("search_in_meeting", ["query": "zebra"], scope: scope, store: store).hasPrefix("No transcript lines match"), "no match")
            let read = try run("read_transcript", ["from": "1:00", "to": "12:00"], scope: scope, store: store)
            check(read == "[1:15] Du: Releasen är på tisdag.\n[11:40] Elin: Testdata saknas fortfarande.\n", read)
            check(try run("read_transcript", ["from": "0:00"], scope: scope, store: store).hasSuffix("tisdag.\n"), "five minutes by default")
            check(try run("get_notes", [:], scope: scope, store: store) == "Fråga Johan om kreditfakturor.\n", "notes")
            let names = ChatToolbox.tools(for: scope, store: store, budget: ChatBudget(contextSize: 4096)).map(\.name)
            check(names == ["search_in_meeting", "read_transcript", "get_notes"], "\(names)")
            let overview = try ChatToolbox.overview(for: scope, store: store, budget: ChatBudget(contextSize: 4096))!
            check(overview.contains("Meeting \u{201C}Daglig standup\u{201D} (id \(id))") && overview.contains("Speakers: Elin, ")
                  && overview.contains("Anna: Skicka rapporten") && overview.contains("Release:\n- Tisdag.") && overview.contains("Fråga Johan"), overview)
            check(overview.count <= ChatBudget(contextSize: 4096).overview, "within budget")
        }
    }),

    ("the general tools list meetings by day and open action items", {
        try withStore { store in
            let id = try seeded(store)
            let scope = ChatScope.general
            let names = ChatToolbox.tools(for: scope, store: store, budget: ChatBudget(contextSize: 4096)).map(\.name)
            check(names == ["search_meetings", "get_meeting", "recent_meetings", "meetings_on", "open_action_items", "activity_on",
                            "activity_context", "time_report"], "\(names)")
            let day = try run("meetings_on", ["date": "2026-10-16"], scope: scope, store: store)
            check(day.contains("id \(id)") && day.contains("Daglig standup"), day)
            check(try run("meetings_on", ["date": "2026-01-01"], scope: scope, store: store) == "No meetings on 2026-01-01.\n", "empty day")
            let items = try run("open_action_items", [:], scope: scope, store: store)
            check(items.contains("Anna: Skicka rapporten") && items.contains("id \(id)"), items)
            let checked = try store.content(of: audio)!.summary.actionItems[0]
            try store.setChecked(actionItem: Int64(checked.key)!, true)
            check(try run("open_action_items", [:], scope: scope, store: store) == "No open action items.\n", "ticked off items are left out")
            let big = try run("get_meeting", ["id": Int(id)], scope: scope, store: store)
            check(big.count <= ChatBudget(contextSize: 4096).toolOutput + 10, "capped")
        }
    }),

    ("every tool result is cut to the budget", {
        try withStore { store in
            let id = try seeded(store)
            let long = (0..<400).map { TranscriptSegment(start: Double($0), text: "ord \($0) tickets och mer text här", speaker: .you) }
            try store.saveTranscript(audio, segments: long, language: .swedish, engine: "x")
            let read = try run("read_transcript", ["from": "0:00", "to": "10:00"], scope: .meeting(id, label: nil), store: store)
            check(read.count <= ChatBudget(contextSize: 4096).toolOutput + 10 && read.hasSuffix("[Cut]\n") || read.hasSuffix("[Cut]"), "cut \(read.count)")
        }
    }),
]
