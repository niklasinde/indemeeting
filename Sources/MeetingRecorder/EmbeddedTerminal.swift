import Foundation

/// The pure parts of the embedded Claude terminal: the login-shell command, the environment, where the pane goes, the font, the colours,
/// the status dot and the notices. Tested; the SwiftTerm view and the processes live in EmbeddedTerminalModel.swift.
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
        environment["CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"] = "1"
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
    static let belowRange = 220.0...1000.0
    static let minimumPageWidth = 480.0
    static let minimumPageHeight = 200.0
    /// The handle between the page and the terminal, which takes a point of the room too.
    static let handleLength = 1.0
    static let defaultRight = 560.0
    /// Zero means half the window's height, which is the default bottom half.
    static let defaultBelow = 0.0

    static func placement(width: Double) -> Placement { width >= rightFromWidth ? .right : .below }

    /// The pane's width or height, kept inside its range and leaving room for the page it sits next to. A stored height of zero
    /// is half the available height.
    static func paneLength(_ stored: Double, placement: Placement, available: Double) -> Double {
        switch placement {
        case .right: return min(max(stored, rightRange.lowerBound), min(rightRange.upperBound, available - minimumPageWidth - handleLength))
        case .below:
            let wanted = stored > 0 ? stored : available / 2
            return min(max(wanted, belowRange.lowerBound), min(belowRange.upperBound, available - minimumPageHeight - handleLength))
        }
    }

    // MARK: Font

    static let fontSizes = 9.0...24.0
    static let defaultFontSize = 13.0
    static let fontFamilies = ["SFMono-Regular", "Menlo-Regular"]
    static let lineSpacing = 1.2
    static let scrollbackLines = 10_000

    static func fontName(isAvailable: (String) -> Bool) -> String? { fontFamilies.first(where: isAvailable) }

    static func fontSize(_ stored: Double?) -> Double {
        min(max(stored ?? defaultFontSize, fontSizes.lowerBound), fontSizes.upperBound)
    }

    /// Moves the saved size by the step (zero resets it) and returns the new size.
    @discardableResult
    static func steppedFontSize(_ step: Int, defaults: UserDefaults = .standard) -> Double {
        let size = step == 0 ? defaultFontSize : fontSize((defaults.object(forKey: fontSizeKey) as? Double ?? defaultFontSize) + Double(step))
        defaults.set(size, forKey: fontSizeKey)
        return size
    }

    // MARK: Messages

    /// Nil when nothing is running; otherwise what to ask before quitting.
    static func quitMessage(running: Int, enabled: Bool) -> String? {
        guard enabled, running > 0 else { return nil }
        return "Claude is still running in \(running) terminal\(running == 1 ? "" : "s") \u{2014} Quit anyway?"
    }

    static func runningText(_ count: Int) -> String { "\(count) Claude terminal\(count == 1 ? "" : "s") running" }

    static func safetyNote(directory: String) -> String { "Interactive Claude can change files in \(directory) \u{2014} it asks first." }

    // MARK: Status

    enum Activity: Equatable { case working, idle, ended }

    /// Claude counts as working while it wrote something in this many seconds.
    static let workingWindow: TimeInterval = 3

    static func activity(running: Bool, ended: Bool, lastOutput: Date?, now: Date) -> Activity {
        if ended { return .ended }
        guard running, let lastOutput, now.timeIntervalSince(lastOutput) < workingWindow else { return .idle }
        return .working
    }

    /// `owner/repo #n` for a pull request address, nil for anything else.
    static func pullRequestLabel(_ url: String) -> String? {
        guard let parts = URL(string: url)?.pathComponents, parts.count >= 5, parts[3] == "pull", Int(parts[4]) != nil else { return nil }
        return "\(parts[1])/\(parts[2]) #\(parts[4])"
    }

    // MARK: Notices

    /// One line under the header. Each is shown once per session until its × is pressed.
    struct Notice: Equatable {
        let id: String
        let symbol: String
        let text: String
        var copy: String?
        var action: String?
    }

    static func safetyNotice(directory: String, neverAgain: Bool, running: Bool) -> Notice? {
        guard running, !neverAgain else { return nil }
        return Notice(id: "safety", symbol: "pencil.and.list.clipboard", text: safetyNote(directory: directory), action: "Don't show again")
    }

    /// The first notice that has not been dismissed in this session.
    static func currentNotice(_ notices: [Notice], dismissed: Set<String>) -> Notice? {
        notices.first { !dismissed.contains($0.id) }
    }

    // MARK: Colours

    struct Palette: Equatable {
        let foreground: UInt32
        let background: UInt32
        let caret: UInt32
        let selection: UInt32
        let ansi: [UInt32]
    }

    /// The terminal's colours on the page's own surface: the background is the surface, the text and ANSI colours are pushed away from
    /// it until they are readable, and the caret and selection take the accent.
    static func palette(surface: UInt32, accent: UInt32) -> Palette {
        let dark = contrast(surface, 0xFFFFFF) > contrast(surface, 0x000000)
        return Palette(foreground: readable(dark ? 0xE6E6E6 : 0x1D1D1F, on: surface, minimum: 7),
                       background: surface,
                       caret: readable(accent, on: surface, minimum: 3),
                       selection: mix(surface, accent, 0.35),
                       ansi: (dark ? ansiDark : ansiLight).map { readable($0, on: surface, minimum: 4.5) })
    }

    static let ansiLight: [UInt32] = [0x1D1D1F, 0xC4271C, 0x1F7A3A, 0x946200, 0x1D5FC4, 0x9A3FA6, 0x0F7F8A, 0x6E6E73,
                                      0x8E8E93, 0xE0392B, 0x2E9D4F, 0xB57B00, 0x3A7BE0, 0xB352C0, 0x1A9AA6, 0x3A3A3C]
    static let ansiDark: [UInt32] = [0x1C1C1E, 0xFF6B60, 0x5FD07A, 0xE5B84B, 0x6EA8FF, 0xD28CE0, 0x5CC8D2, 0xC7C7CC,
                                     0x6E6E73, 0xFF8A80, 0x7FE59A, 0xF2CB6B, 0x8FBFFF, 0xE3A6EE, 0x7FDDE6, 0xFFFFFF]

    /// The colour, moved toward black or white (whichever contrasts more with the surface) until it reaches the minimum contrast.
    static func readable(_ color: UInt32, on surface: UInt32, minimum: Double) -> UInt32 {
        let target: UInt32 = contrast(surface, 0xFFFFFF) > contrast(surface, 0x000000) ? 0xFFFFFF : 0x000000
        var result = color
        var step = 0.0
        while contrast(result, surface) < minimum, step < 1 {
            step += 0.05
            result = mix(color, target, min(step, 1))
        }
        return result
    }

    /// WCAG contrast ratio, from 1 to 21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ color: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double(color >> shift & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double(a >> shift & 0xFF), y = Double(b >> shift & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
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
