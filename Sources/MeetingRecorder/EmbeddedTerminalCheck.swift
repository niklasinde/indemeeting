#if DEBUG && canImport(SwiftTerm)
import AppKit
import SwiftUI

/// The agent's session cannot activate the app, so the window is made to report itself as the key window for the key tests.
private final class AlwaysKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// Debug builds only: `MeetingRecorder --render-github <folder> --terminal-check` renders the pull request page with the embedded
/// terminal (canned output) in both layouts and appearances, then drives real sessions against a fake `claude` to check keyboard
/// focus, resizing and that closing leaves no process behind. Never starts the real claude.
@MainActor
enum TerminalCheck {
    private static let canned = [
        "\u{1B}[1m\u{1B}[38;5;173m\u{273B} Claude Code\u{1B}[0m  \u{1B}[2m~/git/acme/finq.api\u{1B}[0m",
        "",
        "\u{1B}[2m>\u{1B}[0m Review this pull request. Work read-only.",
        "",
        "\u{1B}[32m\u{25CF}\u{1B}[0m Reading the diff: \u{1B}[1mgh pr diff 2442\u{1B}[0m",
        "  \u{1B}[2m\u{23BF}\u{1B}[0m  \u{1B}[32m+ if not setting(\"strawbay_send\"):\u{1B}[0m",
        "     \u{1B}[31m- return send(batch)\u{1B}[0m",
        "",
        "\u{1B}[33m\u{25CF}\u{1B}[0m The guard skips the log line (\u{1B}[4msending.py:41\u{1B}[0m). \u{00C5}\u{00C4}\u{00D6} \u{00E5}\u{00E4}\u{00F6}",
        "",
        "\u{1B}[1;34mDo you want to proceed?\u{1B}[0m  \u{1B}[7m 1. Yes \u{1B}[0m  2. No",
    ].joined(separator: "\r\n") + "\r\n"

    private static var failures = 0

    static func run(window: NSWindow, model: GitHubModel, directory: TicketDirectory, output: URL) async {
        let prs = GitHubPreview.samples[.created] ?? []
        let detail = GitHubPreview.detailSamples[0].detail
        model.showSample(prs: GitHubPreview.samples, directory: directory)
        model.showSample(selecting: prs[1], detail: detail)
        let terminals = EmbeddedTerminalModel.shared
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("git/acme/finq.api")
        terminals.showSample(prs[1].url, title: "Review \u{00B7} finq.api #2442", directory: home, output: canned, running: true)
        terminals.showSample(prs[2].url, title: "Failing checks \u{00B7} finq.api #2460", directory: home, output: canned, running: false)
        window.setFrameOrigin(NSPoint(x: 0, y: 40))
        window.makeKeyAndOrderFront(nil)
        for (name, size) in [("1440", NSSize(width: 1440, height: 900)), ("1728", NSSize(width: 1728, height: 960)),
                             ("2048", NSSize(width: 2048, height: 1080)), ("2560", NSSize(width: 2560, height: 1300)),
                             ("780", NSSize(width: 780, height: 760))] {
            window.setContentSize(size)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                PreviewRenderer.save(window, to: output.appendingPathComponent("terminal-\(name)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        terminals.close(prs[1].url)
        terminals.close(prs[2].url)
        await live(window: window, model: model, prs: prs, detail: detail, output: output)
    }

    // MARK: Live

    private static func report(_ ok: Bool, _ text: String) {
        if !ok { failures += 1 }
        print("\(ok ? "OK  " : "FAIL") \(text)")
    }

    private static func wait(_ seconds: Double = 8, until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private static func press(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private static func type(_ text: String, in window: NSWindow) async {
        for character in text {
            let codes: [Character: UInt16] = ["\r": 36, "h": 4, "e": 14, "l": 37, "o": 31, "z": 6, "s": 1, "i": 34]
            await press(String(character), code: codes[character] ?? 0, in: window)
        }
    }

    private static func processes(_ pattern: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pgid=,stat=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.split(separator: "\n").map(String.init).filter { $0.range(of: pattern, options: .regularExpression) != nil && !$0.contains("/bin/ps") }
    }

    private static func live(window: NSWindow, model: GitHubModel, prs: [GitHubPR], detail: GitHubPRDetail, output: URL) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tc-fake-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            printf 'PROMPT:%s\\n' "$1"
            sleep 7311 &
            ( sleep 7312 ) &
            perl -e 'use POSIX; setsid(); $SIG{INT}="IGNORE"; $SIG{HUP}="IGNORE"; $SIG{TERM}="IGNORE"; sleep 7313' &
            printf 'ready\\n'
            while IFS= read -r line; do
              case "$line" in size) printf 'SIZE:%s\\n' "$(stty size)";; *) printf 'got:%s\\n' "$line";; esac
            done
            """
        try? script.write(to: cli, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let pattern = "^ *[0-9]+ +[0-9]+ +[0-9]+ +\\S+ +(/bin/sh [^ ]*tc-fake|sleep 731[123]|perl -e use POSIX)"
        let terminals = EmbeddedTerminalModel.shared
        let a = prs[1], b = prs[2]
        let prompt = "a\"$HOME`x`'y'\u{00E5}\u{00E4}\u{00F6}"
        window.setContentSize(NSSize(width: 1800, height: 900))
        window.orderOut(nil)
        window.contentViewController = nil
        let window = AlwaysKeyWindow(contentViewController: NSHostingController(rootView: GitHubView(model: model)))
        window.setContentSize(NSSize(width: 1800, height: 900))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        model.showSample(selecting: a, detail: detail)
        try? await Task.sleep(nanoseconds: 500_000_000)
        terminals.open(a.url, title: "Review", directory: folder, prompt: prompt, cli: cli, hint: nil)
        let session = terminals.session(for: a.url)!
        report(await wait { session.view.allOutput.contains("ready") }, "session starts only on open, shows the prompt line: \(session.view.allOutput.split(separator: "\n").first ?? "")")
        report(session.view.allOutput.contains("PROMPT:" + prompt), "the hostile prompt reached the program through the terminal")
        report(terminals.runningCount == 1 && terminals.isRunning(a.url) && !terminals.isRunning(b.url), "running count 1, dot only for the started pull request")
        print("ps with one session:"); processes(pattern).forEach { print("  " + $0) }

        // The terminal takes keys only when it is the first responder.
        let startSelection = model.selectedURL
        await press("t", code: 17, flags: [.command, .option], in: window)
        let focused = await wait(2) { terminals.terminalHasFocus(a.url) }
        report(focused, "Cmd-Opt-T gives the terminal the keyboard")
        await press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, in: window)
        report(model.selectedURL == startSelection, "Down arrow in the terminal does not move the list selection")
        report(await wait(2) { session.view.allOutput.contains("^[[B") || session.view.allOutput.contains("^[OB") }, "Down arrow reached the program")
        await type("hello\r", in: window)
        report(await wait(3) { session.view.allOutput.contains("hello") && session.view.allOutput.contains("got:") }, "typed text reaches the program only while focused")
        await press("t", code: 17, flags: [.command, .option], in: window)
        report(await wait(2) { !terminals.terminalHasFocus(a.url) }, "Cmd-Opt-T again takes the keyboard back")
        try? await Task.sleep(nanoseconds: 600_000_000)
        await type("zz\r", in: window)
        report(!session.view.allOutput.contains("zz"), "typing while the list has the keyboard does not reach the terminal")
        await press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, in: window)
        print((model.selectedURL != startSelection ? "OK  " : "INFO") + " Down arrow in the list moves the selection (\(model.selectedURL.map { String($0.suffix(5)) } ?? "nil"))")
        report(terminals.isRunning(a.url), "the first session keeps running while another pull request is selected")

        // Keys and resizing while focused.
        model.showSample(selecting: a, detail: detail)
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = terminals.focusTerminal(a.url)
        _ = await wait(2) { terminals.terminalHasFocus(a.url) }
        let sizeBefore = UserDefaults.standard.double(forKey: EmbeddedTerminal.fontSizeKey)
        await press("=", code: 24, flags: .command, in: window)
        let sizeAfter = UserDefaults.standard.double(forKey: EmbeddedTerminal.fontSizeKey)
        report(sizeAfter == EmbeddedTerminal.fontSize(sizeBefore == 0 ? EmbeddedTerminal.defaultFontSize : sizeBefore + 1), "Cmd-+ grows the font (\(sizeBefore) -> \(sizeAfter))")
        await press("0", code: 29, flags: .command, in: window)
        report(UserDefaults.standard.double(forKey: EmbeddedTerminal.fontSizeKey) == EmbeddedTerminal.defaultFontSize, "Cmd-0 resets it")
        await press("k", code: 40, flags: .command, in: window)
        report(await wait(2) { !session.view.allOutput.contains("PROMPT:") }, "Cmd-K clears the screen")
        await type("size\r", in: window)
        _ = await wait(3) { session.view.allOutput.contains("SIZE:") }
        let before = session.view.allOutput.components(separatedBy: "SIZE:").last?.prefix(8) ?? ""
        window.setContentSize(NSSize(width: 1700, height: 760))
        try? await Task.sleep(nanoseconds: 800_000_000)
        await type("size\r", in: window)
        _ = await wait(3) { session.view.allOutput.components(separatedBy: "SIZE:").count > 2 }
        let after = session.view.allOutput.components(separatedBy: "SIZE:").last?.prefix(8) ?? ""
        report(before != after && !before.isEmpty, "resizing reaches the program (SIGWINCH): \(before.split(separator: "\n").first ?? "") -> \(after.split(separator: "\n").first ?? "")")

        // Second session, reattach, scrollback.
        terminals.open(b.url, title: "Review B", directory: folder, prompt: "second", cli: cli, hint: nil)
        report(await wait { terminals.runningCount == 2 }, "two sessions run side by side")
        report(terminals.session(for: a.url)?.view === session.view, "the first session's terminal view is the same object (scrollback kept)")
        report(session.view.allOutput.contains("SIZE:"), "its scrollback is retained")
        print("ps with two sessions:"); processes(pattern).forEach { print("  " + $0) }

        // Stop, restart, close.
        let pidBefore = session.view.process.shellPid
        session.stop()
        report(await wait(6) { !session.isRunning }, "Stop ends the session (Ctrl-C, then SIGHUP/SIGKILL for what ignores it)")
        report(await wait(4) { processes("^ *[0-9]+ +[0-9]+ +[0-9]+ +\\S+ +(sleep 731[123]|perl -e use POSIX)").filter { !$0.contains(" Z") }.count == 3 }, "only the second session's two sleeps and perl remain after Stop of the first: \(processes("^ *[0-9]+ +[0-9]+ +[0-9]+ +\\S+ +(sleep 731[123]|perl -e use POSIX)").count) lines")
        session.restart()
        report(await wait { session.isRunning && session.view.process.shellPid != pidBefore && session.view.allOutput.contains("ready") }, "Restart starts a fresh process")
        terminals.close(a.url)
        terminals.close(b.url)
        report(await wait(6) { processes(pattern).isEmpty }, "Close leaves no process of either session behind")
        print("ps after closing:"); processes(pattern).forEach { print("  " + $0) }
        let zombies = processes("^ *[0-9]+ +[0-9]+ +[0-9]+ +\\S+ +/bin/sh [^ ]*tc-fake").filter { $0.split(separator: " ").dropFirst(3).first?.hasPrefix("Z") == true }
        report(zombies.isEmpty, "no zombie left")

        // Quit path.
        terminals.open(a.url, title: "Review", directory: folder, prompt: "quit", cli: cli, hint: nil)
        report(await wait { terminals.session(for: a.url)?.view.allOutput.contains("ready") == true }, "a session for the quit check")
        report(terminals.quitMessage(enabled: true) == "Claude is still running in 1 terminal \u{2014} Quit anyway?", "quit asks while Claude runs")
        let started = Date()
        terminals.terminateAll()
        report(await wait(3) { processes(pattern).isEmpty }, "terminateAll (quit) removes everything in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        terminals.close(a.url)
        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
    }
}
#endif
