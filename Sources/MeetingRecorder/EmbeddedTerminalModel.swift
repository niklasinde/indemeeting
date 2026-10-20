import AppKit
import Combine
import SwiftUI

#if canImport(SwiftTerm)
import SwiftTerm

/// SwiftTerm's view, with the keys of a terminal app: copy, paste, clear and the font size, taken only while it has the keyboard.
final class ClaudeTerminalView: LocalProcessTerminalView {
    var fontStep: ((Int) -> Void)?
    private var appliedPalette: EmbeddedTerminal.Palette?

    /// Handles a key pressed while this view has the keyboard; false leaves it to the terminal and the menu.
    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "t" {
            Self.swallowKeyUp = true
            EmbeddedTerminalModel.shared.toggleFocus?()
            return true
        }
        guard modifiers.subtracting(.shift) == .command, let key = event.charactersIgnoringModifiers else { return false }
        switch key {
        case "c": copySelection()
        case "v": paste(self)
        case "k": clear()
        case "+", "=": fontStep?(1)
        case "-": fontStep?(-1)
        case "0": fontStep?(0)
        default: return false
        }
        return true
    }

    /// The release of the shortcut that gave the keyboard back must not reach the page it was given to.
    private static var swallowKeyUp = false

    /// One monitor for all terminals: it sees the key before the menu does, and only acts when a terminal is the first responder.
    static let keyMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
        if event.type == .keyUp { return swallowKeyUp && { swallowKeyUp = false; return true }() ? nil : event }
        return (event.window?.firstResponder as? ClaudeTerminalView)?.handle(event) == true ? nil : event
    }

    private func copySelection() {
        let board = NSPasteboard.general
        let before = board.string(forType: .string)
        copy(self)
        if board.string(forType: .string)?.isEmpty ?? true, let before {
            board.clearContents()
            board.setString(before, forType: .string)
        }
    }

    func clear() { feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J") }

    var allOutput: String { String(decoding: getBufferAsData(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

    func apply(_ palette: EmbeddedTerminal.Palette) {
        guard palette != appliedPalette else { return }
        appliedPalette = palette
        func color(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        installColors(palette.ansi.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 0xFF), green8: UInt16($0 >> 8 & 0xFF), blue8: UInt16($0 & 0xFF)) })
        nativeForegroundColor = color(palette.foreground)
        nativeBackgroundColor = color(palette.background)
        caretColor = color(palette.caret)
        selectedTextBackgroundColor = color(palette.selection)
    }
}

/// One Claude session in a terminal of its own: the view, its process and what to start again with. Lives until it is closed, so
/// the scrollback stays while another pull request is selected.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        case idle
        case running
        case exited(Int32?)
        case unavailable(String, copy: String?)
    }

    static let stopGrace: TimeInterval = 3
    static let killGrace: TimeInterval = 1.5

    let key: String
    let title: String
    let directory: URL
    let hint: GitHubClaudeModel.Note?
    let preset: GitHubClaude.Preset?
    /// The saved session this one picks up, when it does; then the prompt is not sent again.
    let resume: GitHubClaude.Resume?
    let view = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    @Published private(set) var state = State.idle
    @Published private(set) var programTitle = ""
    private(set) var startedAt = Date.distantPast
    let prompt: String
    let cli: URL?
    private var restarting = false

    var isRunning: Bool { state == .running }

    init(key: String, title: String, directory: URL, prompt: String, cli: URL?, hint: GitHubClaudeModel.Note?,
         preset: GitHubClaude.Preset?, resume: GitHubClaude.Resume?) {
        self.key = key
        self.title = title
        self.directory = directory
        self.prompt = prompt
        self.cli = cli
        self.hint = hint
        self.preset = preset
        self.resume = resume
        super.init()
        view.processDelegate = self
        view.fontStep = { Self.stepFont($0) }
        _ = ClaudeTerminalView.keyMonitor
        if cli == nil {
            state = .unavailable("The Claude CLI was not found. Install it with npm install -g @anthropic-ai/claude-code.",
                                 copy: "npm install -g @anthropic-ai/claude-code")
        }
    }

    static func stepFont(_ step: Int) {
        let stored = UserDefaults.standard.object(forKey: EmbeddedTerminal.fontSizeKey) as? Double
        let size = step == 0 ? EmbeddedTerminal.defaultFontSize : EmbeddedTerminal.fontSize((stored ?? EmbeddedTerminal.defaultFontSize) + Double(step))
        UserDefaults.standard.set(size, forKey: EmbeddedTerminal.fontSizeKey)
    }

    func start() {
        guard let cli, !isRunning else { return }
        do {
            let script: String
            if let resume {
                script = EmbeddedTerminal.script(directory: directory, promptFile: nil, cli: cli, flags: resume.flags)
            } else {
                let file = try GitHubClaude.writePromptFile(prompt: prompt, folder: GitHubClaude.promptFolder())
                script = EmbeddedTerminal.script(directory: directory, promptFile: file, cli: cli)
            }
            startedAt = Date()
            view.startProcess(executable: EmbeddedTerminal.shell, args: EmbeddedTerminal.shellArguments(script),
                              environment: EmbeddedTerminal.environment(ClaudePluginModel.environment(for: cli)), currentDirectory: directory.path)
            state = .running
        } catch {
            state = .unavailable("Could not start Claude: \(error.localizedDescription)", copy: nil)
        }
    }

    func restart() {
        guard isRunning else { return start() }
        restarting = true
        terminateTree()
    }

    /// Ctrl-C for the whole process group, and the same as Close if Claude is still there after a few seconds.
    func stop() {
        guard let pid = livePID else { return }
        let tree = ClaudeProcess.descendants(of: pid)
        killpg(pid, SIGINT)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopGrace) { [weak self] in
            guard let self else { return }
            if self.livePID == pid { self.terminateTree() } else { Self.kill(tree, SIGKILL) }
        }
    }

    /// SIGHUP to the process group and to everything that left it, SIGKILL for what is still there a moment later, even when the
    /// group leader itself is already gone.
    func terminateTree() {
        guard let pid = livePID else { return }
        let tree = ClaudeProcess.descendants(of: pid)
        killpg(pid, SIGHUP)
        Self.kill(tree, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace) { [weak self] in
            if self?.livePID == pid { killpg(pid, SIGKILL) }
            Self.kill(tree, SIGKILL)
        }
    }

    /// For quitting: no time to wait, so a short grace and then SIGKILL.
    func terminateNow() {
        guard let pid = livePID else { return }
        let tree = ClaudeProcess.descendants(of: pid)
        killpg(pid, SIGHUP)
        Self.kill(tree, SIGHUP)
        usleep(300_000)
        killpg(pid, SIGKILL)
        Self.kill(tree, SIGKILL)
    }

    private static func kill(_ pids: [pid_t], _ signal: Int32) {
        pids.forEach { Darwin.kill($0, signal) }
    }

    private var livePID: pid_t? {
        let pid = view.process.shellPid
        return pid > 0 && view.process.running ? pid : nil
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { programTitle = title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            state = .exited(exitCode)
            guard restarting else { return }
            restarting = false
            view.feed(text: "\u{1B}c")
            start()
        }
    }

    nonisolated func processFailedToStart(source: LocalProcessTerminalView, error: LocalProcessError) {
        MainActor.assumeIsolated { state = .unavailable("Could not start Claude: \(error)", copy: nil) }
    }
}

/// The sessions, one per pull request, whichever pull request is on screen.
@MainActor
final class EmbeddedTerminalModel: ObservableObject {
    static let shared = EmbeddedTerminalModel()
    static let available = true
    /// Set by the page: called when a terminal that has the keyboard sees the shortcut for giving it back (the page's own shortcut
    /// does not reach a key pressed inside the terminal).
    var toggleFocus: (() -> Void)?

    @Published private(set) var registry = TerminalRegistry<TerminalSession>()
    @Published private(set) var hidden: Set<String> = []
    private var watching: [String: AnyCancellable] = [:]

    func session(for key: String) -> TerminalSession? { registry[key] }

    func hasSession(_ key: String) -> Bool { registry[key] != nil }

    var runningCount: Int { registry.runningCount(\.isRunning) }

    func isRunning(_ key: String) -> Bool { registry[key]?.isRunning ?? false }

    func isShown(_ key: String) -> Bool { registry[key] != nil && !hidden.contains(key) }

    func terminalHasFocus(_ key: String) -> Bool {
        guard let view = registry[key]?.view else { return false }
        return view.window?.firstResponder === view
    }

    func releaseTerminal(_ key: String) {
        guard let view = registry[key]?.view else { return }
        view.window?.makeFirstResponder(nil)
    }

    /// Gives the keyboard to the pull request's terminal; false when it has none on screen.
    func focusTerminal(_ key: String) -> Bool {
        guard isShown(key), let view = registry[key]?.view, let window = view.window else { return false }
        return window.makeFirstResponder(view)
    }

    func setShown(_ key: String, _ shown: Bool) {
        if shown { hidden.remove(key) } else { hidden.insert(key) }
    }

    /// Opens the pull request's terminal and starts Claude in it. When Claude already runs there, that session is shown instead of a second one.
    func open(_ key: String, title: String, directory: URL, prompt: String, cli: URL?, hint: GitHubClaudeModel.Note?,
              preset: GitHubClaude.Preset? = nil, resume: GitHubClaude.Resume? = nil) {
        hidden.remove(key)
        if isRunning(key) { return }
        close(key)
        let session = registry.attach(key) {
            TerminalSession(key: key, title: title, directory: directory, prompt: prompt, cli: cli, hint: hint, preset: preset, resume: resume)
        }
        watching[key] = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        session.start()
    }

    /// Ends the pull request's session and starts Claude again in the same folder with the same prompt, without the saved session.
    func startNew(_ key: String) {
        guard let old = registry[key] else { return }
        close(key)
        open(key, title: old.title, directory: old.directory, prompt: old.prompt, cli: old.cli, hint: nil, preset: old.preset)
    }

    /// When the pull request's Claude started, while it runs there; nil when nothing runs.
    func runningSince(_ key: String) -> Date? {
        registry[key].flatMap { $0.isRunning ? $0.startedAt : nil }
    }

    func close(_ key: String) {
        registry[key]?.terminateTree()
        registry.remove(key)
        watching[key] = nil
        hidden.remove(key)
    }

    func terminateAll() {
        registry.sessions.values.forEach { $0.terminateNow() }
    }

    func quitMessage(enabled: Bool = UserDefaults.standard.object(forKey: EmbeddedTerminal.confirmQuitKey) as? Bool ?? true) -> String? {
        EmbeddedTerminal.quitMessage(running: runningCount, enabled: enabled)
    }

    #if DEBUG
    /// A session that shows canned output instead of running anything.
    func showSample(_ key: String, title: String, directory: URL, output: String, running: Bool, hint: GitHubClaudeModel.Note? = nil) {
        close(key)
        let session = registry.attach(key) {
            TerminalSession(key: key, title: title, directory: directory, prompt: "", cli: nil, hint: hint, preset: nil, resume: nil)
        }
        session.showSample(output: output, running: running)
        watching[key] = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        objectWillChange.send()
    }
    #endif
}

#if DEBUG
extension TerminalSession {
    func showSample(output: String, running: Bool) {
        view.feed(text: output)
        state = running ? .running : .exited(0)
    }
}
#endif

#else

/// Without SwiftTerm (the swiftc fallback build) there is no embedded terminal.
@MainActor
final class EmbeddedTerminalModel: ObservableObject {
    static let shared = EmbeddedTerminalModel()
    static let available = false
    var toggleFocus: (() -> Void)?
    var runningCount: Int { 0 }
    func hasSession(_ key: String) -> Bool { false }
    func isRunning(_ key: String) -> Bool { false }
    func isShown(_ key: String) -> Bool { false }
    func terminalHasFocus(_ key: String) -> Bool { false }
    func releaseTerminal(_ key: String) {}
    func focusTerminal(_ key: String) -> Bool { false }
    func setShown(_ key: String, _ shown: Bool) {}
    func open(_ key: String, title: String, directory: URL, prompt: String, cli: URL?, hint: GitHubClaudeModel.Note?,
              preset: GitHubClaude.Preset? = nil, resume: GitHubClaude.Resume? = nil) {}
    func startNew(_ key: String) {}
    func runningSince(_ key: String) -> Date? { nil }
    func close(_ key: String) {}
    func terminateAll() {}
    func quitMessage(enabled: Bool = true) -> String? { nil }
}

#endif
