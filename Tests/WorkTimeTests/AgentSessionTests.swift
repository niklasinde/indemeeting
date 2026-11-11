import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_792_300_000)
private let first = "0b6f7c2e-1d2a-4c3b-9e8f-112233445566"
private let second = "1c7a8d3f-2e3b-4d4c-8f90-223344556677"

private func entry(_ id: String, title: String = "Prompt", minutesAgo: Double, model: String? = nil) -> AgentSessionEntry {
    AgentSessionEntry(id: id, folder: "/repo", created: now.addingTimeInterval(-minutesAgo * 60 - 60), lastUsed: now.addingTimeInterval(-minutesAgo * 60),
                      title: title, model: model)
}

let agentSessionTests: [(name: String, run: () throws -> Void)] = [
    ("agent sessions: titles are the first prompt line, with Catch up, reviews and Main's prompts named", {
        check(AgentSessions.title(prompt: AgentLogic.catchUpPrompt) == "Catch up", "catch up")
        let review = AgentLogic.reviewPrompt(url: "https://github.com/acme/api/pull/7", repo: "acme/api", hasCheckout: true)
        check(AgentSessions.title(prompt: review) == "Review acme/api#7", AgentSessions.title(prompt: review))
        check(AgentSessions.title(prompt: AgentInbox.prompt("Add the downgrade")) == "From Main: Add the downgrade", "from main")
        check(AgentSessions.title(prompt: "Fix the build\nand then the tests") == "Fix the build", "first line")
        let long = AgentSessions.title(prompt: String(repeating: "word ", count: 40))
        check(long.count <= AgentSessions.titleLimit && long.hasSuffix("\u{2026}"), long)
        check(AgentSessions.title(prompt: "  ") == AgentSessions.untitled, "blank")
    }),

    ("agent sessions: recording keeps the title and start, sorts newest first and caps the list", {
        var list = AgentSessions.record(entry(first, title: "Old", minutesAgo: 30), in: [])
        list = AgentSessions.record(entry(second, title: "New", minutesAgo: 5), in: list)
        check(list.map(\.id) == [second, first], "newest first")
        list = AgentSessions.record(entry(first, title: "Renamed", minutesAgo: 1, model: "claude-opus-5-5"), in: list)
        check(list.map(\.id) == [first, second], "used again moves up")
        check(list[0].title == "Old" && list[0].created == now.addingTimeInterval(-30 * 60 - 60), "keeps title and start")
        check(list[0].model == "claude-opus-5-5", "takes the newer model")
        var untitled = AgentSessions.record(entry(first, title: AgentSessions.untitled, minutesAgo: 9), in: [])
        untitled = AgentSessions.record(entry(first, title: "Found later", minutesAgo: 9), in: untitled)
        check(untitled[0].title == "Found later", "an untitled entry takes a title")
        let many = (0..<40).reduce([AgentSessionEntry]()) { list, index in
            AgentSessions.record(entry(UUID().uuidString, minutesAgo: Double(index)), in: list)
        }
        check(many.count == AgentSessions.limit && many.first?.lastUsed == now, "capped, newest kept")
    }),

    ("agent sessions: touching updates the time and model, removing drops only that entry", {
        let list = [entry(first, minutesAgo: 30, model: "claude-haiku-4-5"), entry(second, minutesAgo: 10)]
        let touched = AgentSessions.touch(first, at: now, model: nil, in: list)
        check(touched.map(\.id) == [first, second] && touched[0].lastUsed == now && touched[0].model == "claude-haiku-4-5", "\(touched)")
        check(AgentSessions.touch("missing", at: now, model: nil, in: list) == list, "unknown id")
        check(AgentSessions.removing(first, from: list).map(\.id) == [second], "removed")
    }),

    ("agent sessions: the history survives encoding, and garbage reads as empty", {
        let history = ["main": [entry(first, minutesAgo: 3)], "https://github.com/acme/api/pull/7": [entry(second, minutesAgo: 8)]]
        check(AgentSessions.decode(AgentSessions.encode(history)) == history, "round trip")
        check(AgentSessions.decode(Data("nope".utf8)).isEmpty && AgentSessions.decode(nil).isEmpty, "garbage")
        check(AgentSessions.lastUsed(history)["main"] == now.addingTimeInterval(-180), "last used per agent")
        check(AgentSessions.shortReference("https://github.com/acme/api/pull/7") == "api#7", "short reference")
        check(AgentSessions.key(prURL: nil, isMain: true, folder: "/x") == AgentOverview.mainKey, "main")
        check(AgentSessions.key(prURL: "https://github.com/acme/api/pull/7", isMain: false, folder: "/x") == "https://github.com/acme/api/pull/7", "pr")
    }),

    ("agent sessions: other transcripts in the folder leave out known and non-session files", {
        let files = [(id: first, modified: now.addingTimeInterval(-60)), (id: second, modified: now), (id: "notes", modified: now)]
        check(AgentSessions.others(files, excluding: []).map(\.id) == [second, first], "newest first, only session ids")
        check(AgentSessions.others(files, excluding: [second]).map(\.id) == [first], "known left out")
    }),

    ("agent sessions: a Claude Code transcript becomes the Agent's prompts, replies and tool rows with results", {
        let items = AgentTranscript.items(jsonl: transcriptFixture, cwd: "/repo")
        check(items.count == 3, "\(items)")
        check(items[0].kind == .user("Review https://github.com/acme/api/pull/7"), "prompt")
        if case .tool(let name, let summary, _, let result, let isError, _) = items[1].kind {
            check(items[1].id == "tool-t1" && name == "Read" && summary == "Sources/App.swift" && result == "let body = 1" && !isError, "\(items[1])")
        } else {
            check(false, "\(items[1])")
        }
        check(items[2].kind == .text("Looks good, one nit in App.swift:3."), "answer")
        let failed = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"make"}}]}}"#
            + "\n" + #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","is_error":true,"content":[{"type":"text","text":"boom"}]}]}}"#
        check(AgentTranscript.items(jsonl: failed, cwd: "/repo").first?.kind == .tool(name: "Bash", summary: "make", detail: "make", result: "boom",
                                                                                    isError: true, auto: false), "error result from blocks")
        check(AgentTranscript.items(jsonl: "", cwd: "/repo").isEmpty, "empty")
    }),

    ("agent sessions: a long restored transcript keeps its last items under a note, numbered so new ones cannot clash", {
        let items = (0..<250).map { AgentItem(id: $0 % 2 == 0 ? "user-\($0)" : "tool-x\($0)", kind: $0 % 2 == 0 ? .user("p\($0)") : .text("t")) }
        let kept = AgentSessions.restored(items, limit: 200)
        check(kept.count == 201 && kept[0].kind == .status("50 earlier items of this session not shown"), "\(kept.first!)")
        check(kept[1].id == "user-1" && kept[1].kind == .user("p50") && kept[2].id == "tool-x51", "\(kept[1].id) \(kept[2].id)")
        check(Set(kept.map(\.id)).count == kept.count, "unique ids")
        check(AgentSessions.restored(Array(items.prefix(3))) == Array(items.prefix(3)), "short ones unchanged")
    }),

    ("agent sessions: the Main page lists Main first, then who needs you, then the newest", {
        func state(_ key: String, _ status: AgentState.Status, minutesAgo: Double?, loaded: Bool = true) -> AgentState {
            AgentState(key: key, title: key, status: status, updatedAt: minutesAgo.map { now.addingTimeInterval(-$0 * 60) }, loaded: loaded)
        }
        let rows = AgentSessions.sidebar([state("main", .idle, minutesAgo: 90), state("a", .idle, minutesAgo: 1), state("b", .waiting, minutesAgo: 60),
                                          state("c", .idle, minutesAgo: nil, loaded: false)],
                                         lastUsed: ["c": now.addingTimeInterval(-30)])
        check(rows.map(\.key) == ["main", "b", "c", "a"], "\(rows.map(\.key))")
        check(rows[2].updatedAt == now.addingTimeInterval(-30), "saved session time from its history")
        let known = AgentOverview.withPersisted([], sessions: [:], known: ["main", "https://github.com/acme/api/pull/7"])
        check(known.map(\.key) == ["https://github.com/acme/api/pull/7"] && known[0].sessionID == nil, "history-only pull requests listed")
    }),
]
