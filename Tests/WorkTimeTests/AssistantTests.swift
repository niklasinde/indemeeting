import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let work = Workspaces.defaults[0], personal = Workspaces.defaults[1]
private let now = Date(timeIntervalSince1970: 1_792_300_000)

private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("assistants-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func role(_ name: String, slug: String? = nil, summary: String = "Does things.", body: String = "Be brief.") -> AssistantRole {
    AssistantRole(slug: slug ?? Assistants.slug(name), name: name, summary: summary, body: body)
}

private func entry(_ name: String, workspace: String = "work", problems: [AssistantProblem] = []) -> AssistantEntry {
    var made = role(name)
    made.problems = problems
    return AssistantEntry(workspace: workspace, role: made)
}

let assistantTests: [(name: String, run: () throws -> Void)] = [
    ("assistants: a role file is front matter and instructions, and serialising it and parsing it again gives the same role", {
        let made = AssistantRole(slug: "time-reporter", name: "Time reporter: weekly", icon: "clock", summary: "Drafts the week # one",
                                 model: "sonnet", permissionMode: "acceptEdits", tools: ["time_report", "jira_issue"], folder: "~/git/x",
                                 body: "# Time\n\nLine two: with \"quotes\".\n\n- a\n- b")
        let text = Assistants.serialise(made)
        check(text.hasPrefix("---\nname: \"Time reporter: weekly\"\n"), text)
        check(Assistants.parse(slug: "time-reporter", text: text) == made, "round trip: \(Assistants.parse(slug: "time-reporter", text: text))")
        let plain = role("Support")
        check(Assistants.parse(slug: "support", text: Assistants.serialise(plain)) == plain, "plain")
        let empty = AssistantRole(slug: "e", name: "E", summary: "x", body: "")
        check(Assistants.parse(slug: "e", text: Assistants.serialise(empty)) == empty, "no body")
        for template in Assistants.templates {
            let parsed = Assistants.parse(slug: template.slug, text: template.text)
            check(parsed.isUsable && parsed == template.role, "template \(template.slug): \(parsed.problems)")
        }
    }),
    ("assistants: front matter takes plain, quoted, inline and block values, comments and Windows line endings", {
        let text = "\u{FEFF}---\r\n# a comment\r\nname: 'Dev''s'\r\ndescription: Reviews code # trailing\r\nicon: hammer\r\nmodel: haiku\r\n"
            + "permissionMode: plan\r\ntools:\r\n  - jira_issue\r\n  - \"slack_thread\"\r\nfolder: own\r\n---\r\n\r\nBody here.\r\n"
        let parsed = Assistants.parse(slug: "dev", text: text)
        check(parsed.problems.isEmpty, "\(parsed.problems)")
        check(parsed.name == "Dev's" && parsed.summary == "Reviews code" && parsed.model == "haiku" && parsed.permissionMode == "plan", "\(parsed)")
        check(parsed.tools == ["jira_issue", "slack_thread"] && parsed.folder == "own" && parsed.body == "Body here.", "\(parsed)")
        let inline = Assistants.parse(slug: "x", text: "---\nname: X\ndescription: y\ntools: [a, b , \"c\"]\n---\nz")
        check(inline.tools == ["a", "b", "c"] && inline.model == "sonnet" && inline.permissionMode == "ask" && inline.icon == Assistants.defaultIcon, "\(inline)")
        check(Assistants.parse(slug: "x", text: "---\nname: X\ndescription: y\ntools: a, b, a\n---\n").tools == ["a", "b"], "listed once")
        let legacy = Assistants.parse(slug: "x", text: "---\nname: X\ndescription: y\nmodel: auto\n---\n")
        check(legacy.model == "sonnet" && legacy.problems.isEmpty, "a file written for Auto reads as Sonnet: \(legacy)")
    }),
    ("assistants: a malformed file never fails; it comes back with its problems and as much as could be read", {
        func problems(_ text: String?) -> [AssistantProblem] { Assistants.parse(slug: "bad", text: text).problems }
        check(problems(nil).first?.message.contains("could not be read") == true, "unreadable")
        check(problems("")[0].line == 1, "empty")
        check(problems("Just notes\nno front matter").first?.message.contains("front matter") == true, "no front matter")
        check(Assistants.parse(slug: "bad", text: "Just notes").body == "Just notes", "its text is kept")
        check(problems("---\nname: X\ndescription: y\nnever closed").first?.message.contains("not closed") == true, "not closed")
        check(problems("---\ndescription: y\n---\n").contains { $0.message == "name is required." }, "name required")
        check(problems("---\nname: X\n---\n").contains { $0.message.contains("description is required") }, "description required")
        let wrong = problems("---\nname: X\ndescription: y\nmodel: gpt\npermissionMode: yolo\nicon: Not A Symbol\ntools: [bad tool]\n---\n")
        check(wrong.compactMap(\.line).sorted() == [4, 5, 6, 7], "each on its own line: \(wrong)")
        let typo = problems("---\nname: X\ndescription: y\nmodle: opus\nname: Y\n---\n")
        check(typo.contains { $0.line == 4 && $0.message.contains("Unknown key") } && typo.contains { $0.line == 5 && $0.message.contains("twice") }, "\(typo)")
        check(problems("---\nname X\ndescription: y\n---\n").first?.line == 2, "not key: value")
        check(problems("---\nname: \"\"\ndescription: y\n---\n").first?.message.contains("1 to 60") == true, "empty name")
        check(problems("---\nname: X\ndescription: y\nfolder:\n---\n").first?.line == 4, "empty folder")
        let broken = Assistants.parse(slug: "my-file", text: "---\ndescription: y\n---\nBody")
        check(broken.name == "my-file" && !broken.isUsable && broken.body == "Body", "named after its file when it has no name")
        check(problems("\u{0}\u{1}binary \u{FFFD}").count == 1, "garbage")
    }),
    ("assistants: the list has every file, bad ones included, by name", {
        let good = Assistants.serialise(role("Zed")), other = Assistants.serialise(role("alpha"))
        let roles = Assistants.list([("zed", good), ("broken", "nope"), ("alpha", other), ("gone", nil)])
        check(roles.map(\.slug) == ["alpha", "broken", "gone", "zed"], "\(roles.map(\.slug))")
        check(roles.map(\.isUsable) == [true, false, false, true], "bad ones carry an error")
        check(Assistants.list([]).isEmpty, "none")
    }),
    ("assistants: the templates are written for each workspace on first use and never again, and edits are read fresh", {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = AssistantFiles(folder: folder, home: "/Users/me")
        check(files.url("work", slug: "developer").path.hasSuffix("/work/Assistants/developer.md"), files.url("work", slug: "developer").path)
        check(files.list("work").isEmpty, "nothing until used")
        files.ensureDefaults("work")
        files.ensureDefaults("personal")
        let names = files.list("work").map(\.name)
        check(names == ["Developer", "Meeting follow-up", "Reviewer", "Support", "Time reporter"], "\(names)")
        check(files.list("work").allSatisfy(\.isUsable) && files.list("personal").map(\.name) == names, "the same set in both")
        files.write(Assistants.serialise(role("Developer", body: "Personal developer rules.")), workspace: "personal", slug: "developer")
        check(files.role("personal", slug: "developer")?.body == "Personal developer rules." && files.role("work", slug: "developer")?.body != "Personal developer rules.",
              "each workspace has its own copy")
        files.remove("work", slug: "support")
        files.ensureDefaults("work")
        check(!files.list("work").contains { $0.slug == "support" }, "a deleted one stays deleted")
        files.reset("personal", slug: "developer")
        check(files.role("personal", slug: "developer") == Assistants.template("developer")?.role, "reset to the template")
        files.reset("work", slug: "custom")
        check(files.role("work", slug: "custom") == nil, "no template, no reset")
        try Data("notes".utf8).write(to: files.folder("work").appendingPathComponent("readme.txt"))
        try Data("x".utf8).write(to: files.folder("work").appendingPathComponent(".hidden.md"))
        check(files.slugs("work").sorted() == ["developer", "meeting-follow-up", "reviewer", "time-reporter"], "only visible .md files: \(files.slugs("work"))")
        let before = files.signature("work")
        files.write(Assistants.serialise(role("Another")), workspace: "work", slug: "another")
        check(files.signature("work") != before && files.signature("work") == files.signature("work"), "a new file changes the signature")
    }),
    ("assistants: new, duplicated and renamed assistants get names and files of their own", {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = AssistantFiles(folder: folder, home: "/Users/me")
        files.ensureDefaults("work")
        let copy = files.duplicate("work", slug: "developer")
        check(copy == "developer-copy" && files.role("work", slug: "developer-copy")?.name == "Developer copy", "duplicate: \(copy ?? "nil")")
        check(files.duplicate("work", slug: "developer") == "developer-copy-2" && files.role("work", slug: "developer-copy-2")?.name == "Developer copy 2", "again")
        check(files.duplicate("work", slug: "missing") == nil, "nothing to copy")
        let fresh = files.blank("work", name: "Release notes")
        let blank = files.role("work", slug: fresh)
        check(fresh == "release-notes" && blank?.isUsable == true && blank?.body.contains("Release notes") == true, "blank: \(String(describing: blank))")
        check(files.create("work", name: "Support", text: Assistants.template("support")!.text) == "support-2"
              && files.role("work", slug: "support-2")?.name == "Support 2", "a template again")
        files.rename("work", slug: "reviewer", to: "Code reviewer")
        check(files.role("work", slug: "reviewer")?.name == "Code reviewer" && files.role("work", slug: "reviewer")?.tools == Assistants.template("reviewer")?.role.tools,
              "rename keeps the file and the rest")
        files.rename("work", slug: "reviewer", to: "support")
        check(files.role("work", slug: "reviewer")?.name == "support 3", "never the name of another: \(files.role("work", slug: "reviewer")?.name ?? "")")
        check(Assistants.renamed("no front matter", to: "X") == "no front matter", "only front matter is edited")
        check(Assistants.renamed("---\ndescription: d\n---\nbody", to: "A: B") == "---\nname: \"A: B\"\ndescription: d\n---\nbody", "a missing name is added")
        check(Assistants.slug("!!!") == "assistant" && Assistants.slug("Time reporter") == "time-reporter", "slugs")
        check(Assistants.uniqueName("Dev", taken: ["dev", "Dev 2"]) == "Dev 3" && Assistants.uniqueName("Dev", taken: []) == "Dev", "unique names")
        files.remove("work", slug: "developer")
        check(files.role("work", slug: "developer") == nil && files.role("work", slug: "developer-copy") != nil, "delete removes only that file")
    }),
    ("assistants: a role works in the workspace's folder, its own, or the one it names", {
        let files = AssistantFiles(folder: URL(fileURLWithPath: "/data/Workspaces"), home: "/Users/me")
        check(files.workFolder(role("Dev"), workspace: work) == "/Users/me/git/quiddly", "workspace root")
        check(files.workFolder(role("Dev"), workspace: personal) == "/Users/me/git/inde", "the other workspace's")
        var own = role("Time reporter")
        own.folder = "own"
        check(files.workFolder(own, workspace: work) == "/data/Workspaces/work/Assistants/time-reporter", files.workFolder(own, workspace: work))
        own.folder = "~/notes/"
        check(files.workFolder(own, workspace: work) == "/Users/me/notes", "named")
    }),
    ("assistants: the prompt is the scope text, the role's instructions and then the workspace's MAIN.md", {
        let developer = Assistants.template("developer")!.role
        let scope = Assistants.scope(developer, workspace: work, folder: "/Users/me/git/quiddly")
        check(scope.contains("Developer assistant of the Work workspace") && scope.contains("From Main:") && scope.contains("/Users/me/git/quiddly")
              && scope.contains("never claim it did") && scope.contains("Your role instructions:") && scope.contains("CLAUDE.md"), scope)
        let composed = WorkspaceInstructions.compose(scope: scope, main: "Answer in Swedish.", extras: [])
        let order = ["Developer assistant", "tests", "Answer in Swedish."].compactMap { composed.range(of: $0)?.lowerBound }
        check(order.count == 3 && order == order.sorted(), "scope, role, MAIN.md")
        check(Assistants.scope(role("Empty", body: ""), workspace: personal, folder: "/x").contains("Your role instructions:") == false, "no body, no section")
        check(Assistants.scope(role("Long", body: String(repeating: "a", count: 30_000)), workspace: work, folder: "/x").count < 21_000, "cut")
    }),
    ("assistants: Main is told its usable assistants and when to delegate", {
        check(Assistants.roster([]) == nil, "none")
        check(Assistants.roster([entry("Broken", problems: [AssistantProblem(line: nil, message: "x")]).role]) == nil, "only a broken one")
        let text = Assistants.roster([role("Developer", summary: "Implements tickets."), role("Support", summary: "Works cases."),
                                      entry("Broken", problems: [AssistantProblem(line: nil, message: "x")]).role])!
        check(text.contains("- Developer: Implements tickets.") && text.contains("- Support: Works cases.") && !text.contains("Broken"), text)
        check(text.contains("send_to_agent") && text.contains("approves each message") && text.contains("clearly matches"), text)
    }),
    ("assistants: send_to_agent finds an assistant by role name, file name, key or with 'assistant' after it", {
        let entries = [entry("Developer"), entry("Time reporter"), entry("Developer", workspace: "personal"), entry("Broken", problems: [AssistantProblem(line: 2, message: "name is required.")])]
        func target(_ text: String, _ list: [AssistantEntry]? = nil) -> Result<AgentTarget, AssistantError>? { Assistants.resolve(text, in: list ?? entries) }
        let reporter = AgentTarget(key: "assistant:work:time-reporter", title: "Time reporter")
        check(target("time reporter") == .success(reporter), "by name")
        check(target("  Time Reporter assistant ") == .success(reporter), "ignoring case, spaces and 'assistant'")
        check(target("time-reporter") == .success(reporter), "by file name")
        check(target("assistant:work:time-reporter") == .success(reporter), "by key")
        check(target("ASSISTANT:WORK:TIME-REPORTER") == .success(reporter), "key in any case")
        check(target("developer") == .failure(.ambiguous("developer", ["Developer (work)", "Developer (personal)"])), "the same role in two workspaces")
        check(target("developer", Array(entries.filter { $0.workspace == "personal" })) == .success(AgentTarget(key: "assistant:personal:developer", title: "Developer")), "scoped to one")
        check(target("broken") == .failure(.broken("Broken", "Line 2: name is required.")), "a broken file cannot be delegated to")
        check(target("planner") == nil && target("") == nil && target("https://github.com/a/b/pull/1") == nil && target("topic:x") == nil, "anything else is left to the other agents")
        check(AssistantError.ambiguous("x", ["A", "B"]).message.contains("A, B") && AssistantError.broken("A", "p").message.contains("fixed"), "messages")
    }),
    ("assistants: keys name their workspace and file, and an assistant belongs to the workspace in its key", {
        let key = Assistants.key(workspace: "personal", slug: "my:dev")
        check(key == "assistant:personal:my:dev" && Assistants.parse(key: key)?.workspace == "personal" && Assistants.parse(key: key)?.slug == "my:dev", key)
        check(!Assistants.isKey("assistant:") && !Assistants.isKey("assistant:work") && !Assistants.isKey("assistant::x") && !Assistants.isKey("topic:1") && !Assistants.isKey("main:work"), "not keys")
        let file = WorkspaceFile(workspaces: Workspaces.defaults)
        var state = AgentState(key: "assistant:personal:developer", title: "Developer", folder: "/Users/me/git/quiddly", status: .idle)
        check(Workspaces.assigned(state, in: file, home: "/Users/me") == "personal", "by its key, not its folder")
        state.key = "assistant:gone:developer"
        check(Workspaces.assigned(state, in: file, home: "/Users/me") == "work", "a deleted workspace falls back to the default")
        check(AgentInbox.request(agent: "assistant:work:developer", text: "go", now: now).isSuccess, "the inbox takes assistant keys")
        check(!AgentInbox.request(agent: "assistant:", text: "go", now: now).isSuccess, "but not half of one")
    }),
    ("assistants: they are listed under their workspace's Main, by name, and count as needing the user", {
        func state(_ key: String, _ title: String, status: AgentState.Status = .idle) -> AgentState {
            var state = AgentState(key: key, title: title, status: status, loaded: false, workspace: nil)
            state.kind = key.hasPrefix("assistant:") ? "assistant" : nil
            return state
        }
        let states = [state("main:work", "Main"), state("assistant:work:support", "Support"), state("assistant:work:developer", "Developer", status: .waiting),
                      state("assistant:personal:developer", "Developer"), state("https://github.com/quiddly-com/finq.api/pull/7", "finq.api#7")]
        let groups = Workspaces.groups(states, file: WorkspaceFile(workspaces: Workspaces.defaults), lastUsed: [:], home: "/Users/me")
        check(groups[0].main?.key == "main:work" && groups[0].assistants.map(\.title) == ["Developer", "Support"], "\(groups[0].assistants.map(\.title))")
        check(groups[0].agents.map(\.title) == ["finq.api#7"] && groups[0].needing == 1, "assistants are not among the agents")
        check(groups[1].assistants.map(\.key) == ["assistant:personal:developer"] && groups[1].all.map(\.key).last == "assistant:personal:developer", "Personal's own")
        let line = AgentOverview.line(AgentState(key: "assistant:work:developer", title: "Developer", status: .idle, kind: "assistant", role: "Developer"), now: now)
        check(line.contains("assistant Developer") && line.contains("assistant:work:developer"), line)
        let json = AgentOverview.encode([AgentState(key: "assistant:work:developer", title: "Developer", status: .idle, workspace: "work", kind: "assistant", role: "Developer")], now: now)
        check(String(decoding: json, as: UTF8.self).contains("\"kind\" : \"assistant\"") && AgentOverview.decode(json)?.agents.first?.role == "Developer", "agents.json")
    }),
    ("assistants: the MCP tools delegate to the assistants of their own workspace only", {
        let folder = try scratch(), state = folder.appendingPathComponent("agents.json"), inbox = folder.appendingPathComponent("inbox")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = AssistantFiles(folder: folder.appendingPathComponent("Workspaces"), home: folder.path)
        files.ensureDefaults("work")
        files.ensureDefaults("personal")
        files.write("---\nname: Planner\n---\n", workspace: "work", slug: "planner")
        try AgentOverview.encode([AgentState(key: "assistant:work:developer", title: "Developer", status: .idle, workspace: "work", kind: "assistant", role: "Developer"),
                                  AgentState(key: "assistant:personal:developer", title: "Developer", status: .idle, workspace: "personal", kind: "assistant", role: "Developer")],
                                 now: now).write(to: state)
        func tools(_ environment: String?) -> [MCPTool] {
            var sources = MCPServer.AgentSources(stateFile: state, inbox: inbox, projects: folder, replyTimeout: 0.2, slack: { nil })
            sources.assistants = files
            sources.workspaces = MCPServer.WorkspaceSource(file: { WorkspaceFile(workspaces: Workspaces.defaults) }, environment: { environment })
            return MCPServer.agentTools(.failure(MCPToolError("no db")), sources: sources, now: { now })
        }
        func send(_ environment: String?, _ agent: String, _ args: [String: Any] = [:]) -> String {
            let result = Result { try tools(environment).first { $0.name == "send_to_agent" }!.run(["agent": agent, "text": "go"].merging(args) { $1 }) }
            if case .failure(let error) = result { return error.localizedDescription }
            return "OK"
        }
        check(send("work", "time reporter").contains("Is the app running?"), "found, so it reached the inbox: \(send("work", "time reporter"))")
        check(send("work", "developer").contains("Is the app running?"), "Work's own Developer")
        check(send("personal", "assistant:work:developer").contains("Work workspace") || send("personal", "assistant:work:developer").contains("No agent"), "another workspace's is refused: \(send("personal", "assistant:work:developer"))")
        check(send("personal", "developer", ["workspace": "work"]).contains("Is the app running?"), "named by the user")
        check(send("work", "planner").contains("cannot be used"), "a broken file: \(send("work", "planner"))")
        check(send("work", "nobody").contains("No agent matches"), "unknown: \(send("work", "nobody"))")
        check(send(nil, "developer").contains("matches several assistants"), "outside a Main the same role in two workspaces is ambiguous")
        let overview = (try? tools("work").first { $0.name == "agents_overview" }!.run([:])) ?? ""
        check(overview.contains("assistant Developer") && overview.contains("assistant:work:developer") && !overview.contains("assistant:personal"), overview)
    }),
    ("assistants: Always allow for send_to_agent is offered per target, for a Main's own workspace only", {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = AssistantFiles(folder: folder.appendingPathComponent("Workspaces"), home: folder.path)
        files.ensureDefaults("work")
        files.ensureDefaults("personal")
        files.write("---\nname: Planner\n---\n", workspace: "work", slug: "planner")
        var sources = MCPServer.AgentSources(stateFile: folder.appendingPathComponent("agents.json"), inbox: folder, projects: folder, slack: { nil })
        sources.assistants = files
        sources.workspaces = MCPServer.WorkspaceSource(file: { WorkspaceFile(workspaces: Workspaces.defaults) }, environment: { nil })
        func rule(_ workspace: String, _ args: [String: Any], tool: String = AgentDelegation.tool) -> AgentRule? {
            AgentDelegation.rule(tool: tool, input: args, workspace: workspace, sources: sources)
        }
        let developer = rule("work", ["agent": "Developer assistant", "text": "Review https://github.com/o/r/pull/1"])
        check(developer?.value == "delegate:work:assistant:work:developer", developer?.value ?? "nil")
        check(developer?.delegateLabel == "Main (Work) may message Developer" && AgentRules.offerButton([developer!]) == "Always allow Main \u{2192} Developer", "named")
        check(developer == rule("work", ["agent": "developer", "text": "other text"]), "the same rule whatever the free text")
        check(rule("personal", ["agent": "developer"])?.value == "delegate:personal:assistant:personal:developer", "each workspace its own")
        check(rule("personal", ["agent": "assistant:work:developer"]) == nil, "another workspace's agent")
        check(rule("personal", ["agent": "developer", "workspace": "work"]) == nil, "a workspace argument pointing elsewhere")
        check(rule("work", ["agent": "nobody"]) == nil && rule("work", ["agent": "planner"]) == nil && rule("work", ["text": "x"]) == nil, "unknown, broken, none")
        check(rule("work", ["agent": "developer"], tool: "Bash") == nil && rule("nowhere", ["agent": "developer"]) == nil, "only send_to_agent, only a known workspace")
        let pr = rule("work", ["pr_url": "https://github.com/quiddly-com/finq.api/pull/12"])
        check(pr?.title != nil && pr?.value.hasPrefix("delegate:work:https://github.com/quiddly-com/finq.api/pull/12") == true, pr?.value ?? "nil")
        let saved = AgentRules.decode(AgentRules.encode([developer!]))
        check(saved == [developer!] && saved.first?.title == "Developer" && saved.first?.workspaceName == "Work", "kept with its names")
        check(AgentRules.adding([AgentRule(kind: .delegate, value: developer!.value)], to: saved) == saved, "not added twice")
        check(developer!.json == ["kind": "delegate", "value": developer!.value], "the sidecar gets the kind and value")
        check(AgentRules.offer([developer!]) == "Main (Work) may message Developer without asking" && AgentRules.offerButton([]) == "Always allow", "card text")
    }),
    ("assistants: the sidecar is sent the tools the assistant may call and nothing else", {
        let developer = Assistants.template("developer")!.role
        let allowed = Assistants.allowedTools(developer)
        check(allowed.contains("mcp__worktime__activity_context") && allowed.contains("mcp__worktime__github_pr") && allowed.contains("mcp__worktime__jira_issue"), "\(allowed)")
        check(!allowed.contains("mcp__worktime__send_to_agent") && !allowed.contains("mcp__worktime__slack_thread"), "not what the role does not list")
        var other = role("Other")
        other.tools = ["mcp__other__thing", "jira_issue", "jira_issue"]
        check(Assistants.allowedTools(other).filter { $0 == "mcp__worktime__jira_issue" }.count == 1 && Assistants.allowedTools(other).contains("mcp__other__thing"), "full names pass, names once")
        check(Assistants.allowedTools(role("Bare")) == Assistants.defaultTools.map { "mcp__worktime__" + $0 }, "the default read-only set")
        let line = AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: nil, allowedTools: ["mcp__worktime__time_report"]).line
        check(line.contains(#""allowedMcpTools":["mcp__worktime__time_report"]"#), line)
        check(!AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: nil).line.contains("allowedMcpTools"), "an agent without a list is not restricted")
    }),
    ("assistants: model and permission mode defaults come from the file and map to what the pickers offer", {
        check(Assistants.modelID("sonnet") == AgentLogic.defaultModel && Assistants.modelID("opus") == "claude-opus-5-5" && Assistants.modelID("haiku") == "claude-haiku-5-5", "models")
        check(Assistants.modelID("nope") == AgentLogic.defaultModel && Assistants.modelID("auto") == AgentLogic.defaultModel, "unknown model")
        check(Assistants.permissionMode("ask") == .ask && Assistants.permissionMode("auto") == .auto && Assistants.permissionMode("acceptEdits") == .acceptEdits
              && Assistants.permissionMode("plan") == .plan && Assistants.permissionMode("x") == .ask, "modes")
        check(Assistants.wordCount("---\nname: X\ndescription: y\n---\n\none two\nthree") == 3 && Assistants.wordCount("") == 0, "words of the body only")
    }),
]

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
