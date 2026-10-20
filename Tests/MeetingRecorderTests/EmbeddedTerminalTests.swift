import Foundation

private final class FakeSession { var running: Bool; init(_ running: Bool) { self.running = running } }

private let hostileTitles = [
    "Fix \"quotes\", $HOME, `rm -rf ~`, 'single', \\ and \u{00E5}\u{00E4}\u{00F6} \u{00C5}\u{00C4}\u{00D6}",
    "$(touch /tmp/embedded-pwned) ; echo done",
    "it's\ttabbed, 100% {braces} [x] *glob* ~ #hash !bang \u{1F680}",
]

private func physical(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Runs the exact login-shell command line, with a fake claude that writes the bytes it was given.
func runLoginShell(script: String, in folder: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: EmbeddedTerminal.shell)
    process.arguments = EmbeddedTerminal.shellArguments(script)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let embeddedTerminalTests: [(name: String, run: () throws -> Void)] = [
    ("the login-shell command hands a hostile prompt to the CLI byte for byte", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-\(UUID().uuidString)", isDirectory: true)
        let work = folder.appendingPathComponent("it's a \"dir\" $HOME", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("argv"), cwd = folder.appendingPathComponent("cwd")
        let cli = folder.appendingPathComponent("claude")
        try "#!/bin/sh\npwd -P > \(GitHubClaude.shellQuote(cwd.path))\nprintf '%s\\n' \"$#\" > \(GitHubClaude.shellQuote(output.path))\nprintf '%s' \"$1\" >> \(GitHubClaude.shellQuote(output.path))\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        for title in hostileTitles {
            let context = GitHubClaude.Context(url: "https://github.com/acme/api/pull/7", repo: "acme/api", number: 7, title: title, base: "develop", head: "NI/x", ticket: "QDLY-1")
            let prompt = GitHubClaude.prompt(.review, context)
            let promptFile = try GitHubClaude.writePromptFile(prompt: prompt, folder: folder.appendingPathComponent("prompts"))
            let script = EmbeddedTerminal.script(directory: work, promptFile: promptFile, cli: cli)
            check(!script.contains(title), "the title is not in the script")
            check(try runLoginShell(script: script, in: folder) == 0, "the command ran")
            check((try? String(contentsOf: output, encoding: .utf8)) == "1\n" + prompt, "one argument, exactly the prompt: \(title)")
            check((try? String(contentsOf: cwd, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == physical(work), "started in the checkout")
            check(!FileManager.default.fileExists(atPath: promptFile.path), "the prompt file removes itself")
        }
        check(!FileManager.default.fileExists(atPath: "/tmp/embedded-pwned"), "nothing in a title was executed")
    }),

    ("a folder that cannot be entered fails instead of running the CLI in the wrong place", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("ran")
        let cli = folder.appendingPathComponent("claude")
        try "#!/bin/sh\ntouch \(GitHubClaude.shellQuote(marker.path))\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let script = EmbeddedTerminal.script(directory: folder.appendingPathComponent("missing"), promptFile: nil, cli: cli)
        check(try runLoginShell(script: script, in: folder) == 1, "exit 1")
        check(!FileManager.default.fileExists(atPath: marker.path), "the CLI did not run")
    }),

    ("the real claude is found and runs through the login shell", {
        guard let cli = ClaudePlugin.findCLI() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: EmbeddedTerminal.shell)
        process.arguments = EmbeddedTerminal.shellArguments(EmbeddedTerminal.script(directory: folder, promptFile: nil, cli: cli, flags: ["--version"]))
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        check(process.terminationStatus == 0, "claude --version exited 0")
        check(text.contains("Claude Code"), "claude answered: \(text)")
    }),

    ("the child gets a colour terminal and a UTF-8 locale that exists", {
        let environment = EmbeddedTerminal.environment(["PATH": "/bin", "LANG": "C", "LC_CTYPE": "C"], locale: Locale(identifier: "sv_SE"),
                                                       localeExists: { $0 == "sv_SE.UTF-8" })
        check(environment.contains("TERM=xterm-256color") && environment.contains("COLORTERM=truecolor"), "terminal")
        check(environment.contains("LANG=sv_SE.UTF-8"), "the user's locale")
        check(environment.contains("PATH=/bin") && !environment.contains { $0.hasPrefix("LC_CTYPE") }, "path kept, LC_CTYPE dropped")
        check(EmbeddedTerminal.lang(current: "en_GB.UTF-8", locale: Locale(identifier: "sv_SE"), exists: { _ in true }) == "en_GB.UTF-8", "a UTF-8 LANG stays")
        check(EmbeddedTerminal.lang(current: nil, locale: Locale(identifier: "en_SE"), exists: { _ in false }) == "en_US.UTF-8", "falls back to a locale that exists")
    }),

    ("the pane goes right in a wide window and below otherwise, and stays inside its limits", {
        check(EmbeddedTerminal.placement(width: 1500) == .right && EmbeddedTerminal.placement(width: 1920) == .right, "wide")
        check(EmbeddedTerminal.placement(width: 1499) == .below && EmbeddedTerminal.placement(width: 700) == .below, "narrow")
        check(EmbeddedTerminal.paneLength(100, placement: .right, available: 1000) == 480, "minimum width")
        check(EmbeddedTerminal.paneLength(2000, placement: .right, available: 1000) == 579, "leaves the page its width and the handle")
        check(EmbeddedTerminal.paneLength(320, placement: .below, available: 760) == 320, "kept")
        check(EmbeddedTerminal.paneLength(600, placement: .below, available: 500) == 299, "leaves the page its height and the handle")
        check(EmbeddedTerminal.fontSize(nil) == 12 && EmbeddedTerminal.fontSize(3) == 9 && EmbeddedTerminal.fontSize(99) == 24, "font size clamps")
    }),

    ("one session per pull request, reattached by its address and counted while running", {
        var registry = TerminalRegistry<FakeSession>()
        let first = registry.attach("a") { FakeSession(true) }
        var made = 0
        check(registry.attach("a") { made += 1; return FakeSession(true) } === first && made == 0, "reattach gives the same session")
        let second = registry.attach("b") { FakeSession(false) }
        check(registry["b"] === second && registry["c"] == nil, "lookup by key")
        check(registry.runningCount(\.running) == 1, "one running")
        second.running = true
        check(registry.runningCount(\.running) == 2, "two running")
        check(registry.remove("a") === first && registry["a"] == nil && registry.runningCount(\.running) == 1, "removed")
        check(registry.remove("a") == nil, "removing twice is harmless")
    }),

    ("quitting asks only while something runs and the setting is on", {
        check(EmbeddedTerminal.quitMessage(running: 0, enabled: true) == nil, "nothing running")
        check(EmbeddedTerminal.quitMessage(running: 2, enabled: false) == nil, "setting off")
        check(EmbeddedTerminal.quitMessage(running: 1, enabled: true) == "Claude is still running in 1 terminal \u{2014} Quit anyway?", "one")
        check(EmbeddedTerminal.quitMessage(running: 3, enabled: true) == "Claude is still running in 3 terminals \u{2014} Quit anyway?", "many")
        check(EmbeddedTerminal.runningText(1) == "1 Claude terminal running" && EmbeddedTerminal.runningText(2) == "2 Claude terminals running", "header text")
    }),

    ("the in-app destination is saved, planned and falls back when it is not available", {
        let dir = URL(fileURLWithPath: "/work/api"), home = URL(fileURLWithPath: "/Users/x"), cli = URL(fileURLWithPath: "/bin/claude")
        check(GitHubClaude.Destination.allCases.first == .inApp && GitHubClaude.Destination.inApp.title == "In this app", "first in the list")
        check(GitHubClaude.Destination.stored("inApp", isAvailable: { _ in true }) == .inApp, "saved choice")
        check(GitHubClaude.Destination.stored("inApp", isAvailable: { $0 != .inApp }) == .terminal, "no terminal view in this build")
        check(GitHubClaude.Destination.stored(nil, isAvailable: { _ in true }) == .terminal && GitHubClaude.Destination.stored("nope", isAvailable: { _ in true }) == .terminal, "default Terminal")
        check(GitHubClaude.Destination.stored("warp", isAvailable: { $0 != .warp }) == .terminal, "an app that is gone")
        check(GitHubClaude.plan(.inApp, cli: cli, checkout: dir, home: home, prompt: "p") { _ in false } == .embedded(directory: dir, cli: cli), "in the checkout")
        check(GitHubClaude.plan(.inApp, cli: cli, checkout: nil, home: home, prompt: "p") { _ in false } == .embedded(directory: home, cli: cli), "home without one")
        check(GitHubClaude.plan(.inApp, cli: nil, checkout: dir, home: home, prompt: "p") { _ in true } == .cliMissing, "no CLI")
    }),

    ("both palettes define every colour the terminal needs", {
        for palette in [EmbeddedTerminal.light, EmbeddedTerminal.dark] {
            check(palette.ansi.count == 16 && Set(palette.ansi).count == 16, "16 distinct ANSI colours")
            check(palette.foreground != palette.background, "text differs from the background")
        }
        check(EmbeddedTerminal.light.background != EmbeddedTerminal.dark.background, "the two differ")
    }),
]
