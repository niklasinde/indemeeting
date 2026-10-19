import Foundation

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("githubclaude-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func script(_ body: String, in folder: URL, name: String = "claude") throws -> URL {
    let url = folder.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private let context = GitHubClaude.Context(url: "https://github.com/acme/api/pull/7", repo: "acme/api", number: 7, title: "QDLY-1: Fix it",
                                            base: "develop", head: "NI/QDLY-1", ticket: "QDLY-1")

private func runProcess(_ cli: URL, directory: URL, cancelAfter: TimeInterval? = nil, timeout: TimeInterval = 20) -> (ClaudeProcess.Outcome, [String]) {
    let process = ClaudeProcess()
    let lines = LockedLines()
    let done = DispatchSemaphore(value: 0)
    var outcome: ClaudeProcess.Outcome?
    Task {
        outcome = await process.run(cli: cli, arguments: [], directory: directory, environment: ProcessInfo.processInfo.environment,
                                    timeout: timeout) { lines.add($0) }
        done.signal()
    }
    if let cancelAfter {
        Thread.sleep(forTimeInterval: cancelAfter)
        process.cancel()
    }
    _ = done.wait(timeout: .now() + 30)
    return (outcome ?? ClaudeProcess.Outcome(status: -99, stderr: "no outcome", cancelled: false, timedOut: false), lines.all)
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

let githubClaudeTests: [(name: String, run: () throws -> Void)] = [
    ("the headless run allows only reading and denies every way of writing", {
        let allowed = GitHubClaude.readOnlyTools, denied = GitHubClaude.deniedTools
        for write in ["Edit", "Write", "NotebookEdit", "gh pr review", "gh pr comment", "gh pr merge", "gh api", "git push", "git commit"] {
            check(!allowed.contains { $0.contains(write) }, "\(write) must not be allowed")
            check(denied.contains { $0.contains(write) }, "\(write) must be denied")
        }
        check(Set(allowed).isDisjoint(with: denied), "nothing is both allowed and denied")
        check(allowed.contains("Bash(gh pr diff:*)") && allowed.contains("Bash(gh run view:*)") && allowed.contains("Read"), "the reads are there")
        let arguments = GitHubClaude.headlessArguments(prompt: "hello", model: nil)
        check(Array(arguments.prefix(2)) == ["-p", "hello"], "the prompt follows -p")
        check(arguments.contains("dontAsk") && arguments.contains("--no-session-persistence"), "anything not allowed is refused")
        check(arguments.firstIndex(of: "--setting-sources").map { arguments[$0 + 1] == "" } ?? false, "no settings file is read")
        check(arguments.contains("--allowedTools=" + allowed.joined(separator: ",")), "allowed list passed")
        check(arguments.contains("--disallowedTools=" + denied.joined(separator: ",")), "denied list passed")
        check(!arguments.contains("--model"), "no model unless chosen")
        check(GitHubClaude.headlessArguments(prompt: "x", model: " opus ").suffix(2) == ["--model", "opus"], "model passed through")
    }),

    ("every preset names the pull request, its branches and ticket, and promises to stay read-only", {
        for preset in GitHubClaude.Preset.allCases {
            let prompt = GitHubClaude.prompt(preset, context)
            for part in ["https://github.com/acme/api/pull/7", "acme/api #7", "QDLY-1: Fix it", "develop \u{2190} NI/QDLY-1", "Ticket: QDLY-1",
                         "Do not post comments or reviews, approve, merge, push, commit"] {
                check(prompt.contains(part), "\(preset): \(part)")
            }
            check(!prompt.contains("no local checkout"), "\(preset) has a checkout")
        }
        var bare = context
        bare.ticket = nil
        bare.hasCheckout = false
        let prompt = GitHubClaude.prompt(.checks, bare)
        check(!prompt.contains("Ticket:") && prompt.contains("no local checkout") && prompt.contains("gh run view <id> --log-failed"), "no ticket, no checkout")
        check(GitHubClaude.prompt(.comments, context).contains("Ask before"), "comments are proposed, not applied")
        check(GitHubClaude.Preset.headless == [.review, .explain, .checks, .summary], "the headless presets")
    }),

    ("a review is copied as a comment that says on its first line that an AI wrote it", {
        check(GitHubClaude.reviewComment("Looks fine.").hasPrefix("[AI]\nLooks fine."), "prefixed")
    }),

    ("a hostile title reaches claude unchanged and the files are private and short-lived", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("received.txt")
        let cli = try script("printf '%s' \"$1\" > \(GitHubClaude.shellQuote(output.path))\n", in: folder)
        let work = folder.appendingPathComponent("it's a \"dir\" $HOME", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var hostile = context
        hostile = GitHubClaude.Context(url: context.url, repo: "acme/api", number: 7, title: "Fix \"quotes\", $HOME, `rm -rf ~`, 'single', \\ and \u{00E5}\u{00E4}\u{00F6} \u{00C5}\u{00C4}\u{00D6}\n$(touch /tmp/pwned)")
        let prompt = GitHubClaude.prompt(.review, hostile)
        let prompts = folder.appendingPathComponent("prompts")
        let old = prompts.appendingPathComponent("old.txt")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: old.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        let launcher = try GitHubClaude.writeLaunchFiles(prompt: prompt, directory: work, cli: cli, folder: prompts)
        check(!FileManager.default.fileExists(atPath: old.path), "a file older than a day is removed")
        let promptFile = launcher.deletingPathExtension().appendingPathExtension("txt")
        func permissions(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? 0 }
        check(permissions(promptFile) == 0o600 && permissions(launcher) == 0o700, "0600 prompt, 0700 script")
        check(!(try String(contentsOf: launcher, encoding: .utf8)).contains("quotes"), "the title is not in the script")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/zsh")
        run.arguments = [launcher.path]
        try run.run()
        run.waitUntilExit()
        check(run.terminationStatus == 0, "the script ran")
        check((try? String(contentsOf: output, encoding: .utf8)) == prompt, "the prompt arrived exactly")
        check(!FileManager.default.fileExists(atPath: "/tmp/pwned"), "nothing in the title was executed")
        check(!FileManager.default.fileExists(atPath: promptFile.path) && !FileManager.default.fileExists(atPath: launcher.path), "both files remove themselves")
    }),

    ("the shell quoting survives single quotes", {
        check(GitHubClaude.shellQuote("it's") == "'it'\\''s'", GitHubClaude.shellQuote("it's"))
    }),

    ("the checkout is the repository under ~/git whose remote is the pull request's repository", {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        func repo(_ path: String, remote: String?) throws {
            let git = root.appendingPathComponent(path + "/.git", isDirectory: true)
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            if let remote { try "[remote \"origin\"]\n\turl = \(remote)\n".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8) }
        }
        try repo("quiddly/finq.api", remote: "git@github.com:quiddly-com/finq.api.git")
        try repo("quiddly/other", remote: "git@bitbucket.org:finqr/finq.api.git")
        try repo("copy-of-api", remote: "https://github.com/Quiddly-Com/finq.api")
        try repo("nowhere", remote: nil)
        check(GitHubClaude.checkout(for: "quiddly-com/finq.api", under: root)?.lastPathComponent == "finq.api", "named like the repository wins")
        check(GitHubClaude.checkout(for: "Quiddly-Com/FINQ.API", under: root) != nil, "case does not matter")
        check(GitHubClaude.checkout(for: "acme/unknown", under: root) == nil, "no checkout")
        check(GitHubClaude.remotes(inGitConfig: "[remote \"a\"]\n url = ssh://git@github.com/x/y.git\n[remote \"b\"]\n\turl = https://example.com/x/z") == ["x/y"], "only GitHub remotes")
    }),

    ("the destination falls back to what is installed and what exists", {
        let home = URL(fileURLWithPath: "/Users/x")
        let cli = URL(fileURLWithPath: "/usr/local/bin/claude")
        let checkout = URL(fileURLWithPath: "/Users/x/git/acme/api")
        func plan(_ destination: GitHubClaude.Destination, cli: URL? = cli, checkout: URL? = checkout, prompt: String = "p", installed: Bool = true) -> GitHubClaude.Launch {
            GitHubClaude.plan(destination, cli: cli, checkout: checkout, home: home, prompt: prompt) { _ in installed }
        }
        check(plan(.terminal) == .terminal(.terminal, directory: checkout, cli: cli), "terminal in the checkout")
        check(plan(.terminal, checkout: nil) == .terminal(.terminal, directory: home, cli: cli), "home without a checkout")
        check(plan(.ghostty, installed: false) == .terminal(.terminal, directory: checkout, cli: cli), "a missing terminal app falls back to Terminal")
        check(plan(.iterm, cli: nil) == .cliMissing, "no CLI is reported")
        if case .appLink(let link) = plan(.claudeApp, cli: nil) { check(link.absoluteString.hasPrefix("claude://code/new?q=p&folder="), link.absoluteString) } else { check(false, "app link") }
        check(plan(.claudeApp, prompt: String(repeating: "x", count: 7000)) == .copyAndOpenApp, "a prompt too long for a link is copied")
    }),

    ("the app link carries the prompt and folder percent-encoded", {
        let prompt = "A & B + C = \"D\"\n\u{00E5}\u{00E4}\u{00F6} #1 100%"
        let link = GitHubClaude.appLink(prompt: prompt, folder: URL(fileURLWithPath: "/Users/x/git/my repo"))
        let items = link.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
        check(items?.first { $0.name == "q" }?.value == prompt, "prompt round trip")
        check(items?.first { $0.name == "folder" }?.value == "/Users/x/git/my repo", "folder round trip")
    }),

    ("the stream shows the answer as it grows and ends with the result and its cost", {
        var stream = GitHubClaude.Stream()
        stream.consume(#"{"type":"system","subtype":"init"}"#)
        stream.consume(#"{"type":"stream_event","event":{"type":"message_start"}}"#)
        stream.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Looking"}}}"#)
        stream.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking"},{"type":"tool_use","name":"Bash","input":{"command":"gh pr diff 7"}}]}}"#)
        check(stream.text == "Looking" && stream.status == "Bash gh pr diff 7", "\(stream.text) / \(stream.status ?? "")")
        stream.consume(#"{"type":"stream_event","event":{"type":"message_start"}}"#)
        stream.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Done."}}}"#)
        check(stream.text == "Looking\n\nDone." && stream.status == nil, stream.text)
        stream.consume("not json")
        stream.consume(#"{"type":"result","is_error":false,"result":"Final","total_cost_usd":0.25}"#)
        check(stream.result == GitHubClaude.Stream.Result(text: "Final", isError: false, cost: 0.25), "result")
        var whole = GitHubClaude.Stream()
        whole.consume(#"{"type":"stream_event","event":{"type":"message_start"}}"#)
        whole.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"No partials"}]}}"#)
        check(whole.text == "No partials", "a CLI without partial messages still shows the text")
    }),

    ("a failure is told apart when claude is signed out", {
        check(GitHubClaude.failure("Not logged in \u{00B7} Please run /login") == .notLoggedIn, "signed out")
        check(GitHubClaude.failure("Invalid API key") == .notLoggedIn, "key")
        check(GitHubClaude.failure(" boom \n") == .other("boom"), "other")
        check(GitHubClaude.Failure.notLoggedIn.message.contains("claude once in Terminal"), "hint")
        check(GitHubClaude.Failure.cliMissing.message.contains("npm install"), "install hint")
    }),

    ("a review is outdated only when the pull request has moved on from the commit it looked at", {
        check(GitHubClaude.isOutdated(reviewed: "aaa", current: "bbb"), "new commit")
        check(!GitHubClaude.isOutdated(reviewed: "aaa", current: "aaa"), "same commit")
        check(!GitHubClaude.isOutdated(reviewed: nil, current: "bbb"), "unknown reviewed commit")
        check(!GitHubClaude.isOutdated(reviewed: "aaa", current: nil), "unknown current commit")
    }),

    ("a review is saved per pull request, flagged when new commits arrive, and cleared with the cache", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let url = "https://github.com/acme/api/pull/7"
        check(try store.githubReview(url) == nil, "none yet")
        let review = GitHubReview(url: url, headSHA: "abc123", preset: .review, text: "## Findings\n- one", created: Date(timeIntervalSince1970: 1_700_000_000),
                                  duration: 61, cost: 0.31)
        try store.saveGitHubReview(review)
        check(try store.githubReview(url) == review, "round trip")
        check(try store.githubReviews() == [review], "listed")
        check(try store.githubReviewOutdated() == [url: false], "no detail fetched yet")
        let detail = try store.githubDetail(url)
        check(detail == nil, "no detail")
        try store.saveGitHubReview(GitHubReview(url: url, headSHA: "abc123", preset: .explain, text: "again", created: Date(), duration: 1, cost: nil))
        check(try store.githubReview(url)?.preset == .explain && (try store.githubReview(url)?.cost) == nil, "replaced")
        _ = try store.clearGitHubCache()
        check(try store.githubReview(url) == nil, "cleared with the cache")
    }),

    ("a headless run streams its lines and reports the exit", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = try script("echo one\necho two\nprintf three\necho oops >&2\nexit 3\n", in: folder)
        let (outcome, lines) = runProcess(cli, directory: folder)
        check(lines == ["one", "two", "three"], "\(lines)")
        check(outcome.status == 3 && outcome.stderr.contains("oops") && !outcome.cancelled && !outcome.timedOut, "\(outcome)")
    }),

    ("cancelling stops the run and what it started", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("child.pid")
        let cli = try script("sleep 60 &\necho $! > \(GitHubClaude.shellQuote(pidFile.path))\necho started\nwait\n", in: folder)
        let started = Date()
        let (outcome, lines) = runProcess(cli, directory: folder, cancelAfter: 1)
        check(outcome.cancelled && !outcome.timedOut, "\(outcome)")
        check(lines == ["started"], "\(lines)")
        check(Date().timeIntervalSince(started) < 10, "it did not wait for the sleep")
        let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        Thread.sleep(forTimeInterval: 0.3)
        check(pid.map { kill($0, 0) != 0 } ?? false, "the child it started is gone")
    }),

    ("a run past its time limit is stopped", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = try script("sleep 60\n", in: folder)
        let (outcome, _) = runProcess(cli, directory: folder, timeout: 1)
        check(outcome.timedOut && !outcome.cancelled, "\(outcome)")
    }),
]
