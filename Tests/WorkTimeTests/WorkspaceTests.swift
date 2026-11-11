import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let home = "/Users/me"
private let work = Workspaces.defaults[0], personal = Workspaces.defaults[1]
private let now = Date(timeIntervalSince1970: 1_792_300_000)
private let quiddlyPR = "https://github.com/quiddly-com/finq.api/pull/7"
private let personalPR = "https://github.com/niklasinde/worktime/pull/3"
private let strangerPR = "https://github.com/someone/else/pull/1"

private func assign(_ subject: Workspaces.Subject, exists: @escaping (String) -> Bool = { _ in false }) -> String {
    Workspaces.assign(subject, in: Workspaces.defaults, home: home, exists: exists)
}

private func state(_ key: String, folder: String? = nil, pr: String? = nil, jira: String? = nil, workspace: String? = nil,
                   status: AgentState.Status = .idle) -> AgentState {
    AgentState(key: key, title: key, prURL: pr, folder: folder, status: status, jiraKey: jira, workspace: workspace)
}

private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("workspaces-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

let workspaceTests: [(name: String, run: () throws -> Void)] = [
    ("workspaces: a thing belongs by folder, then repository folder, then GitHub owner, then Jira project, else Work", {
        check(assign(.init(folders: ["/Users/me/git/inde/papercut"])) == "personal", "folder under a root")
        check(assign(.init(folders: ["/Users/me/git/quiddly"])) == "work", "the root itself")
        check(assign(.init(folders: ["/Users/me/git/quiddlyx"])) == "work", "a longer name is not under the root, so Work by default")
        check(assign(.init(folders: ["/Users/me/git/inde/x"], owner: "quiddly-com")) == "personal", "folder beats owner")
        check(assign(.init(owner: "NiklasInde")) == "personal", "owner ignoring case")
        check(assign(.init(owner: "quiddly-com")) == "work", "owner")
        check(assign(.init(jiraKey: "isd-12")) == "work", "Jira project")
        check(assign(.init(owner: "someone", jiraKey: "ABC-1")) == "work", "default")
        check(assign(.init(repo: "worktime"), exists: { $0 == "/Users/me/git/inde/worktime" }) == "personal", "the repository exists under a root")
        check(assign(.init(folders: ["/Users/me/git/quiddly/a"], override: "personal")) == "personal", "an override wins")
        check(assign(.init(folders: ["/Users/me/git/quiddly/a"], override: "gone")) == "work", "an override for a missing workspace is ignored")
        let nested = [work, Workspace(id: "api", name: "API", symbol: "a", color: "red", roots: ["/Users/me/git/quiddly/finq.api"], githubOwners: [],
                                      jiraProjects: [], slack: nil, extraFiles: [])]
        check(Workspaces.assign(.init(folders: ["/Users/me/git/quiddly/finq.api/src"]), in: nested, home: home) == "api", "the longest root wins")
        check(Workspaces.expand("~/git/", home: home) == "/Users/me/git" && Workspaces.expand("~", home: home) == home, "paths expand")
    }),
    ("workspaces: agents are assigned and grouped with each Main first", {
        let file = WorkspaceFile(workspaces: Workspaces.defaults, overrides: [strangerPR: "personal"])
        let states = [state("main:work", status: .idle), state("main:personal"),
                      state(quiddlyPR, folder: "/Users/me/git/quiddly/finq.api", pr: quiddlyPR),
                      state(personalPR, pr: personalPR), state(strangerPR, pr: strangerPR),
                      state("topic:1", jira: "QDLY-1"), state("main", workspace: nil)]
        check(Workspaces.assigned(states[0], in: file, home: home) == "work" && Workspaces.assigned(states[1], in: file, home: home) == "personal", "Mains")
        check(Workspaces.assigned(states[4], in: file, home: home) == "personal", "moved by hand")
        check(Workspaces.assigned(state("topic:2", jira: "ISD-9"), in: file, home: home) == "work", "topic by Jira project")
        check(Workspaces.assigned(state("topic:3", folder: "/Users/me/git/inde/x", jira: "ABC-9"), in: file, home: home) == "personal", "topic by folder")
        let groups = Workspaces.groups(Array(states.prefix(5)), file: file, lastUsed: [:], home: home)
        check(groups.map(\.workspace.id) == ["work", "personal"], "in the file's order")
        check(groups[0].main?.key == "main:work" && groups[0].agents.map(\.key) == [quiddlyPR], "\(groups[0].agents.map(\.key))")
        check(Set(groups[1].agents.map(\.key)) == [personalPR, strangerPR] && groups[1].main?.key == "main:personal", "personal group")
        check(groups[1].all.first?.key == "main:personal", "Main first")
        let legacy = Workspaces.groups([state("main")], file: file, lastUsed: [:], home: home)
        check(legacy[0].main?.key == "main", "the old Main key still lands in Work")
        let waiting = Workspaces.Group(workspace: work, main: nil, assistants: [], agents: [state("a", status: .waiting), state("b", status: .working)])
        check(waiting.needing == 1, "only agents that need you count")
    }),
    ("workspaces: keys, the file and what an old agents.json holds", {
        check(Workspaces.mainKey("personal") == "main:personal" && Workspaces.isMainKey("main:personal") && Workspaces.isMainKey("main"), "main keys")
        check(!Workspaces.isMainKey("topic:x") && !Workspaces.isMainKey("https://github.com/a/b/pull/1"), "other keys")
        check(Workspaces.id(ofMainKey: "main") == "work" && Workspaces.id(ofMainKey: "main:personal") == "personal"
              && Workspaces.id(ofMainKey: quiddlyPR) == nil, "ids")
        check(Workspaces.decode(nil).workspaces == Workspaces.defaults && Workspaces.decode(Data("nope".utf8)).workspaces == Workspaces.defaults, "defaults")
        var file = WorkspaceFile(workspaces: Workspaces.defaults)
        file.workspaces[1].name = "Home"
        file.overrides["x"] = "work"
        check(Workspaces.decode(Workspaces.encode(file)) == file, "round trip")
        check(work.roots == ["~/git/quiddly"] && work.githubOwners == ["quiddly-com"] && work.jiraProjects == ["QDLY", "ISD", "QPB"]
              && work.slack == "Quiddly", "Work defaults")
        check(personal.roots == ["~/git/inde"] && personal.githubOwners == ["niklasinde"] && personal.jiraProjects.isEmpty && personal.slack == nil, "Personal defaults")
        check(personal.defaultFolder(home: home) == "/Users/me/git/inde", "a Main starts in its root")
        let written = AgentOverview.encode([state("main:work", workspace: "work")], now: now)
        check(String(decoding: written, as: UTF8.self).contains(#""workspace" : "work""#), "agents.json has the workspace")
        let old = #"{"written":"2026-10-20T10:00:00Z","agents":[{"key":"main","title":"Main","status":"idle","seen":true,"loaded":true,"queued":0}]}"#
        check(AgentOverview.decode(Data(old.utf8))?.agents.first?.workspace == nil, "an old file has none")
    }),
    ("workspaces: the old Main migrates to Work with its session, folder and history", {
        let moved = Workspaces.migratedMain(sessions: [:], folders: [:], session: "s1", folder: "/Users/me/git")
        check(moved.sessions == ["work": "s1"] && moved.folders == ["work": "/Users/me/git"], "moved")
        let kept = Workspaces.migratedMain(sessions: ["work": "newer"], folders: [:], session: "s1", folder: nil)
        check(kept.sessions == ["work": "newer"] && kept.folders.isEmpty, "what is saved wins")
        let history = ["main": [AgentSessionEntry(id: "a", folder: "/x", created: now, lastUsed: now, title: "T")], quiddlyPR: []]
        let renamed = Workspaces.renamedMain(history)
        check(renamed["main"] == nil && renamed["main:work"]?.first?.id == "a" && renamed[quiddlyPR] != nil, "history key")
        check(Workspaces.renamedMain(["main": 1, "main:work": 2])["main:work"] == 2, "never overwrites")
        check(Workspaces.renamedMain(["x": 1]) == ["x": 1], "nothing to move")
        check(AgentSessions.key(agent: nil, isMain: true, folder: "/x", workspace: "personal") == "main:personal", "history key per workspace")
        check(AgentSessions.key(agent: nil, isMain: true, folder: "/x") == "main", "old key without one")
        check(AgentLogic.childEnvironment(["PATH": "/bin"], nodeFolder: "/n", mcpCommand: "/app", workspace: "personal")[Workspaces.envKey] == "personal", "env var")
        check(AgentLogic.childEnvironment(["PATH": "/bin"], nodeFolder: "/n", mcpCommand: "/app")[Workspaces.envKey] == nil, "none for other agents")
    }),
    ("workspaces: tool arguments default to the calling Main's workspace", {
        let all = Workspaces.defaults
        func scope(_ argument: Any?, _ environment: String?) -> WorkspaceScope? { try? Workspaces.scope(argument: argument, environment: environment, in: all).get() }
        check(scope(nil, "personal") == WorkspaceScope(id: "personal", named: false), "from the environment")
        check(scope(nil, nil) == .all && scope(nil, "gone") == .all, "outside a Main, or an unknown one: everything")
        check(scope("work", "personal") == WorkspaceScope(id: "work", named: true), "named")
        check(scope("PERSONAL", nil)?.id == "personal" && scope("Work", nil)?.id == "work", "by name or id, ignoring case")
        check(scope("all", "personal") == .all, "all")
        check(scope("  ", "personal")?.id == "personal", "blank means the default")
        if case .failure(let error) = Workspaces.scope(argument: "nowhere", environment: nil, in: all) {
            check(error.message.contains("work, personal"), error.message)
        } else { check(false, "unknown refused") }
        check(Workspaces.includes(nil, in: WorkspaceScope(id: "work")) && !Workspaces.includes(nil, in: WorkspaceScope(id: "personal")), "no workspace is Work's")
        let agents = [state("a", workspace: "work"), state("b", workspace: "personal"), state("c")]
        check(Workspaces.filter(agents, in: WorkspaceScope(id: "personal")).map(\.key) == ["b"], "agents")
        check(Workspaces.filter(agents, in: .all).count == 3 && Workspaces.filter(agents, in: WorkspaceScope(id: "work")).map(\.key) == ["a", "c"], "agents, Work")
        let prs = [GitHubPR(url: quiddlyPR, number: 7, title: "a", repo: "quiddly-com/finq.api", updated: now),
                   GitHubPR(url: personalPR, number: 3, title: "b", repo: "niklasinde/worktime", updated: now),
                   GitHubPR(url: strangerPR, number: 1, title: "c", repo: "someone/else", updated: now)]
        let file = WorkspaceFile(workspaces: all, overrides: [strangerPR: "personal"])
        check(Workspaces.filter(prs, in: WorkspaceScope(id: "personal"), file: file).map(\.number) == [3, 1], "pull requests by owner and override")
        check(Workspaces.filter(prs, in: WorkspaceScope(id: "work"), file: file).map(\.number) == [7], "Work's")
        check(Workspaces.filter(prs, in: .all, file: file).count == 3, "all")
        func block(_ key: ActivityKey) -> ActivityBlock { ActivityBlock(id: 1, start: now, end: now.addingTimeInterval(60), key: key) }
        let blocks = [block(ActivityKey(repo: "worktime", claude: [], idle: false)),
                      block(ActivityKey(repo: "finq.api", ticket: "QDLY-1", claude: [], idle: false)),
                      block(ActivityKey(repo: "x", claude: [ClaudeSession(id: "1", folder: "/Users/me/git/inde/x", title: "")], idle: false))]
        let found = Workspaces.filter(blocks, in: WorkspaceScope(id: "personal"), file: file, home: home) { $0 == "/Users/me/git/inde/worktime" }
        check(found.map(\.key.repo) == ["worktime", "x"], "activity by folder, repository folder, session folder: \(found.map(\.key.repo))")
    }),
    ("workspaces: a Main cannot delegate to another workspace unless the user names it", {
        let all = Workspaces.defaults
        let own = WorkspaceScope(id: "personal")
        check(Workspaces.delegationProblem(target: "personal", scope: own, workspaces: all) == nil, "its own")
        check(Workspaces.delegationProblem(target: nil, scope: WorkspaceScope(id: "work"), workspaces: all) == nil, "none is Work")
        check(Workspaces.delegationProblem(target: "work", scope: own, workspaces: all)?.contains("Work workspace") == true, "another's is refused")
        check(Workspaces.delegationProblem(target: "work", scope: WorkspaceScope(id: "personal", named: true), workspaces: all) == nil, "named")
        check(Workspaces.delegationProblem(target: "work", scope: .all, workspaces: all) == nil, "outside a Main")
        let prompt = AgentLogic.mainSystemPrompt(workspace: personal, others: [work])
        check(prompt.contains("Main for the Personal workspace") && prompt.contains("~/git/inde") && prompt.contains("niklasinde")
              && prompt.contains("no Jira") && prompt.contains("Slack is not part of it") && prompt.contains("(Work)"), prompt)
        let workPrompt = AgentLogic.mainSystemPrompt(workspace: work, others: [personal])
        check(workPrompt.contains("QDLY, ISD, QPB") && workPrompt.contains("Slack workspace is Quiddly") && workPrompt.contains("attention"), workPrompt)
    }),
    ("workspaces: the MCP tools see only their workspace and refuse another's agents", {
        let folder = try scratch(), state = folder.appendingPathComponent("agents.json"), inbox = folder.appendingPathComponent("inbox")
        defer { try? FileManager.default.removeItem(at: folder) }
        try AgentOverview.encode([AgentState(key: "main:work", title: "Main", status: .idle, workspace: "work"),
                                  AgentState(key: quiddlyPR, title: "finq.api#7", prURL: quiddlyPR, status: .waiting, pendingTool: "Bash", seen: false, workspace: "work"),
                                  AgentState(key: personalPR, title: "worktime#3", prURL: personalPR, status: .working, workspace: "personal")], now: now).write(to: state)
        func tools(_ environment: String?) -> [MCPTool] {
            var sources = MCPServer.AgentSources(stateFile: state, inbox: inbox, projects: folder, replyTimeout: 0.2, slack: { "- DM\n" })
            sources.workspaces = MCPServer.WorkspaceSource(file: { WorkspaceFile(workspaces: Workspaces.defaults) }, environment: { environment })
            return MCPServer.agentTools(.failure(MCPToolError("no db")), sources: sources, now: { now })
        }
        func run(_ environment: String?, _ name: String, _ args: [String: Any] = [:]) -> String {
            (try? tools(environment).first { $0.name == name }!.run(args)) ?? "ERROR"
        }
        let personalOverview = run("personal", "agents_overview")
        check(personalOverview.contains("worktime#3") && !personalOverview.contains("finq.api#7"), personalOverview)
        check(run("work", "agents_overview").contains("finq.api#7") && !run("work", "agents_overview").contains("worktime#3"), "Work's")
        check(run(nil, "agents_overview").contains("worktime#3") && run(nil, "agents_overview").contains("finq.api#7"), "outside a Main: all")
        check(run("personal", "agents_overview", ["workspace": "work"]).contains("finq.api#7"), "named")
        check(run("personal", "agents_overview", ["workspace": "nowhere"]) == "ERROR", "unknown refused")
        let attention = run("personal", "attention")
        check(attention.contains("worktime#3") && !attention.contains("finq.api#7") && !attention.contains("Slack"), "no Slack for Personal: \(attention)")
        check(run("work", "attention").contains("## Slack") && run("work", "attention").contains("finq.api#7"), "Work's attention")
        check(run("personal", "send_to_agent", ["pr_url": quiddlyPR, "text": "go"]) == "ERROR", "another workspace's agent is refused")
        check(run("personal", "agent_session", ["pr_url": quiddlyPR]) == "ERROR", "and not read")
        let named = Result { try tools("personal").first { $0.name == "send_to_agent" }!.run(["pr_url": quiddlyPR, "text": "go", "workspace": "work"]) }
        if case .failure(let error) = named { check(error.localizedDescription.contains("Is the app running?"), "named, so it reaches the inbox: \(error.localizedDescription)") }
        else { check(false, "nothing answers") }
        for name in ["agents_overview", "agent_session", "attention", "send_to_agent"] {
            let properties = (tools(nil).first { $0.name == name }!.listing["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            check(properties?["workspace"] != nil, "\(name) takes workspace")
        }
    }),
    ("workspaces: Main's instructions follow the scope text, MAIN.md and the extra files, cut at the limit", {
        let scope = "SCOPE"
        check(WorkspaceInstructions.compose(scope: scope, main: nil, extras: []) == scope && WorkspaceInstructions.compose(scope: scope, main: "  \n", extras: []) == scope, "nothing to add")
        let composed = WorkspaceInstructions.compose(scope: scope, main: "Be brief.", extras: [("~/CLAUDE.md", "Use Swedish."), ("~/gone.md", nil), ("~/empty.md", " ")])
        let order = ["SCOPE", "Be brief.", "Use Swedish."].compactMap { composed.range(of: $0)?.lowerBound }
        check(order.count == 3 && order == order.sorted(), "scope, MAIN.md, extras: \(composed)")
        check(composed.contains("~/CLAUDE.md") && !composed.contains("gone.md") && !composed.contains("empty.md"), "missing and empty files are skipped")
        let long = WorkspaceInstructions.compose(scope: scope, main: String(repeating: "a", count: 50), extras: [("~/b", "second")], limit: 40)
        check(long.hasSuffix(WorkspaceInstructions.cutNote) && !long.contains("second") && long.contains("SCOPE"), long)
        let exact = WorkspaceInstructions.compose(scope: scope, main: "x", extras: [], limit: 1000)
        check(!exact.contains("cut here"), "short enough")
        check(WorkspaceInstructions.limit == 20_000, "about 20k characters")
        let huge = WorkspaceInstructions.compose(scope: scope, main: String(repeating: "z", count: 30_000), extras: [])
        check(huge.count < scope.count + 20_500 && huge.contains("cut here"), "\(huge.count)")
    }),
    ("workspaces: MAIN.md is made from a template on first use, read fresh and reset on request", {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = WorkspaceInstructionFiles(folder: folder.appendingPathComponent("Workspaces"), home: folder.path)
        let url = files.url(for: work)
        check(url.path.hasSuffix("Workspaces/work/MAIN.md"), url.path)
        check(!FileManager.default.fileExists(atPath: url.path), "not made until used")
        let template = files.read(work) ?? ""
        check(template == WorkspaceInstructions.template(for: work) && template.contains("Never post to Jira, Slack or GitHub without my approval"), "made from the template")
        check(template.contains("Purpose") && template.contains("Catch up") && template.contains("Tone") && template.contains("Standing rules"), "sections")
        check(!files.isCustom(work), "the template is not custom")
        let first = files.prompt(for: work, others: [personal])
        check(first.contains("Main for the Work workspace") && first.contains("Standing rules"), "in the prompt")
        files.write("Only talk about invoices.", for: work)
        let second = files.prompt(for: work, others: [personal])
        check(second.contains("Only talk about invoices.") && !second.contains("Standing rules"), "an edit applies at the next prompt")
        check(files.isCustom(work), "edited")
        try Data("Prefer Swedish.".utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        var extra = work
        extra.extraFiles = ["~/CLAUDE.md", "~/missing.md"]
        let withExtra = files.prompt(for: extra, others: [])
        check(withExtra.contains("Prefer Swedish.") && !withExtra.contains("missing.md"), "an extra file is added, a missing one skipped")
        try Data("Prefer English.".utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        check(files.prompt(for: extra, others: []).contains("Prefer English."), "extra files are read fresh too")
        files.reset(work)
        check(files.read(work) == template && !files.isCustom(work), "reset to the default")
        check(files.isCustom(extra) && !files.isCustom(personal), "an extra file counts as custom; another workspace has its own file")
        check(files.url(for: personal) != url, "one file per workspace")
        check(WorkspaceInstructions.template(for: personal).contains("Personal"), "named in its template")
    }),
]
