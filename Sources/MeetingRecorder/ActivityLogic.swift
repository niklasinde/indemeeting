import Foundation

/// A Claude Code session seen writing to its transcript.
struct ClaudeSession: Equatable, Hashable {
    let id: String
    let folder: String
    let title: String
}

/// A session seen lately, with the latest message the user typed into it; one the user only prompted is not working.
struct ClaudeActivity: Equatable {
    var session: ClaudeSession
    var lastUser: Date?
    var lastPrompt: String?
    var working = true
}

/// What is captured about one moment; equal fields of consecutive samples collapse into one block.
struct ActivitySample: Equatable {
    var time: Date
    var appBundle: String?
    var appName: String?
    var windowTitle: String?
    var url: String?
    var repo: String?
    var branch: String?
    var ticket: String?
    var claude: [ClaudeSession] = []
    var idle = false
    /// The owner or organisation of a code-host repository in the address.
    var owner: String?
    /// The session the user is typing into while Claude is frontmost, and the last thing they asked it.
    var claudeFocus: String?
    var claudePrompt: String?
    var redaction: ActivityRedaction?

    static func idle(at time: Date) -> ActivitySample { ActivitySample(time: time, idle: true) }

    /// The fields that have to match for two samples to belong to the same block; the sessions working in the
    /// background are gathered over the block instead.
    var key: ActivityKey {
        ActivityKey(appBundle: appBundle, appName: appName, windowTitle: windowTitle, url: url, repo: repo, branch: branch,
                    ticket: ticket, claude: claude, idle: idle, claudeFocus: claudeFocus, redaction: redaction, owner: owner)
    }

    /// Takes the repository, owner and branch `ActivityLogic.linked` finds for the address.
    mutating func link(branches: BranchIndex) {
        let key = ActivityLogic.linked(key, branches: branches)
        repo = key.repo
        owner = key.owner
        branch = key.branch
    }
}

/// What the tracking rules left of a block: a blocked app or website keeps its app (`private`), an app outside the
/// allowlist keeps only its times (`other`), and a browser on a website outside the allowlist keeps its app (`otherSite`).
enum ActivityRedaction: String {
    case `private`
    case other
    case otherSite = "other site"
}

struct ActivityKey: Hashable {
    var appBundle: String?
    var appName: String?
    var windowTitle: String?
    var url: String?
    var repo: String?
    var branch: String?
    var ticket: String?
    var claude: [ClaudeSession]
    var idle: Bool
    var claudeFocus: String?
    var redaction: ActivityRedaction?
    var owner: String? = nil

    var host: String? { url.flatMap { $0.split(separator: "/", maxSplits: 1).first }.map(String.init) }

    var codeHost: CodeHostLink? { CodeHostLink.parse(url) }

    /// The ticket's prefix, or the Jira project of the page.
    var ticketPrefix: String? { ticket.map(ActivityLogic.ticketPrefix) ?? JiraLink.parse(url)?.prefix }

    /// What the block was worked on: its branch when known, else its ticket.
    var workItem: String? { branch ?? ticket }

    func sameBlock(as other: ActivityKey) -> Bool {
        var a = self, b = other
        a.claude = []
        b.claude = []
        return a == b
    }
}

struct ActivityBlock: Equatable, Identifiable {
    var id: Int64
    var start: Date
    var end: Date
    var key: ActivityKey
    /// A project chosen by hand; nil leaves it to the rules and then the AI guess.
    var projectID: Int64?
    /// The latest settled text around the cursor while this block was active.
    var typedExcerpt: String?
    var category: ActivityCategory?
    var aiDescription: String?
    var aiProjectID: Int64?
    var claudePrompt: String?
    /// Whether Apple Intelligence thought the block was work; nil before classification or for old answers.
    var aiWork: Bool?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    var claudeFocusSession: ClaudeSession? { key.claudeFocus.flatMap { id in key.claude.first { $0.id == id } } }
    var backgroundSessions: [ClaudeSession] { key.claude.filter { $0.id != key.claudeFocus } }
    var title: String? { claudeFocusSession?.title ?? key.windowTitle ?? key.appName }

    /// The seconds of the block inside `range`.
    func seconds(in range: Range<Date>) -> TimeInterval {
        max(0, min(end, range.upperBound).timeIntervalSince(max(start, range.lowerBound)))
    }

    var host: String? { key.host }

    var withoutPrompt: ActivityBlock {
        var block = self
        block.claudePrompt = nil
        return block
    }
}

/// What a block was for, as guessed by Apple Intelligence from the app, title, address and text.
enum ActivityCategory: String, CaseIterable {
    case coding
    case codeReview = "code review"
    case meeting
    case email
    case chat
    case writing = "writing/docs"
    case planning = "planning/tickets"
    case research = "research/browsing"
    case design
    case admin
    case entertainment
    case other

    var label: String {
        switch self {
        case .writing: return "Writing"
        case .planning: return "Planning"
        case .research: return "Research"
        case .codeReview: return "Code review"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

struct Project: Equatable, Identifiable, Hashable {
    var id: Int64
    var name: String
    var color: String

    static let colors = ["#5B8DEF", "#E0665C", "#4CAF7D", "#E6A23C", "#9B6BD6", "#2BB3B1", "#D66B9B", "#8A8F98"]
}

/// The fields a rule can match, in the order rules are tried: a block's own choice comes first, the AI guess last.
enum RuleField: String, CaseIterable {
    case branch
    case ticket
    case repo
    case owner
    case host
    case app

    var label: String {
        switch self {
        case .branch: return "Branch"
        case .ticket: return "Ticket prefix"
        case .repo: return "Repository"
        case .owner: return "Organisation"
        case .host: return "Website"
        case .app: return "App"
        }
    }

    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

struct ProjectRule: Equatable, Identifiable {
    var id: Int64
    var projectID: Int64
    var field: RuleField
    var pattern: String

    func matches(_ key: ActivityKey) -> Bool {
        let pattern = pattern.lowercased()
        switch field {
        case .branch: return key.branch.map { Self.glob(pattern, matches: $0.lowercased()) } ?? false
        case .ticket: return key.ticketPrefix?.lowercased() == pattern
        case .repo: return key.repo?.lowercased() == pattern
        case .owner: return key.owner?.lowercased() == pattern
        case .host: return key.host.map { HostPattern.matches(pattern, host: $0) } ?? false
        case .app: return [key.appBundle, key.appName].contains { $0?.lowercased() == pattern }
        }
    }

    /// `*` stands for any run of characters; everything else matches itself.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let regex = "^" + pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
        return text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// The settings of activity tracking, kept in UserDefaults.
struct ActivitySettings: Equatable {
    static let enabledKey = "activityTrackingEnabled"
    static let pausedKey = "activityTrackingPaused"
    static let titlesKey = "activityCaptureTitles"
    static let urlsKey = "activityCaptureURLs"
    static let gitKey = "activityCaptureGit"
    static let claudeKey = "activityCaptureClaude"
    static let promptsKey = "activityStorePrompts"
    static let idleKey = "activityIdleSeconds"
    static let retentionKey = "activityRetentionDays"
    /// The blocked apps; the key predates the allowlist.
    static let excludedKey = "activityExcludedApps"
    static let allowedAppsKey = "activityAllowedApps"
    static let blockedSitesKey = "activityBlockedWebsites"
    static let allowedSitesKey = "activityAllowedWebsites"
    static let appModeKey = "activityAppMode"
    static let workAppsKey = "activityWorkApps"
    static let workSitesKey = "activityWorkWebsites"
    static let nonWorkAppsKey = "activityNonWorkApps"
    static let nonWorkSitesKey = "activityNonWorkWebsites"
    static let nonWorkKey = "activityNonWork"
    static let siteModeKey = "activityWebsiteMode"
    static let typingKey = "activityCaptureTyping"
    static let classifyKey = "activityClassify"
    static let excludedCategoriesKey = "activityExcludedCategories"
    /// Removes blocked activity instead of keeping it private; the key predates blocked apps and websites.
    static let removeBlockedKey = "activityRemoveExcludedCategories"

    static let defaultExcluded = ["1Password", "Keychain Access", "Passwords"]
    static let idleChoices: [TimeInterval] = [60, 120, 300, 600]
    static let retentionChoices = [30, 90, 180, 365]
    static let interval: TimeInterval = 5
    /// How long a Claude session counts as working after it last wrote, so the lane does not flicker between samples.
    static let claudeLookback: TimeInterval = 120

    static let defaults: [String: Any] = [
        enabledKey: false, pausedKey: false, titlesKey: true, urlsKey: true, gitKey: true, claudeKey: true, promptsKey: false,
        idleKey: 120, retentionKey: 90, excludedKey: defaultExcluded, typingKey: false, classifyKey: true,
        excludedCategoriesKey: [String](), removeBlockedKey: false, allowedAppsKey: [String](), blockedSitesKey: [String](),
        allowedSitesKey: [String](), appModeKey: ListMode.allExceptBlocked.rawValue, siteModeKey: ListMode.allExceptBlocked.rawValue,
        workAppsKey: [String](), workSitesKey: [String](), nonWorkAppsKey: [String](), nonWorkSitesKey: [String](),
        nonWorkKey: NonWork.keep.rawValue,
    ]

    enum NonWork: String, CaseIterable {
        case keep
        case fold
        case remove

        var label: String {
            switch self {
            case .keep: return "Keep"
            case .fold: return "Fold into Other"
            case .remove: return "Remove"
            }
        }
    }

    enum ListMode: String, CaseIterable {
        case allExceptBlocked = "blocked"
        case onlyAllowed = "allowed"
    }

    var enabled = false
    var paused = false
    var titles = true
    var urls = true
    var git = true
    var claude = true
    var storePrompts = false
    var idleSeconds: TimeInterval = 120
    var retentionDays = 90
    var blockedApps = defaultExcluded
    var allowedApps: [String] = []
    var blockedSites: [String] = []
    var allowedSites: [String] = []
    var appMode = ListMode.allExceptBlocked
    var siteMode = ListMode.allExceptBlocked
    var workApps: [String] = []
    var workSites: [String] = []
    var nonWorkApps: [String] = []
    var nonWorkSites: [String] = []
    var nonWork = NonWork.keep
    var typing = false
    var classify = true
    var excludedCategories: [ActivityCategory] = []
    var removeBlocked = false

    init() {}

    init(_ defaults: UserDefaults) {
        enabled = defaults.bool(forKey: Self.enabledKey)
        paused = defaults.bool(forKey: Self.pausedKey)
        titles = defaults.bool(forKey: Self.titlesKey)
        urls = defaults.bool(forKey: Self.urlsKey)
        git = defaults.bool(forKey: Self.gitKey)
        claude = defaults.bool(forKey: Self.claudeKey)
        storePrompts = defaults.bool(forKey: Self.promptsKey)
        idleSeconds = defaults.double(forKey: Self.idleKey)
        retentionDays = defaults.integer(forKey: Self.retentionKey)
        blockedApps = defaults.stringArray(forKey: Self.excludedKey) ?? Self.defaultExcluded
        allowedApps = defaults.stringArray(forKey: Self.allowedAppsKey) ?? []
        blockedSites = defaults.stringArray(forKey: Self.blockedSitesKey) ?? []
        allowedSites = defaults.stringArray(forKey: Self.allowedSitesKey) ?? []
        appMode = defaults.string(forKey: Self.appModeKey).flatMap(ListMode.init) ?? .allExceptBlocked
        siteMode = defaults.string(forKey: Self.siteModeKey).flatMap(ListMode.init) ?? .allExceptBlocked
        workApps = defaults.stringArray(forKey: Self.workAppsKey) ?? []
        workSites = defaults.stringArray(forKey: Self.workSitesKey) ?? []
        nonWorkApps = defaults.stringArray(forKey: Self.nonWorkAppsKey) ?? []
        nonWorkSites = defaults.stringArray(forKey: Self.nonWorkSitesKey) ?? []
        nonWork = defaults.string(forKey: Self.nonWorkKey).flatMap(NonWork.init) ?? .keep
        typing = defaults.bool(forKey: Self.typingKey)
        classify = defaults.bool(forKey: Self.classifyKey)
        excludedCategories = (defaults.stringArray(forKey: Self.excludedCategoriesKey) ?? []).compactMap(ActivityCategory.init)
        removeBlocked = defaults.bool(forKey: Self.removeBlockedKey)
    }

    /// Whether prompts are stored, read from the app's own defaults so the command line and the MCP server agree with it.
    static var promptsStored: Bool {
        let app = "com.niklasinde.MeetingRecorder"
        let defaults = Bundle.main.bundleIdentifier == app ? UserDefaults.standard : UserDefaults(suiteName: app) ?? .standard
        return defaults.bool(forKey: promptsKey)
    }

    func blocks(appName: String?, bundle: String?) -> Bool { Self.lists(blockedApps, appName: appName, bundle: bundle) }
    func allows(appName: String?, bundle: String?) -> Bool { Self.lists(allowedApps, appName: appName, bundle: bundle) }
    func blocks(host: String?) -> Bool { Self.lists(blockedSites, host: host) }
    func allows(host: String?) -> Bool { Self.lists(allowedSites, host: host) }

    /// What the user said about the block's website, else its app; nil when they said nothing.
    func workRule(_ key: ActivityKey) -> Bool? {
        if Self.lists(nonWorkSites, host: key.host) { return false }
        if Self.lists(workSites, host: key.host) { return true }
        if Self.lists(nonWorkApps, appName: key.appName, bundle: key.appBundle) { return false }
        if Self.lists(workApps, appName: key.appName, bundle: key.appBundle) { return true }
        return nil
    }

    /// The user's own rule first, then an allowed app or website counts as work, then Apple Intelligence: entertainment
    /// and blocks it says are not work are not work. Blocks not yet categorised count as work.
    func isWork(_ block: ActivityBlock) -> Bool {
        if let rule = workRule(block.key) { return rule }
        if allows(appName: block.key.appName, bundle: block.key.appBundle) || allows(host: block.key.host) { return true }
        return block.category != .entertainment && block.aiWork != false
    }

    /// Whether the browser's address has to be read even when addresses are not kept, to apply the website rules.
    var needsHost: Bool { siteMode == .onlyAllowed || !blockedSites.isEmpty || (appMode == .onlyAllowed && !allowedSites.isEmpty) }

    private static func lists(_ list: [String], host: String?) -> Bool {
        host.map { host in list.contains { HostPattern.matches($0, host: host) } } ?? false
    }

    private static func lists(_ list: [String], appName: String?, bundle: String?) -> Bool {
        list.contains { name in [appName, bundle].contains { $0?.caseInsensitiveCompare(name) == .orderedSame } }
    }

    enum Capture: Equatable {
        case keep
        case redact(ActivityRedaction)
        case remove
    }

    /// What the app and website rules do with a moment, in this order: a blocked app, then a blocked website (both
    /// private, or removed), then an app or website the user said is not work (other, or removed, unless non-work
    /// activity is kept), then an app outside the app allowlist (other; a browser on an allowed website counts as
    /// allowed), then a browser on a website outside the website allowlist (other site, or removed). Idle time and
    /// blocks that are already other are left alone.
    func capture(_ key: ActivityKey) -> Capture {
        guard !key.idle, key.redaction != .other, key.appName != nil || key.appBundle != nil else { return .keep }
        let blocked: Capture = removeBlocked ? .remove : .redact(.private)
        if blocks(appName: key.appName, bundle: key.appBundle) || blocks(host: key.host) { return blocked }
        if nonWork != .keep, workRule(key) == false { return foldedNonWork }
        let browser = WebBrowsers.contains(key.appBundle)
        if appMode == .onlyAllowed, !allows(appName: key.appName, bundle: key.appBundle), !(browser && allows(host: key.host)) {
            return .redact(.other)
        }
        if browser, siteMode == .onlyAllowed, !allows(host: key.host) { return removeBlocked ? .remove : .redact(.otherSite) }
        return .keep
    }

    private var foldedNonWork: Capture { nonWork == .remove ? .remove : .redact(.other) }

    /// What the rules do with a stored block: the capture rules, and once it is categorised, an excluded category
    /// (private, or removed) and non-work (other, or removed). The stronger outcome wins.
    func review(_ block: ActivityBlock) -> Capture {
        let captured = capture(block.key)
        if captured == .remove || captured == .redact(.other) || block.key.idle || block.key.redaction == .other { return captured }
        let category = action(for: block.category)
        if category == .remove { return .remove }
        if nonWork != .keep, !isWork(block) { return foldedNonWork }
        return category == .strip ? .redact(.private) : captured
    }

    enum CategoryAction { case keep, strip, remove }

    /// What happens to a block once it has been given `category`: excluded categories are made private or removed.
    func action(for category: ActivityCategory?) -> CategoryAction {
        guard let category, excludedCategories.contains(category) else { return .keep }
        return removeBlocked ? .remove : .strip
    }
}

/// Website rules: `bank.se` covers the host and every subdomain, `*.bank.se` only the subdomains.
enum HostPattern {
    /// A pattern from what the user typed: scheme, credentials, port, path and query are dropped and it is lowercased;
    /// nil when what is left is not a host name.
    static func normalized(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<end]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        while text.hasSuffix(".") { text.removeLast() }
        let wildcard = text.hasPrefix("*.")
        if wildcard { text.removeFirst(2) }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        let valid = !text.isEmpty && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
        return valid ? (wildcard ? "*." : "") + text : nil
    }

    static func matches(_ pattern: String, host: String) -> Bool {
        let pattern = pattern.lowercased(), host = host.lowercased()
        if pattern.hasPrefix("*.") { return host.hasSuffix(pattern.dropFirst()) }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    static let presets: [(name: String, pattern: String)] = [
        ("Jira", "*.atlassian.net"), ("GitHub", "github.com"), ("Confluence", "atlassian.net"), ("Google Docs", "docs.google.com"),
    ]
}

/// Browsers whose blocks follow the website rules; the address is read from the ones `Browsers` scripts.
enum WebBrowsers {
    static let bundles: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
                                       "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
                                       "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "app.zen-browser.zen",
                                       "org.chromium.Chromium"]

    static func contains(_ bundle: String?) -> Bool { bundle.map(bundles.contains) ?? false }
}

/// Apps whose window titles name the repository being worked on.
enum DeveloperApps {
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
                                         "com.mitchellh.ghostty", "co.zeit.hyper", "org.alacritty"]
    static let bundlePrefixes = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp", "com.mitchellh.ghostty", "com.jetbrains.",
                                 "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "com.anthropic.claudefordesktop",
                                 "com.sublimetext.", "com.github.GitHubClient", "com.fournova.Tower", "co.zeit.hyper", "org.alacritty"]

    static func contains(_ bundle: String?) -> Bool {
        bundle.map { id in bundlePrefixes.contains { id.hasPrefix($0) } } ?? false
    }
}

enum ActivityLogic {
    /// Extends the open block when the sample has the same key and follows closely; otherwise returns the block to
    /// close (if any) and the new open block. Block ends cover the sample's whole interval.
    static func collapse(_ open: ActivityBlock?, with sample: ActivitySample, interval: TimeInterval = ActivitySettings.interval)
        -> (closed: ActivityBlock?, open: ActivityBlock) {
        let end = sample.time.addingTimeInterval(interval)
        if var open, open.key.sameBlock(as: sample.key), sample.time.timeIntervalSince(open.end) <= interval {
            open.end = max(open.end, end)
            for session in sample.claude {
                if let index = open.key.claude.firstIndex(where: { $0.id == session.id }) {
                    open.key.claude[index] = session
                } else {
                    open.key.claude.append(session)
                }
            }
            open.claudePrompt = sample.claudePrompt ?? open.claudePrompt
            return (nil, open)
        }
        return (open, ActivityBlock(id: 0, start: sample.time, end: end, key: sample.key, projectID: nil, claudePrompt: sample.claudePrompt))
    }

    /// Applies the app and website rules and then the capture settings; nil when the moment is not to be stored.
    static func filtered(_ sample: ActivitySample, settings: ActivitySettings) -> ActivitySample? {
        var sample = sample
        switch settings.capture(sample.key) {
        case .remove: return nil
        case .redact(let redaction): return redacted(sample, as: redaction)
        case .keep: break
        }
        if !settings.titles { sample.windowTitle = nil }
        if !settings.urls {
            sample.url = nil
            sample.owner = nil
        }
        if !settings.git {
            sample.repo = nil
            sample.branch = nil
            sample.owner = nil
        }
        if !settings.claude {
            sample.claude = []
            sample.claudeFocus = nil
        }
        if !settings.claude || !settings.storePrompts { sample.claudePrompt = nil }
        return sample
    }

    /// Only the time, and for anything but `other` the app, are kept.
    static func redacted(_ sample: ActivitySample, as redaction: ActivityRedaction) -> ActivitySample {
        var kept = ActivitySample(time: sample.time, redaction: redaction)
        if redaction != .other {
            kept.appBundle = sample.appBundle
            kept.appName = sample.appName
        }
        return kept
    }

    // MARK: Detection

    static let ticketPattern = try! NSRegularExpression(pattern: "\\b([A-Z][A-Z0-9]{1,9}-[0-9]{1,6})\\b")

    static func ticket(in texts: String?...) -> String? {
        for text in texts.compactMap({ $0 }) {
            if let match = ticketPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    /// Repository folders under `~/git/*` and `~/git/*/*`: a folder is a repository when it has a `.git` entry.
    static func repositories(under root: URL, fileManager: FileManager = .default) -> [URL] {
        func children(_ url: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        }
        let first = children(root)
        return (first + first.flatMap(children)).filter { fileManager.fileExists(atPath: $0.appendingPathComponent(".git").path) }
    }

    /// The repository whose folder name appears in the title as a whole word; the longest name wins.
    static func repository(inTitle title: String?, repositories: [URL]) -> URL? {
        guard let title, !title.isEmpty else { return nil }
        let lowered = title.lowercased()
        return repositories
            .filter { containsWord(lowered, $0.lastPathComponent.lowercased()) }
            .max { $0.lastPathComponent.count < $1.lastPathComponent.count }
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: word, range: searchRange) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before.map(isWordCharacter) ?? false), !(after.map(isWordCharacter) ?? false) { return true }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// The checked-out branch from `.git/HEAD`, following a worktree's `gitdir:` file. A detached HEAD gives the
    /// short commit.
    static func branch(ofRepository repo: URL, fileManager: FileManager = .default) -> String? {
        var gitFolder = repo.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitFolder.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            guard let pointer = try? String(contentsOf: gitFolder, encoding: .utf8),
                  let line = pointer.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitFolder = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appendingPathComponent(path)
        }
        guard let head = try? String(contentsOf: gitFolder.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        return branch(fromHEAD: head)
    }

    static func branch(fromHEAD head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("ref: ") {
            let ref = line.dropFirst(5)
            return String(ref.hasPrefix("refs/heads/") ? ref.dropFirst("refs/heads/".count) : ref)
        }
        return String(line.prefix(8))
    }

    /// `host/path` of a URL without query or fragment; nil for anything that is not http(s).
    static func cleanURL(_ string: String?) -> String? {
        guard let string, let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased()), let host = components.host, !host.isEmpty else { return nil }
        let path = components.path == "/" ? "" : components.path
        return host.lowercased() + (path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    // MARK: Typed text

    /// Up to `limit` characters of a text field's value around the insertion point, on one line.
    static func excerpt(value: String, cursor: Int, limit: Int = 300) -> String? {
        let text = value.replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let count = text.count
        let cursor = min(max(cursor, 0), count)
        var start = max(0, cursor - limit / 2)
        let end = min(count, start + limit)
        start = max(0, end - limit)
        let slice = text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)]
        var result = slice.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if start > 0 { result = "\u{2026}" + result }
        if end < count { result += "\u{2026}" }
        return result
    }

    // MARK: Claude sessions

    /// The session's working folder from the `cwd` of its first user message, and a title: the custom title when the
    /// user set one, else the first line the user wrote (system reminders stripped), truncated.
    static func claudeSession(id: String, jsonl: String, customTitle: String? = nil, titleLimit: Int = 80) -> ClaudeSession? {
        var folder: String?
        var title: String?
        var lastCustom: String?
        for line in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "custom-title" { lastCustom = object["customTitle"] as? String }
            guard type == "user", let message = object["message"] as? [String: Any] else { continue }
            if folder == nil { folder = object["cwd"] as? String }
            if title == nil, let text = userText(message["content"]).flatMap(firstLine) { title = text }
            if folder != nil, title != nil, customTitle != nil { break }
        }
        guard let folder else { return nil }
        let chosen = [customTitle, lastCustom, title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return ClaudeSession(id: id, folder: folder, title: truncate(chosen ?? "Untitled session", to: titleLimit))
    }

    private static func userText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// The first line of what the user typed, leaving out `<system-reminder>` blocks and other tags.
    static func firstLine(of text: String) -> String? {
        typedLines(text).first
    }

    /// What the user typed, on one line without reminders and tags, cut to `limit`.
    static func promptExcerpt(_ text: String, limit: Int = 120) -> String? {
        let line = typedLines(text).joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return line.isEmpty ? nil : truncate(line, to: limit)
    }

    private static func typedLines(_ text: String) -> [String] {
        var text = text
        while let open = text.range(of: "<system-reminder>") {
            guard let close = text.range(of: "</system-reminder>", range: open.upperBound..<text.endIndex) else {
                text.removeSubrange(open.lowerBound...)
                break
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("[Request interrupted") }
    }

    /// The time and text of the last message the user typed in a transcript (or its tail); tool results, meta
    /// entries and subagent turns are not typed by the user.
    static func lastUserMessage(inJSONL jsonl: String) -> (time: Date?, text: String)? {
        for line in jsonl.split(whereSeparator: \.isNewline).reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "user", object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let text = userText(message["content"]).flatMap({ promptExcerpt($0) }) else { continue }
            let time = (object["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
            return (time, text)
        }
        return nil
    }

    /// The session the user is in: the one they last typed into within `window`, else the block's session so far.
    static func focusedSession(_ activity: [ClaudeActivity], now: Date, window: TimeInterval = 120, sticky: String?) -> String? {
        activity.filter { ($0.lastUser.map { now.timeIntervalSince($0) <= window }) ?? false }
            .max { $0.lastUser! < $1.lastUser! }?.session.id ?? sticky
    }

    /// The Claude app, or a terminal whose title shows Claude Code running in it.
    static func isClaudeWindow(bundle: String?, title: String?) -> Bool {
        guard let bundle else { return false }
        if bundle.hasPrefix("com.anthropic.claude") { return true }
        let title = title?.lowercased() ?? ""
        return DeveloperApps.terminals.contains(bundle) && (title.contains("claude") || title.hasPrefix("\u{2733}"))
    }

    /// The repository a session works in: for `<repo>/.claude/worktrees/<name>` the parent repository and the
    /// worktree's checkout, otherwise the nearest folder with a `.git` entry. Claude's scratch workspaces have none.
    static func claudeCheckout(cwd: String, fileManager: FileManager = .default) -> (repo: String, checkout: URL)? {
        guard !cwd.isEmpty, !cwd.contains("/scratch-workspaces/") else { return nil }
        if let marker = cwd.range(of: "/.claude/worktrees/") {
            let parent = URL(fileURLWithPath: String(cwd[..<marker.lowerBound]))
            guard let name = cwd[marker.upperBound...].split(separator: "/").first else { return nil }
            return (parent.lastPathComponent, parent.appendingPathComponent(".claude/worktrees/\(name)"))
        }
        var folder = URL(fileURLWithPath: cwd)
        while folder.path != "/" {
            if fileManager.fileExists(atPath: folder.appendingPathComponent(".git").path) { return (folder.lastPathComponent, folder) }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// `~/.claude/projects/-Users-me-git-repo` → `/Users/me/git/repo` (dashes in names are lost, so `cwd` is preferred).
    static func decodeProjectFolder(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "/")
    }

    /// Merges consecutive other blocks less than `gap` apart into one row of the timeline.
    static func timelineRows(_ blocks: [ActivityBlock], gap: TimeInterval = 60) -> [ActivityBlock] {
        var rows: [ActivityBlock] = []
        for block in blocks {
            if block.key.redaction == .other, let last = rows.last, last.key.redaction == .other, block.start.timeIntervalSince(last.end) <= gap {
                rows[rows.count - 1].end = max(last.end, block.end)
            } else {
                rows.append(block)
            }
        }
        return rows
    }

    // MARK: Projects

    /// The block's own choice, else the matching rule whose field comes first in `RuleField` (the older rule among
    /// equals), else the AI guess.
    static func project(for block: ActivityBlock, rules: [ProjectRule], projects: [Project]) -> Project? {
        let id = block.projectID ?? matchingRule(block.key, rules)?.projectID ?? block.aiProjectID
        return id.flatMap { id in projects.first { $0.id == id } }
    }

    static func matchingRule(_ key: ActivityKey, _ rules: [ProjectRule]) -> ProjectRule? {
        rules.filter { $0.matches(key) }.min { ($0.field.rank, $0.id) < ($1.field.rank, $1.id) }
    }

    /// Whether the shown project is only the AI's guess.
    static func projectIsGuessed(_ block: ActivityBlock, rules: [ProjectRule]) -> Bool {
        block.projectID == nil && block.aiProjectID != nil && matchingRule(block.key, rules) == nil
    }

    // MARK: Totals

    struct Total: Equatable {
        let name: String
        let seconds: TimeInterval
    }

    /// Active (non-idle) seconds per project, "Unassigned" last, longest first.
    static func projectTotals(_ blocks: [ActivityBlock], in range: Range<Date>, rules: [ProjectRule], projects: [Project]) -> [Total] {
        totals(blocks, in: range) { project(for: $0, rules: rules, projects: projects)?.name ?? unassigned }
    }

    static func appTotals(_ blocks: [ActivityBlock], in range: Range<Date>) -> [Total] {
        totals(blocks, in: range) { $0.key.redaction == .other ? "Other" : $0.key.appName ?? $0.key.appBundle ?? "Unknown" }
    }

    /// Seconds per category; blocks not yet categorised are left out.
    static func categoryTotals(_ blocks: [ActivityBlock], in range: Range<Date>) -> [Total] {
        totals(blocks.filter { $0.category != nil }, in: range) { $0.category!.label }
    }

    static let unassigned = "Unassigned"

    private static func totals(_ blocks: [ActivityBlock], in range: Range<Date>, by name: (ActivityBlock) -> String) -> [Total] {
        var seconds: [String: TimeInterval] = [:]
        for block in blocks where !block.key.idle {
            let overlap = block.seconds(in: range)
            if overlap > 0 { seconds[name(block), default: 0] += overlap }
        }
        return seconds.map { Total(name: $0.key, seconds: $0.value) }.sorted {
            if ($0.name == unassigned) != ($1.name == unassigned) { return $1.name == unassigned }
            return $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name
        }
    }

    /// `owner/repo` when the owner is known, else the repository's folder name.
    static func repoLabel(_ key: ActivityKey) -> String {
        [key.owner, key.repo].compactMap { $0 }.joined(separator: "/")
    }

    /// Time per work item: a branch (in its repository), else a ticket worked on without one.
    struct WorkTotal: Equatable {
        let name: String
        let repo: String?
        let ticket: String?
        let project: RowProject?
        let seconds: TimeInterval

        var label: String { repo.map { "\(name) (\($0))" } ?? name }
    }

    /// Time per ticket: its branches and the browser time on its pages.
    struct TicketTotal: Equatable {
        let ticket: String
        let branches: [String]
        let project: RowProject?
        let seconds: TimeInterval
    }

    static func ticket(of key: ActivityKey) -> String? { key.ticket ?? ticket(in: key.branch) }

    static func workTotals(_ blocks: [ActivityBlock], in range: Range<Date>, rules: [ProjectRule], projects: [Project]) -> [WorkTotal] {
        let groups = Dictionary(grouping: blocks.filter { !$0.key.idle && $0.key.workItem != nil && $0.seconds(in: range) > 0 }) { block in
            [block.key.workItem!, block.key.branch == nil ? "" : block.key.repo ?? ""]
        }
        return groups.map { group, blocks in
            WorkTotal(name: group[0], repo: group[1].isEmpty ? nil : group[1], ticket: blocks.lazy.compactMap { ticket(of: $0.key) }.first,
                      project: rowProject(blocks, in: range, rules: rules, projects: projects), seconds: activeSeconds(blocks, in: range))
        }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
    }

    static func ticketTotals(_ blocks: [ActivityBlock], in range: Range<Date>, rules: [ProjectRule], projects: [Project]) -> [TicketTotal] {
        let groups = Dictionary(grouping: blocks.filter { !$0.key.idle && $0.seconds(in: range) > 0 }) { ticket(of: $0.key) }
        return groups.compactMap { ticket, blocks in
            ticket.map { TicketTotal(ticket: $0, branches: Array(Set(blocks.compactMap(\.key.branch))).sorted(),
                                     project: rowProject(blocks, in: range, rules: rules, projects: projects), seconds: activeSeconds(blocks, in: range)) }
        }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.ticket < $1.ticket }
    }

    /// The project a row of the breakdown shows: `guessed` when only the AI's guess says so.
    struct RowProject: Equatable {
        let name: String
        let guessed: Bool
    }

    /// The rule or manual project with the most time; without one, the guessed project, but only when it covers more
    /// than half of the row's time.
    static func rowProject(_ blocks: [ActivityBlock], in range: Range<Date>, rules: [ProjectRule], projects: [Project]) -> RowProject? {
        var resolved: [Project: TimeInterval] = [:]
        var guessed: [Project: TimeInterval] = [:]
        var total: TimeInterval = 0
        for block in blocks where !block.key.idle {
            let seconds = block.seconds(in: range)
            total += seconds
            guard seconds > 0, let project = project(for: block, rules: rules, projects: projects) else { continue }
            if projectIsGuessed(block, rules: rules) { guessed[project, default: 0] += seconds } else { resolved[project, default: 0] += seconds }
        }
        func longest(_ seconds: [Project: TimeInterval]) -> (project: Project, seconds: TimeInterval)? {
            seconds.max { $0.value != $1.value ? $0.value < $1.value : $0.key.name > $1.key.name }.map { ($0.key, $0.value) }
        }
        if let top = longest(resolved) { return RowProject(name: top.project.name, guessed: false) }
        if let top = longest(guessed), top.seconds > total / 2 { return RowProject(name: top.project.name, guessed: true) }
        return nil
    }

    static func activeSeconds(_ blocks: [ActivityBlock], in range: Range<Date>) -> TimeInterval {
        blocks.filter { !$0.key.idle }.reduce(0) { $0 + $1.seconds(in: range) }
    }

    static func day(containing date: Date, calendar: Calendar = .current) -> Range<Date> {
        let start = calendar.startOfDay(for: date)
        return start..<calendar.date(byAdding: .day, value: 1, to: start)!
    }

    /// The seven days of the week containing `date`, starting on the calendar's first weekday.
    static func week(containing date: Date, calendar: Calendar = .current) -> [Range<Date>] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0..<7).map { day(containing: calendar.date(byAdding: .day, value: $0, to: start)!, calendar: calendar) }
    }

    static func hoursText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes == 0 { return seconds > 0 ? "<1 min" : "0 min" }
        return minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func hours(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds / 3600) }

    // MARK: Export

    struct WeekReport {
        let days: [Range<Date>]
        let blocks: [ActivityBlock]
        let rules: [ProjectRule]
        let projects: [Project]
        var calendar = Calendar.current
        var directory = TicketDirectory()
    }

    /// One row per day, project and work item; blocks without a work item come last with an empty one.
    static func csv(_ report: WeekReport) -> String {
        var lines = ["date,project,work_item,ticket,ticket_title,jira_url,hours,details"]
        for day in report.days {
            let date = dateText(day.lowerBound)
            for (name, blocks) in groupedByProject(report, in: day) {
                let items = Dictionary(grouping: blocks) { $0.key.workItem ?? "" }.map { ($0.key, $0.value, activeSeconds($0.value, in: day)) }
                    .sorted { ($0.0.isEmpty ? 1 : 0, -$0.2, $0.0) < ($1.0.isEmpty ? 1 : 0, -$1.2, $1.0) }
                for (item, blocks, seconds) in items {
                    let ticket = blocks.lazy.compactMap { ticket(of: $0.key) }.first
                    lines.append([date, name, item, ticket ?? "", ticket.flatMap { report.directory.titles[$0] } ?? "",
                                  ticket.flatMap { report.directory.url(for: $0)?.absoluteString } ?? "", hours(seconds),
                                  details(of: blocks).joined(separator: "; ")].map(csvField).joined(separator: ","))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func markdown(_ report: WeekReport) -> String {
        let first = report.days.first!.lowerBound
        let last = report.days.last!.lowerBound
        var lines = ["# Week \(report.calendar.component(.weekOfYear, from: first)) \u{00B7} \(dateText(first)) \u{2013} \(dateText(last))", ""]
        let weekTotal = activeSeconds(report.blocks, in: first..<report.days.last!.upperBound)
        lines.append("Total: \(hoursText(weekTotal))")
        for day in report.days {
            let groups = groupedByProject(report, in: day)
            guard !groups.isEmpty else { continue }
            lines += ["", "## \(day.lowerBound.formatted(.dateTime.weekday(.wide))) \(dateText(day.lowerBound)) \u{00B7} \(hoursText(activeSeconds(report.blocks, in: day)))"]
            for (name, blocks) in groups {
                lines += ["", "### \(name) \u{00B7} \(hoursText(activeSeconds(blocks, in: day)))"]
                lines += details(of: blocks).map { "- " + $0 }
            }
        }
        lines += workSections(report.blocks, in: first..<report.days.last!.upperBound, rules: report.rules, projects: report.projects,
                              directory: report.directory)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `## By branch` and `## By ticket`, for the week export and the context summary.
    static func workSections(_ blocks: [ActivityBlock], in range: Range<Date>, rules: [ProjectRule], projects: [Project],
                             directory: TicketDirectory) -> [String] {
        var lines: [String] = []
        let work = workTotals(blocks, in: range, rules: rules, projects: projects)
        if !work.isEmpty {
            lines += ["", "## By branch"] + work.prefix(15).map { item in
                let names = item.name == item.ticket ? [directory.markdown(item.name)] : [item.label, item.ticket.map(directory.markdown)]
                return "- " + (names + [item.project?.name, hoursText(item.seconds)]).compactMap { $0 }.joined(separator: " \u{00B7} ")
            }
        }
        let tickets = ticketTotals(blocks, in: range, rules: rules, projects: projects)
        if !tickets.isEmpty {
            lines += ["", "## By ticket"] + tickets.prefix(15).map { total in
                "- " + [directory.markdown(total.ticket), total.project?.name, hoursText(total.seconds)].compactMap { $0 }.joined(separator: " \u{00B7} ")
                    + (total.branches.isEmpty ? "" : " (\(total.branches.joined(separator: ", ")))")
            }
        }
        return lines
    }

    /// Repositories (with branches and tickets), tickets, websites and the longest window titles of the blocks.
    static func details(of blocks: [ActivityBlock], limit: Int = 6) -> [String] {
        var seconds: [String: TimeInterval] = [:]
        for block in blocks where !block.key.idle {
            var labels: [String] = []
            if block.key.repo != nil {
                labels.append([repoLabel(block.key), block.key.branch.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
            }
            if let ticket = block.key.ticket { labels.append(ticket) }
            if let host = block.host { labels.append(host) }
            if labels.isEmpty, let title = block.key.windowTitle { labels.append(title) }
            if labels.isEmpty, let app = block.key.appName { labels.append(app) }
            for label in labels { seconds[label, default: 0] += block.duration }
        }
        return seconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    private static func groupedByProject(_ report: WeekReport, in day: Range<Date>) -> [(String, [ActivityBlock])] {
        let inDay = report.blocks.filter { !$0.key.idle && $0.seconds(in: day) > 0 }
        let groups = Dictionary(grouping: inDay) { project(for: $0, rules: report.rules, projects: report.projects)?.name ?? unassigned }
        return projectTotals(inDay, in: day, rules: report.rules, projects: report.projects).compactMap { total in
            groups[total.name].map { (total.name, $0) }
        }
    }

    static func csvField(_ text: String) -> String {
        text.contains(where: { ",\"\n".contains($0) }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
    }

    // MARK: Context

    struct MeetingSummaryLine: Equatable {
        let date: Date
        let title: String
        let duration: TimeInterval?
    }

    /// A compact Markdown summary of what happened in `range`, for pasting into a Claude conversation.
    static func contextMarkdown(blocks: [ActivityBlock], meetings: [MeetingSummaryLine], range: Range<Date>,
                                rules: [ProjectRule] = [], projects: [Project] = [], directory: TicketDirectory = TicketDirectory()) -> String {
        let active = blocks.filter { !$0.key.idle && $0.seconds(in: range) > 0 }
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        var lines = ["# Activity \(dateText(range.lowerBound)) \(time(range.lowerBound)) \u{2013} \(time(range.upperBound))",
                     "", "Active: \(hoursText(activeSeconds(active, in: range)))"]
        let projectLines = projectTotals(active, in: range, rules: rules, projects: projects)
        if projectLines.count > 1 || projectLines.first?.name != unassigned {
            lines += ["", "## Projects"] + projectLines.map { "- \($0.name): \(hoursText($0.seconds))" }
        }
        func section(_ title: String, _ items: [(String, TimeInterval)]) {
            guard !items.isEmpty else { return }
            lines += ["", "## \(title)"] + items.map { "- \($0.0) \u{00B7} \(hoursText($0.1))" }
        }
        section("Apps", appTotals(active, in: range).map { ($0.name, $0.seconds) })
        section("Repositories", ranked(active, in: range) { block in
            block.key.repo.map { _ in [repoLabel(block.key), block.key.branch.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ") }
        })
        lines += workSections(active, in: range, rules: rules, projects: projects, directory: directory)
        section("Websites", ranked(active, in: range, limit: 15) { $0.key.url })
        let sessions = claudeTotals(active, in: range)
        if !sessions.isEmpty {
            lines += ["", "## Claude sessions"] + sessions.map { total in
                "- \(total.label) \u{00B7} \(hoursText(total.seconds))" + (total.attended > 0 ? " \u{00B7} with you \(hoursText(total.attended))" : "")
            }
        }
        section("Windows", ranked(active, in: range, limit: 12) { block in
            block.key.repo == nil && block.key.url == nil ? block.key.windowTitle : nil
        })
        section("Categories", categoryTotals(active, in: range).map { ($0.name, $0.seconds) })
        let excerpts = active.compactMap { block in (block.claudePrompt ?? block.typedExcerpt).map { (block, $0) } }
            .sorted { $0.0.end > $1.0.end }.prefix(5)
        if !excerpts.isEmpty {
            lines += ["", "## Writing"] + excerpts.map { block, text in
                "- \(block.claudeFocusSession?.title ?? block.key.appName ?? "") \u{00B7} \u{201C}\(truncate(text, to: 200))\u{201D}"
            }
        }
        if !meetings.isEmpty {
            lines += ["", "## Meetings"] + meetings.map { meeting in
                "- " + [time(meeting.date), meeting.title, meeting.duration.map(hoursText)].compactMap { $0 }.joined(separator: " \u{00B7} ")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Per session the time it was working or being typed into, and of that the time the user was in it.
    private static func claudeTotals(_ blocks: [ActivityBlock], in range: Range<Date>) -> [(label: String, seconds: TimeInterval, attended: TimeInterval)] {
        var totals: [String: (seconds: TimeInterval, attended: TimeInterval)] = [:]
        for block in blocks {
            for session in block.key.claude {
                let label = "\(session.title) (\(URL(fileURLWithPath: session.folder).lastPathComponent))"
                totals[label, default: (0, 0)].seconds += block.seconds(in: range)
                if session.id == block.key.claudeFocus { totals[label]!.attended += block.seconds(in: range) }
            }
        }
        return totals.sorted { $0.value.seconds != $1.value.seconds ? $0.value.seconds > $1.value.seconds : $0.key < $1.key }
            .map { ($0.key, $0.value.seconds, $0.value.attended) }
    }

    private static func ranked(_ blocks: [ActivityBlock], in range: Range<Date>, limit: Int = 10,
                               _ label: (ActivityBlock) -> String?) -> [(String, TimeInterval)] {
        var seconds: [String: TimeInterval] = [:]
        for block in blocks {
            if let label = label(block) { seconds[label, default: 0] += block.seconds(in: range) }
        }
        return seconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { ($0.key, $0.value) }
    }

    /// `--context [hours]`: the hours to summarise, 8 when not given.
    static func contextArguments(_ arguments: [String]) -> Double? {
        guard let index = arguments.firstIndex(of: "--context") else { return nil }
        guard index + 1 < arguments.count, let hours = Double(arguments[index + 1]), hours > 0 else { return 8 }
        return hours
    }
}

/// Waits for the text around the cursor to stop changing before it is kept.
struct TypingWatch: Equatable {
    static let settleSeconds: TimeInterval = 5

    private var text: String?
    private var since = Date.distantPast
    private var kept: String?

    /// Returns the excerpt to store once the same text has been seen for `settleSeconds`, each new text once.
    mutating func update(_ excerpt: String?, now: Date) -> String? {
        if excerpt != text {
            text = excerpt
            since = now
            return nil
        }
        guard let excerpt, excerpt != kept, now.timeIntervalSince(since) >= Self.settleSeconds else { return nil }
        kept = excerpt
        return excerpt
    }

    /// A new block starts without a kept excerpt, so the settled text is stored for it too.
    mutating func blockChanged() { kept = nil }
}

/// Classifies blocks with Apple Intelligence: the pure parts (cache key, prompt, result mapping).
enum ActivityAI {
    struct Classification: Equatable {
        var category: ActivityCategory
        var description: String?
        var projectID: Int64?
        var work: Bool?
    }

    typealias Answer = (category: String, description: String?, project: String?, work: Bool?)

    static let instructions = """
        You label short records of what someone was doing on their Mac. Use only the given app, window title, address, \
        repository and text. category: the single best match from the list. description: at most eight words saying what \
        was being done, e.g. "Reviewing the reminder fee pull request", in English. project: "none" unless the record clearly \
        belongs to a listed project, meaning its name or one of the repositories, organisations, ticket prefixes or websites \
        listed for it appears in the record; otherwise choose exactly that project name. work: true when it is part of someone's job (code, \
        tickets, documents, meetings, work email or chat, anything for the listed projects), false for entertainment, \
        shopping, social media, news and private errands.
        """

    /// Equal for repeats of the same work: counters, sizes and numbers in titles do not matter.
    static func cacheKey(_ key: ActivityKey) -> String {
        let title = (key.windowTitle ?? "").lowercased()
            .replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let session = key.claudeFocus.flatMap { id in key.claude.first { $0.id == id } }.map { [$0.title.lowercased()] } ?? []
        return ([key.appBundle ?? key.appName ?? "", title, key.url ?? "", key.repo ?? ""] + session).joined(separator: "|")
    }

    static func prompt(for block: ActivityBlock, projects: [Project], rules: [ProjectRule] = []) -> String {
        let key = block.key
        var lines = ["App: \(key.appName ?? key.appBundle ?? "unknown")"]
        if let title = key.windowTitle { lines.append("Window: \(title)") }
        if let url = key.url { lines.append("Address: \(url)") }
        if let link = key.codeHost { lines.append("Code host: \(link.promptText)") }
        if key.repo != nil { lines.append("Repository: \(ActivityLogic.repoLabel(key))" + (key.branch.map { " on branch \($0)" } ?? "")) }
        if let ticket = key.ticket { lines.append("Ticket: \(ticket)") }
        if let session = block.claudeFocusSession { lines.append("Claude Code session: \(session.title)") }
        if let prompt = block.claudePrompt { lines.append("Last request to Claude: \(prompt)") }
        if let excerpt = block.typedExcerpt { lines.append("Text being written: \(ActivityLogic.truncate(excerpt, to: 200))") }
        lines.append("Projects: " + (projects.isEmpty ? "none" : projects.map { describe($0, rules: rules) }.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }

    private static func describe(_ project: Project, rules: [ProjectRule]) -> String {
        let evidence = rules.filter { $0.projectID == project.id }.map { "\($0.field.label.lowercased()) \($0.pattern)" }
        return evidence.isEmpty ? project.name : "\(project.name) (\(evidence.joined(separator: "; ")))"
    }

    /// Whether the block gives a reason to think it belongs to the project: one of the project's rules matches it, its
    /// text mentions the project's name, or it names no repository, organisation or ticket prefix that could belong elsewhere.
    static func hasEvidence(_ block: ActivityBlock, for project: Project, rules: [ProjectRule]) -> Bool {
        let key = block.key
        if rules.contains(where: { $0.projectID == project.id && $0.matches(key) }) { return true }
        let name = project.name.lowercased()
        let texts = [key.windowTitle, key.url, key.repo, key.owner, key.branch, key.ticket, block.claudeFocusSession?.title]
        if texts.contains(where: { $0.map { ActivityLogic.containsWord($0.lowercased(), name) } ?? false }) { return true }
        return key.repo == nil && key.owner == nil && key.ticketPrefix == nil
    }

    /// The guessed project when the block gives a reason for it, else nil.
    static func vetted(_ id: Int64?, for block: ActivityBlock, projects: [Project], rules: [ProjectRule]) -> Int64? {
        guard let id, let project = projects.first(where: { $0.id == id }), hasEvidence(block, for: project, rules: rules) else { return nil }
        return id
    }

    static var projectChoices: (_ projects: [Project]) -> [String] { { ["none"] + $0.map(\.name) } }

    static func classification(category: String?, description: String?, project: String?, work: Bool? = nil, projects: [Project]) -> Classification {
        let category = category.flatMap { raw in ActivityCategory.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } } ?? .other
        let words = description?.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        let project = project.flatMap { name in projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        return Classification(category: category, description: words.flatMap { $0.isEmpty ? nil : $0 }, projectID: project?.id, work: work)
    }
}
