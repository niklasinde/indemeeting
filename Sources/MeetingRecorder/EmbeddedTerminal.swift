import Foundation

/// The pure parts of the embedded Claude terminal: the login-shell command, the environment, where the pane goes, when to ask before
/// quitting, and the colours. Tested; the SwiftTerm view and the processes live in EmbeddedTerminalModel.swift.
enum EmbeddedTerminal {
    static let fontSizeKey = "embeddedTerminalFontSize"
    static let confirmQuitKey = "embeddedTerminalConfirmQuit"
    static let noteHiddenKey = "embeddedTerminalNoteHidden"
    static let rightSizeKey = "embeddedTerminalRightWidth"
    static let belowSizeKey = "embeddedTerminalBelowHeight"

    static let shell = "/bin/zsh"

    // MARK: Command

    /// Runs the CLI in the checkout through a login shell, so PATH and auth are the ones of the user's Terminal. The prompt is read
    /// from its file and the file removed at once, so no title or comment is ever part of the script's own text.
    static func script(directory: URL, promptFile: URL?, cli: URL, flags: [String] = []) -> String {
        var lines = ["cd \(GitHubClaude.shellQuote(directory.path)) || exit 1"]
        if let promptFile {
            lines.append("prompt=$(cat \(GitHubClaude.shellQuote(promptFile.path)))")
            lines.append("rm -f -- \(GitHubClaude.shellQuote(promptFile.path))")
        }
        lines.append("export PATH=\(GitHubClaude.shellQuote(cli.deletingLastPathComponent().path)):\"$PATH\"")
        let words = [GitHubClaude.shellQuote(cli.path)] + flags.map(GitHubClaude.shellQuote) + (promptFile == nil ? [] : ["\"$prompt\""])
        lines.append("exec " + words.joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    static func shellArguments(_ script: String) -> [String] { ["-l", "-c", script] }

    /// `KEY=value` strings for the child: the given environment with a terminal that can show colours and UTF-8.
    static func environment(_ base: [String: String], locale: Locale = .current,
                            localeExists: (String) -> Bool = { FileManager.default.fileExists(atPath: "/usr/share/locale/" + $0) }) -> [String] {
        var environment = base
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = lang(current: base["LANG"], locale: locale, exists: localeExists)
        environment["LC_CTYPE"] = nil
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    static func lang(current: String?, locale: Locale, exists: (String) -> Bool) -> String {
        if let current, current.uppercased().contains("UTF-8") || current.uppercased().contains("UTF8") { return current }
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
            let candidate = "\(language)_\(region).UTF-8"
            if exists(candidate) { return candidate }
        }
        return "en_US.UTF-8"
    }

    // MARK: Layout

    enum Placement: Equatable { case right, below }

    static let rightFromWidth = 1500.0
    static let rightRange = 480.0...720.0
    static let belowRange = 160.0...700.0
    static let minimumPageWidth = 420.0
    static let minimumPageHeight = 200.0
    static let defaultRight = 560.0
    static let defaultBelow = 320.0

    static func placement(width: Double) -> Placement { width >= rightFromWidth ? .right : .below }

    /// The pane's width or height, kept inside its range and leaving room for the page it sits next to.
    static func paneLength(_ stored: Double, placement: Placement, available: Double) -> Double {
        switch placement {
        case .right: return min(max(stored, rightRange.lowerBound), min(rightRange.upperBound, available - minimumPageWidth))
        case .below: return min(max(stored, belowRange.lowerBound), min(belowRange.upperBound, available - minimumPageHeight))
        }
    }

    // MARK: Font

    static let fontSizes = 9.0...24.0
    static let defaultFontSize = 12.0

    static func fontSize(_ stored: Double?) -> Double {
        min(max(stored ?? defaultFontSize, fontSizes.lowerBound), fontSizes.upperBound)
    }

    // MARK: Messages

    /// Nil when nothing is running; otherwise what to ask before quitting.
    static func quitMessage(running: Int, enabled: Bool) -> String? {
        guard enabled, running > 0 else { return nil }
        return "Claude is still running in \(running) terminal\(running == 1 ? "" : "s") \u{2014} Quit anyway?"
    }

    static func runningText(_ count: Int) -> String { "\(count) Claude terminal\(count == 1 ? "" : "s") running" }

    static func safetyNote(directory: String) -> String { "Interactive Claude can change files in \(directory) \u{2014} it asks first." }

    // MARK: Colours

    struct Palette: Equatable {
        let foreground: UInt32
        let background: UInt32
        let caret: UInt32
        let selection: UInt32
        let ansi: [UInt32]
    }

    static let light = Palette(foreground: 0x1D1D1F, background: 0xFBFBFA, caret: 0x1D1D1F, selection: 0xB5D5FF,
                               ansi: [0x1D1D1F, 0xC4271C, 0x1F7A3A, 0x946200, 0x1D5FC4, 0x9A3FA6, 0x0F7F8A, 0x6E6E73,
                                      0x8E8E93, 0xE0392B, 0x2E9D4F, 0xB57B00, 0x3A7BE0, 0xB352C0, 0x1A9AA6, 0x3A3A3C])

    static let dark = Palette(foreground: 0xE6E6E6, background: 0x1C1C1E, caret: 0xE6E6E6, selection: 0x3E5C8A,
                              ansi: [0x1C1C1E, 0xFF6B60, 0x5FD07A, 0xE5B84B, 0x6EA8FF, 0xD28CE0, 0x5CC8D2, 0xC7C7CC,
                                     0x6E6E73, 0xFF8A80, 0x7FE59A, 0xF2CB6B, 0x8FBFFF, 0xE3A6EE, 0x7FDDE6, 0xFFFFFF])
}

/// One session per key, reattached by the same key. Pure over its session type so the rules are tested without a terminal.
struct TerminalRegistry<Session: AnyObject> {
    private(set) var sessions: [String: Session] = [:]

    subscript(key: String) -> Session? { sessions[key] }

    /// The session for the key, made by `create` only when there is none.
    mutating func attach(_ key: String, create: () -> Session) -> Session {
        if let existing = sessions[key] { return existing }
        let session = create()
        sessions[key] = session
        return session
    }

    @discardableResult mutating func remove(_ key: String) -> Session? { sessions.removeValue(forKey: key) }

    func runningCount(_ isRunning: (Session) -> Bool) -> Int { sessions.values.filter(isRunning).count }
}
