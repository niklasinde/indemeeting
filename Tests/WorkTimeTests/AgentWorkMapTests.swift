import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let start = Date(timeIntervalSince1970: 1_792_300_000)
private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private func category(_ tool: String, _ input: [String: Any] = [:]) -> WorkMapCategory { WorkMap.category(tool: tool, input: input) }

private func use(_ id: String, _ tool: String, _ input: [String: Any] = [:]) -> [String: Any] {
    ["type": "tool_use", "id": id, "tool": tool, "input": input]
}

let agentWorkMapTests: [(name: String, run: () throws -> Void)] = [
    ("work map: file tools are Files, and Memory inside a memory folder or on an instructions file", {
        for tool in ["Read", "Edit", "Write", "NotebookEdit"] { check(category(tool, ["file_path": "/repo/Sources/App.swift"]) == .files, tool) }
        check(category("Glob", ["pattern": "**/*.swift"]) == .files, "glob")
        check(category("Grep", ["pattern": "TODO", "path": "/repo"]) == .files, "grep")
        check(category("Read", ["file_path": "/Users/me/.claude/projects/x/memory/notes.md"]) == .memory, "memory folder")
        check(category("Edit", ["file_path": "/repo/CLAUDE.md"]) == .memory, "CLAUDE.md")
        check(category("Read", ["file_path": "/data/work/MAIN.md"]) == .memory, "MAIN.md")
        check(category("Write", ["file_path": "/data/work/Assistants/reviewer.md"]) == .memory, "assistant file")
        check(category("Read", ["file_path": "/repo/docs/memory-model.md"]) == .files, "a file that only mentions memory")
    }),
    ("work map: Bash is Shell unless a command in it talks to the network", {
        check(category("Bash", ["command": "swift build"]) == .shell, "build")
        check(category("Bash", ["command": "git status && git log -3"]) == .shell, "local git")
        check(category("Bash", ["command": "git commit -m 'push the fix'"]) == .shell, "push in a message")
        check(category("Bash", ["command": "gh pr view 12 --json state"]) == .network, "gh")
        check(category("Bash", ["command": "curl -s https://example.com | jq ."]) == .network, "curl")
        check(category("Bash", ["command": "cd agent && npm install"]) == .network, "npm install")
        check(category("Bash", ["command": "npm test"]) == .shell, "npm test")
        check(category("Bash", ["command": "git -C /repo fetch -q"]) == .network, "git -C fetch")
        check(category("Bash", ["command": "GIT_TERMINAL_PROMPT=0 git push origin main"]) == .network, "env then git push")
        check(category("Bash", ["command": "/usr/bin/wget https://example.com/a.zip"]) == .network, "path to wget")
        check(category("Bash", ["command": "echo curl"]) == .shell, "curl as an argument")
    }),
    ("work map: web, MCP, browser, agent and skill tools", {
        check(category("WebFetch", ["url": "https://example.com"]) == .network, "web fetch")
        check(category("WebSearch", ["query": "swift canvas"]) == .network, "web search")
        check(category("mcp__worktime__jira_issue", ["key": "QDLY-1"]) == .network, "jira")
        check(category("mcp__plugin_engineering_slack__slack_read_thread") == .network, "slack")
        check(category("mcp__claude-in-chrome__navigate", ["url": "https://example.com"]) == .browser, "chrome")
        check(category("mcp__claude_in_chrome__read_page") == .browser, "chrome with underscores")
        check(category("mcp__playwright__browser_click") == .browser, "playwright")
        check(category("mcp__worktime__send_to_agent", ["agent": "Reviewer"]) == .agents, "send to agent")
        check(category("mcp__worktime__search_meetings", ["query": "release"]) == .memory, "stored meetings")
        check(category("Agent", ["prompt": "Look"]) == .agents && category("Task") == .agents, "sub-agents")
        check(category("Skill", ["skill": "review"]) == .skills, "skill")
    }),
    ("work map: the description is the call's own, else the tool and what it works on", {
        let described = WorkMap.description(tool: "Bash", input: ["command": "gh pr view 1", "description": " Check the release note "], cwd: "/repo")
        check(described == "Check the release note", described)
        check(WorkMap.description(tool: "Bash", input: ["command": "swift build\nswift test"], cwd: "/repo") == "swift build \u{2026}", "first line of the command")
        check(WorkMap.description(tool: "Read", input: ["file_path": "/repo/Sources/App.swift"], cwd: "/repo") == "Read Sources/App.swift", "relative file")
        let mcp = WorkMap.description(tool: "mcp__worktime__jira_issue", input: ["key": "QDLY-1"], cwd: "/repo")
        check(mcp == "WorkTime \u{00B7} Jira issue: QDLY-1", mcp)
        check(WorkMap.description(tool: "Skill", input: [:], cwd: "/repo") == "Skill", "nothing to add")
    }),
    ("work map: durations read as ms, seconds and minutes", {
        check(WorkMap.duration(0.673) == "673 ms", WorkMap.duration(0.673))
        check(WorkMap.duration(1.84) == "1.8 s", WorkMap.duration(1.84))
        check(WorkMap.duration(59.94) == "59.9 s", WorkMap.duration(59.94))
        check(WorkMap.duration(125) == "2 min 5 s", WorkMap.duration(125))
        check(WorkMap.duration(120) == "2 min", WorkMap.duration(120))
        check(WorkMap.duration(0.0001) == "1 ms", WorkMap.duration(0.0001))
    }),
    ("work map: a turn is a message, model steps and timed tool calls", {
        var map = WorkMap()
        map.prompt(model: "claude-opus-5-5", at: at(0))
        check(map.events.map(\.category) == [.you, .model] && map.active == .model && map.step == 1, "the model starts on the message")
        map.receive(use("a", "Bash", ["command": "gh pr list", "description": "List the open pull requests"]), cwd: "/repo", at: at(1.8))
        check(map.events[1].durationText == "1.8 s" && map.text(map.events[1]) == "opus 5.5 \u{00B7} step 1", map.text(map.events[1]))
        check(map.active == .network && map.events.last?.text == "List the open pull requests", "the call runs")
        map.receive(["type": "tool_result", "id": "a", "content": "", "isError": false], cwd: "/repo", at: at(2.473))
        check(map.events[2].durationText == "673 ms", map.events[2].durationText ?? "nil")
        check(map.active == .model && map.step == 2, "the next step starts on the result")
        map.receive(["type": "text", "text": "Done."], cwd: "/repo", at: at(4))
        map.receive(["type": "context", "tokens": 20_000, "max": 200_000, "percent": 10], cwd: "/repo", at: at(4))
        map.receive(["type": "idle"], cwd: "/repo", at: at(4.1))
        check(map.active == nil && map.events.count == 4, "nothing runs after the turn")
        check(map.counts == [.you: 1, .model: 2, .network: 1], "\(map.counts)")
        check(map.status == "Model: opus 5.5 \u{00B7} step 2 \u{00B7} context 10%", map.status)
    }),
    ("work map: parallel calls keep the model waiting until the last result", {
        var map = WorkMap()
        map.prompt(model: nil, at: at(0))
        map.receive(use("a", "Read", ["file_path": "/repo/a.swift"]), cwd: "/repo", at: at(1))
        map.receive(use("b", "Read", ["file_path": "/repo/b.swift"]), cwd: "/repo", at: at(1))
        map.receive(["type": "tool_result", "id": "a"], cwd: "/repo", at: at(2))
        check(map.step == 1 && map.active == .files, "one still runs")
        map.receive(["type": "tool_result", "id": "b"], cwd: "/repo", at: at(3))
        check(map.step == 2 && map.counts[.files] == 2, "both done")
        check(map.status == "Model: model \u{00B7} step 2", map.status)
    }),
    ("work map: a stopped turn drops the step that never answered and ends what ran", {
        var map = WorkMap()
        map.prompt(model: "claude-sonnet-5-5", at: at(0))
        map.receive(use("a", "Bash", ["command": "sleep 60"]), cwd: "/repo", at: at(1))
        map.finish(at: at(5))
        check(map.events.last?.durationText == "4.0 s" && map.active == nil, "the call ends with the turn")
        map.prompt(model: nil, at: at(10))
        map.finish(at: at(11))
        check(map.step == 1 && map.counts[.model] == 1 && map.events.last?.category == .you, "\(map.step) \(map.counts)")
    }),
    ("work map: hooks run from start to end, and context falls back to tokens", {
        var map = WorkMap()
        map.receive(["type": "hook", "id": "h", "name": "PostToolUse:Edit", "event": "PostToolUse", "phase": "started"], cwd: "/repo", at: at(0))
        check(map.active == .hooks && map.events.last?.text == "PostToolUse:Edit", "running hook")
        map.receive(["type": "hook", "id": "h", "phase": "ended"], cwd: "/repo", at: at(0.05))
        check(map.events.last?.durationText == "50 ms" && map.counts[.hooks] == 1, "hook ended")
        map.receive(["type": "context", "tokens": 48_200], cwd: "/repo", at: at(1))
        check(map.contextText == "48k" && map.contextPercent == nil, map.contextText ?? "nil")
    }),
    ("work map: a node is warm while it runs and fades after its last event", {
        var map = WorkMap()
        map.receive(use("a", "Bash", ["command": "ls"]), cwd: "/repo", at: at(0))
        check(map.warmth(.shell, at: at(100)) == 1, "running")
        map.receive(["type": "tool_result", "id": "a"], cwd: "/repo", at: at(2))
        check(abs(map.warmth(.shell, at: at(2 + WorkMap.fade / 2)) - 0.5) < 0.001, "half way")
        check(map.warmth(.shell, at: at(2 + WorkMap.fade)) == 0 && map.warmth(.files, at: at(3)) == 0, "faded, and never used")
    }),
    ("work map: the log keeps the newest events while the counts keep counting", {
        var map = WorkMap()
        for index in 0..<(WorkMap.limit + 20) {
            map.receive(use("\(index)", "Read", ["file_path": "/repo/\(index).swift"]), cwd: "/repo", at: at(Double(index)))
            map.receive(["type": "tool_result", "id": "\(index)"], cwd: "/repo", at: at(Double(index) + 0.5))
        }
        check(map.events.count == WorkMap.limit, "\(map.events.count)")
        check(map.counts[.files] == WorkMap.limit + 20, "\(map.counts)")
        check(map.events.last?.category == .model, "newest last")
    }),
]
