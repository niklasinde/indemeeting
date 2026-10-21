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
        check(environment.contains("CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"), "transcripts are kept")
        check(EmbeddedTerminal.lang(current: "en_GB.UTF-8", locale: Locale(identifier: "sv_SE"), exists: { _ in true }) == "en_GB.UTF-8", "a UTF-8 LANG stays")
        check(EmbeddedTerminal.lang(current: nil, locale: Locale(identifier: "en_SE"), exists: { _ in false }) == "en_US.UTF-8", "falls back to a locale that exists")
    }),

    ("the pane goes right in a wide window and below otherwise, and stays inside its limits", {
        check(EmbeddedTerminal.placement(width: 1500) == .right && EmbeddedTerminal.placement(width: 1920) == .right, "wide")
        check(EmbeddedTerminal.placement(width: 1499) == .below && EmbeddedTerminal.placement(width: 700) == .below, "narrow")
        check(EmbeddedTerminal.paneLength(100, placement: .right, available: 1000) == 480, "minimum width")
        check(EmbeddedTerminal.paneLength(2000, placement: .right, available: 1000) == 519, "leaves the page its width and the handle")
        check(EmbeddedTerminal.paneLength(320, placement: .below, available: 760) == 320, "kept")
        check(EmbeddedTerminal.paneLength(600, placement: .below, available: 500) == 299, "leaves the page its height and the handle")
        check(EmbeddedTerminal.fontSize(nil) == 13 && EmbeddedTerminal.fontSize(3) == 9 && EmbeddedTerminal.fontSize(99) == 24, "font size clamps")
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

    ("the colours sit on the page's surface and stay readable on light and dark", {
        for surface in [0xFFFFFF, 0xECECEC, 0xF5F5F7, 0x000000, 0x1E1E1E, 0x282828, 0x2C2C2E] {
            for accent in [0x007AFF, 0x0A84FF] {
                let palette = EmbeddedTerminal.palette(surface: UInt32(surface), accent: UInt32(accent))
                let name = String(surface, radix: 16) + "/" + String(accent, radix: 16)
                check(palette.background == UInt32(surface), "the background is the surface \(name)")
                check(EmbeddedTerminal.contrast(palette.foreground, palette.background) >= 7, "body text 7:1 \(name)")
                check(EmbeddedTerminal.contrast(palette.foreground, palette.selection) >= 4.5, "text on the selection 4.5:1 \(name)")
                check(palette.ansi.count == 16 && palette.ansi.allSatisfy { EmbeddedTerminal.contrast($0, palette.background) >= 4.5 }, "ANSI 4.5:1 \(name)")
                check(EmbeddedTerminal.contrast(palette.caret, palette.background) >= 3, "caret 3:1 \(name)")
                let darkSurface = EmbeddedTerminal.luminance(UInt32(surface)) < 0.5
                check((EmbeddedTerminal.luminance(palette.foreground) > EmbeddedTerminal.luminance(palette.background)) == darkSurface, "text contrasts the surface \(name)")
            }
        }
        let dark = EmbeddedTerminal.palette(surface: 0x1E1E1E, accent: 0x0A84FF)
        check(dark.foreground == 0xE6E6E6 && dark.caret == 0x0A84FF, "readable colours are kept as they are")
        check(EmbeddedTerminal.readable(0x777777, on: 0xFFFFFF, minimum: 4.5) != 0x777777 && EmbeddedTerminal.readable(0x000000, on: 0xFFFFFF, minimum: 4.5) == 0x000000, "only what must move moves")
    }),

    ("the font is SF Mono, then Menlo, at 13 pt with 1.2 line spacing", {
        check(EmbeddedTerminal.fontName { _ in true } == "SFMono-Regular", "SF Mono first")
        check(EmbeddedTerminal.fontName { $0 == "Menlo-Regular" } == "Menlo-Regular", "Menlo when SF Mono is missing")
        check(EmbeddedTerminal.fontName { _ in false } == nil, "system monospace when neither is there")
        check(EmbeddedTerminal.defaultFontSize == 13 && EmbeddedTerminal.lineSpacing == 1.2, "size and spacing")
    }),

    ("the font size is saved, steps with the keys and stays inside its limits", {
        let suite = "embedded-font-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "a defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        check(EmbeddedTerminal.steppedFontSize(1, defaults: defaults) == 14, "one larger from the default")
        check(defaults.double(forKey: EmbeddedTerminal.fontSizeKey) == 14, "saved")
        check(EmbeddedTerminal.steppedFontSize(1, defaults: defaults) == 15, "kept on the next step")
        check(EmbeddedTerminal.steppedFontSize(0, defaults: defaults) == 13 && defaults.double(forKey: EmbeddedTerminal.fontSizeKey) == 13, "Cmd-0 resets")
        check(EmbeddedTerminal.steppedFontSize(50, defaults: defaults) == 24, "largest")
        check(EmbeddedTerminal.steppedFontSize(-50, defaults: defaults) == 9, "smallest")
    }),

    ("the scrollback keeps ten thousand lines", {
        check(EmbeddedTerminal.scrollbackLines == 10_000, "10,000 lines")
    }),

    ("the status dot is green while output is fresh, grey when quiet and red once ended", {
        let now = Date()
        check(EmbeddedTerminal.activity(running: true, ended: false, lastOutput: now.addingTimeInterval(-1), now: now) == .working, "output a second ago")
        check(EmbeddedTerminal.activity(running: true, ended: false, lastOutput: now.addingTimeInterval(-3), now: now) == .idle, "quiet for the window")
        check(EmbeddedTerminal.activity(running: true, ended: false, lastOutput: nil, now: now) == .idle, "running with no output yet")
        check(EmbeddedTerminal.activity(running: false, ended: false, lastOutput: nil, now: now) == .idle, "not started")
        check(EmbeddedTerminal.activity(running: false, ended: true, lastOutput: now, now: now) == .ended, "ended, even with recent output")
    }),

    ("a notice shows once per session until it is dismissed, and the safety note stops when asked", {
        let hint = EmbeddedTerminal.Notice(id: "hint", symbol: "info.circle", text: "Install it", copy: "npm install")
        guard let safety = EmbeddedTerminal.safetyNotice(directory: "~/git/api", neverAgain: false, running: true) else { return check(false, "safety note while running") }
        check(EmbeddedTerminal.currentNotice([hint, safety], dismissed: []) == hint, "the first one first")
        check(EmbeddedTerminal.currentNotice([hint, safety], dismissed: ["hint"]) == safety, "then the next")
        check(EmbeddedTerminal.currentNotice([hint, safety], dismissed: ["hint", "safety"]) == nil, "nothing once all are dismissed")
        check(safety.text == "Interactive Claude can change files in ~/git/api \u{2014} it asks first.", "the safety text")
        check(EmbeddedTerminal.safetyNotice(directory: "~/git/api", neverAgain: false, running: false) == nil, "not while nothing runs")
        check(EmbeddedTerminal.safetyNotice(directory: "~/git/api", neverAgain: true, running: true) == nil, "Don't show again")
    }),

    ("the header names the pull request by owner, repository and number", {
        check(EmbeddedTerminal.pullRequestLabel("https://github.com/acme/api/pull/7") == "acme/api #7", "a pull request")
        check(EmbeddedTerminal.pullRequestLabel("https://github.com/acme/api/issues/7") == nil, "an issue")
        check(EmbeddedTerminal.pullRequestLabel("not a url") == nil, "no address")
    }),
]
