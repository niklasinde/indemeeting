import Foundation

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Files are created in the order written: the creation date is the one the folder is searched by.
private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
    Thread.sleep(forTimeInterval: 0.05)
}

private func readText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

private let sample = "11111111-2222-3333-4444-555555555555"
private let other = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
private let prURL = "https://github.com/acme/api/pull/7"
private let folderCwd = "/Users/niklasinde/git/inde/indemeeting"

private final class Stub {}

let claudeResumeTests: [(name: String, run: () throws -> Void)] = [
    ("session ids are UUIDs and nothing else can name a transcript", {
        check(ClaudeTranscripts.isSessionID(sample) && ClaudeTranscripts.isSessionID(other.lowercased()), "UUIDs are accepted")
        for bad in ["", "../../etc/passwd", "\(sample).jsonl", "\(sample) ; rm -rf ~", "1111-2222", sample + "\n"] {
            check(!ClaudeTranscripts.isSessionID(bad), "rejected \(bad)")
        }
        check(ClaudeTranscripts.transcript(id: "../x", cwd: folderCwd) == nil, "a bad id gives no path")
    }),

    ("the folder name is Claude Code's name for the working folder, as on this Mac", {
        check(ClaudeTranscripts.folderName(cwd: folderCwd) == "-Users-niklasinde-git-inde-indemeeting", "plain path")
        check(ClaudeTranscripts.folderName(cwd: "/Users/niklasinde/git/inde/devops.indepower.se/.claude/worktrees/payment-batches-white-box-cd520a")
              == "-Users-niklasinde-git-inde-devops-indepower-se--claude-worktrees-payment-batches-white-box-cd520a", "worktree under .claude")
        check(ClaudeTranscripts.folderName(cwd: "/Users/niklasinde/Library/Application Support/Claude/scratch-workspaces/46337f81-8cc2/da9569b6/scratch-2026-09-10-374f98")
              == "-Users-niklasinde-Library-Application-Support-Claude-scratch-workspaces-46337f81-8cc2-da9569b6-scratch-2026-09-10-374f98", "space")
    }),

    ("the newest transcript created after the terminal started and mentioning the pull request is the session", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = "99999999-2222-3333-4444-555555555555", noise = "CCCCCCCC-2222-3333-4444-555555555555"
        let newer = "BBBBBBBB-2222-3333-4444-555555555555", notUUID = "not-a-uuid"
        try write("Pull request: \(prURL)", to: folder.appendingPathComponent(before + ".jsonl"))
        Thread.sleep(forTimeInterval: 0.05)
        let started = Date()
        Thread.sleep(forTimeInterval: 0.05)
        try write("unrelated", to: folder.appendingPathComponent(noise + ".jsonl"))
        try write("Pull request: \(prURL)", to: folder.appendingPathComponent(notUUID + ".jsonl"))
        try write("Pull request: \(prURL)", to: folder.appendingPathComponent("notes.txt"))
        check(ClaudeTranscripts.newestSession(in: folder, since: started, containing: prURL) == nil, "nothing qualifies yet")
        try write("Pull request: \(prURL)", to: folder.appendingPathComponent(sample + ".jsonl"))
        try write("Pull request: \(prURL)", to: folder.appendingPathComponent(newer + ".jsonl"))
        check(ClaudeTranscripts.newestSession(in: folder, since: started, containing: prURL) == newer, "the newest one wins")
        try FileManager.default.removeItem(at: folder.appendingPathComponent(newer + ".jsonl"))
        check(ClaudeTranscripts.newestSession(in: folder, since: started, containing: prURL) == sample, "then the one before it")
    }),

    ("a transcript exists only where the stored folder and id say", {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ClaudeTranscripts.folder(cwd: folderCwd, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("{}", to: folder.appendingPathComponent(sample + ".jsonl"))
        check(ClaudeTranscripts.exists(id: sample, cwd: folderCwd, root: root), "present")
        check(!ClaudeTranscripts.exists(id: other, cwd: folderCwd, root: root), "missing id")
        check(!ClaudeTranscripts.exists(id: sample, cwd: "/elsewhere", root: root), "other folder")
        check(!ClaudeTranscripts.exists(id: "../\(sample)", cwd: folderCwd, root: root), "not a UUID")
    }),

    ("the title is the custom title the user set, else the first line they wrote", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let user = "{\"type\":\"user\",\"cwd\":\"\(folderCwd)\",\"message\":{\"role\":\"user\",\"content\":\"Pull request: \(prURL)\\nmore\"}}"
        try write(user + "\n", to: folder.appendingPathComponent(sample + ".jsonl"))
        check(ClaudeTranscripts.title(in: folder, id: sample) == "Pull request: \(prURL)", "first line")
        try write(user + "\n{\"type\":\"custom-title\",\"customTitle\":\"Mine\"}\n", to: folder.appendingPathComponent(sample + ".jsonl"))
        check(ClaudeTranscripts.title(in: folder, id: sample) == "Mine", "custom title")
    }),

    ("resume, reattach or start new follows the running session, the stored row and its transcript", {
        check(GitHubClaude.resumption(running: true, storedID: sample, transcriptExists: true) == .reattach, "a running session is reattached")
        check(GitHubClaude.resumption(running: true, storedID: nil, transcriptExists: false) == .reattach, "running wins over no row")
        check(GitHubClaude.resumption(running: false, storedID: sample, transcriptExists: true) == .resume(sample), "transcript there: resume")
        check(GitHubClaude.resumption(running: false, storedID: sample, transcriptExists: false) == .startNew(forget: true), "transcript gone: forget")
        check(GitHubClaude.resumption(running: false, storedID: nil, transcriptExists: false) == .startNew(forget: false), "no row: start new")
        check(GitHubClaude.resumption(running: false, storedID: "../x", transcriptExists: true) == .startNew(forget: true), "a stored non-UUID is never resumed")
    }),

    ("a second open for the same pull request reattaches to the session it has", {
        var registry = TerminalRegistry<Stub>()
        var made = 0
        let first = registry.attach(prURL) { made += 1; return Stub() }
        let second = registry.attach(prURL) { made += 1; return Stub() }
        check(first === second && made == 1, "one session per pull request")
    }),

    ("resuming runs claude with --resume and the id as its own argument, and no prompt", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let work = folder.appendingPathComponent("it's a \"dir\" $HOME", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let argv = folder.appendingPathComponent("argv")
        let cli = folder.appendingPathComponent("claude")
        try ("#!/bin/sh\nprintf '%s\\n' \"$#\" > \(GitHubClaude.shellQuote(argv.path))\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> \(GitHubClaude.shellQuote(argv.path)); done\n")
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let resume = GitHubClaude.Resume(id: sample, title: "Fix it")

        check(try runLoginShell(script: EmbeddedTerminal.script(directory: work, promptFile: nil, cli: cli, flags: resume.flags), in: folder) == 0,
              "the login shell ran the CLI")
        check(readText(argv) == "2\n--resume\n\(sample)\n", "exactly --resume and the id: \(readText(argv))")

        let launcher = try GitHubClaude.writeLaunchFiles(prompt: nil, directory: work, cli: cli, flags: resume.flags, folder: folder.appendingPathComponent("launch"))
        check((try? FileManager.default.contentsOfDirectory(atPath: launcher.deletingLastPathComponent().path)) == [launcher.lastPathComponent],
              "no prompt file is written for a resume")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/zsh")
        run.arguments = [launcher.path]
        try run.run()
        run.waitUntilExit()
        check(readText(argv) == "2\n--resume\n\(sample)\n", "the .command passes the same arguments")
        check(!FileManager.default.fileExists(atPath: launcher.path), "the .command removes itself")
    }),

    ("the headless run's session id comes from its stream", {
        var stream = GitHubClaude.Stream()
        stream.consume("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\(sample)\"}")
        stream.consume("{\"type\":\"result\",\"result\":\"ok\",\"is_error\":false,\"session_id\":\"\(sample)\"}")
        check(stream.sessionID == sample, "read from the stream")
    }),

    ("saved sessions round-trip, and forget removes one pull request or all", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore(path: folder.appendingPathComponent("store.sqlite").path)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let interactive = GitHubClaudeSession(url: prURL, id: sample, cwd: "/work/api", kind: .interactive, preset: .review, title: "Fix it", updated: date)
        let review = GitHubClaudeSession(url: prURL, id: other, cwd: "/work/api", kind: .review, preset: .explain, title: nil, updated: date)
        let second = GitHubClaudeSession(url: "https://github.com/acme/api/pull/8", id: sample, cwd: "/work/api", kind: .interactive, preset: nil, title: nil, updated: date)
        try store.saveGitHubSession(interactive)
        try store.saveGitHubSession(review)
        try store.saveGitHubSession(second)
        let rows = try store.githubSessions()
        check(rows.count == 3 && rows.contains(interactive) && rows.contains(review) && rows.contains(second), "round trip: \(rows)")

        let replaced = GitHubClaudeSession(url: prURL, id: other, cwd: "/work/other", kind: .interactive, preset: .summary, title: nil, updated: date)
        try store.saveGitHubSession(replaced)
        check(try store.githubSessions().filter { $0.url == prURL && $0.kind == .interactive } == [replaced], "one interactive row per pull request")

        try store.forgetGitHubSessions(prURL)
        check(try store.githubSessions() == [second], "forget one pull request")
        try store.forgetGitHubSessions()
        check(try store.githubSessions().isEmpty, "forget all")
    }),
]
