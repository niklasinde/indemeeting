import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Samples the frontmost app every few seconds and keeps the open block in the store. Nothing is sampled until the
/// user turns tracking on and grants Accessibility; a lock, sleep or idle period becomes an "away" block.
@MainActor
final class ActivityTracker: ObservableObject {
    @Published private(set) var current: ActivityBlock?
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var settings: ActivitySettings

    private let store: MeetingStore
    private let repositoriesRoot: URL
    private var timer: Timer?
    private var observers: [Any] = []
    private var away = false
    private var repositories: [URL] = []
    private var repositoriesScanned = Date.distantPast
    private var cleanedUp = Date.distantPast
    private var typing = TypingWatch()
    private let claude = ClaudeSessionScanner()

    init(store: MeetingStore, repositoriesRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("git")) {
        self.store = store
        self.repositoriesRoot = repositoriesRoot
        UserDefaults.standard.register(defaults: ActivitySettings.defaults)
        settings = ActivitySettings(.standard)
    }

    var isTracking: Bool { settings.enabled && !settings.paused && accessibilityGranted && store.isAvailable }

    /// A short line for the menu: what is being tracked, or why nothing is.
    var statusText: String? {
        guard settings.enabled else { return nil }
        if settings.paused { return "Activity tracking paused" }
        if !accessibilityGranted { return "Activity tracking needs Accessibility access" }
        guard let current else { return "Activity tracking on" }
        if current.key.idle { return "Away \u{00B7} \(ActivityLogic.hoursText(current.duration))" }
        return "Tracking \(current.key.appName ?? "") \u{00B7} \(ActivityLogic.hoursText(current.duration))"
    }

    func start() {
        guard timer == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setAway(true) },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setAway(false) },
            distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                self?.setAway(true)
            },
            distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                self?.setAway(false)
            },
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsChanged() }
            },
        ]
        timer = Timer.scheduledTimer(withTimeInterval: ActivitySettings.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ActivitySettings.enabledKey)
        if enabled, !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
    }

    func setPaused(_ paused: Bool) {
        UserDefaults.standard.set(paused, forKey: ActivitySettings.pausedKey)
    }

    func setExcludedApps(_ apps: [String]) {
        UserDefaults.standard.set(apps, forKey: ActivitySettings.excludedKey)
    }

    func setExcludedCategories(_ categories: [ActivityCategory]) {
        UserDefaults.standard.set(categories.map(\.rawValue), forKey: ActivitySettings.excludedCategoriesKey)
    }

    /// Writes the open block and forgets it, so what follows starts a new one.
    func flush() {
        guard let current else { return }
        save(current)
        self.current = nil
    }

    /// Forgets the open block without writing it when it is about to be deleted, so the next sample starts a new one.
    /// The typed text already kept is not stored again for that block.
    func discard(where matches: (ActivityBlock) -> Bool) {
        guard let current, matches(current) else { return }
        self.current = nil
    }

    /// Feeds one sample through the same path as the timer, for tests and `--simulate-activity`.
    func ingest(_ sample: ActivitySample, now: Date? = nil) {
        let filtered = ActivityLogic.filtered(sample, settings: settings)
        let result = ActivityLogic.collapse(current, with: filtered)
        if let closed = result.closed {
            save(closed)
            typing.blockChanged()
        }
        var open = result.open
        if open.id == 0 { open.id = saveReturningID(open) } else { save(open) }
        current = open
    }

    private func setAway(_ away: Bool) {
        self.away = away
        if away { tick() } else { flush() }
    }

    private func settingsChanged() {
        let changed = ActivitySettings(.standard)
        guard changed != settings else { return }
        let wasTracking = isTracking
        settings = changed
        if wasTracking, !isTracking { flush() }
    }

    private func tick() {
        accessibilityGranted = Permissions.accessibilityGranted
        guard isTracking else { return flush() }
        let now = Date()
        cleanUp(now)
        if away || idleSeconds() > settings.idleSeconds { return ingest(.idle(at: now)) }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return ingest(.idle(at: now)) }
        var sample = ActivitySample(time: now, appBundle: app.bundleIdentifier, appName: app.localizedName)
        sample.windowTitle = Self.focusedWindowTitle(of: app.processIdentifier)
        if settings.urls, let bundle = app.bundleIdentifier, Browsers.supports(bundle) {
            sample.url = ActivityLogic.cleanURL(Browsers.frontURL(of: bundle))
        }
        if settings.git, DeveloperApps.contains(app.bundleIdentifier), let repo = ActivityLogic.repository(inTitle: sample.windowTitle, repositories: repositories(now)) {
            sample.repo = repo.lastPathComponent
            sample.branch = ActivityLogic.branch(ofRepository: repo)
        }
        sample.ticket = ActivityLogic.ticket(in: sample.branch, sample.windowTitle, sample.url)
        if settings.claude { sample.claude = claude.active(since: now.addingTimeInterval(-2 * ActivitySettings.interval)) }
        ingest(sample)
        let excerpt = settings.typing && !settings.excludes(appName: sample.appName, bundle: sample.appBundle) && !IsSecureEventInputEnabled()
            ? Self.focusedTextExcerpt(of: app.processIdentifier) : nil
        if let kept = typing.update(excerpt, now: now), current != nil {
            current?.typedExcerpt = kept
            save(current!)
        }
    }

    private func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func repositories(_ now: Date) -> [URL] {
        if now.timeIntervalSince(repositoriesScanned) > 300 {
            repositories = ActivityLogic.repositories(under: repositoriesRoot)
            repositoriesScanned = now
        }
        return repositories
    }

    private func cleanUp(_ now: Date) {
        guard !Calendar.current.isDate(cleanedUp, inSameDayAs: now) else { return }
        cleanedUp = now
        try? store.deleteBlocks(before: now.addingTimeInterval(-Double(settings.retentionDays) * 86_400))
    }

    private func save(_ block: ActivityBlock) {
        _ = saveReturningID(block)
    }

    private func saveReturningID(_ block: ActivityBlock) -> Int64 {
        do {
            return try store.saveBlock(block)
        } catch {
            FileHandle.standardError.write(Data("Activity not saved: \(error.localizedDescription)\n".utf8))
            return block.id
        }
    }

    /// The text around the insertion point of the app's focused text field or area. Secure fields are never read.
    nonisolated static func focusedTextExcerpt(of pid: pid_t) -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let field = focused as! AXUIElement
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(field, attribute as CFString, &value) == .success ? value as? String : nil
        }
        guard [kAXTextAreaRole, kAXTextFieldRole].contains(string(kAXRoleAttribute) ?? ""),
              string(kAXSubroleAttribute) != kAXSecureTextFieldSubrole, let text = string(kAXValueAttribute) else { return nil }
        var cursor = text.count
        var selection: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selection) == .success, let selection,
           CFGetTypeID(selection) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(selection as! AXValue, .cfRange, &range) { cursor = range.location + range.length }
        }
        return ActivityLogic.excerpt(value: text, cursor: cursor)
    }

    /// The title of the app's focused (else main) window through Accessibility.
    nonisolated static func focusedWindowTitle(of pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &window) == .success, let window else { continue }
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
               let title = title as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }
}

/// Apps whose window titles name the repository being worked on.
enum DeveloperApps {
    static let bundlePrefixes = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp", "com.mitchellh.ghostty", "com.jetbrains.",
                                 "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "com.anthropic.claudefordesktop",
                                 "com.sublimetext.", "com.github.GitHubClient", "com.fournova.Tower", "co.zeit.hyper", "org.alacritty"]

    static func contains(_ bundle: String?) -> Bool {
        bundle.map { id in bundlePrefixes.contains { id.hasPrefix($0) } } ?? false
    }
}

/// The URL of the front tab of the frontmost browser, through Apple Events (Automation permission). Firefox has no
/// scripting dictionary, so only its title is captured. Private windows are skipped where the browser says so.
enum Browsers {
    private static let scripts: [String: String] = [
        "com.apple.Safari": """
            tell application id "com.apple.Safari"
                if (count of windows) is 0 then return ""
                return URL of current tab of front window
            end tell
            """,
        "com.google.Chrome": chromium("com.google.Chrome"),
        "com.brave.Browser": chromium("com.brave.Browser"),
        "com.microsoft.edgemac": chromium("com.microsoft.edgemac"),
        "company.thebrowser.Browser": """
            tell application id "company.thebrowser.Browser"
                if (count of windows) is 0 then return ""
                if incognito of front window then return ""
                return URL of active tab of front window
            end tell
            """,
    ]
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

    static func supports(_ bundle: String) -> Bool { scripts[bundle] != nil }

    private static func chromium(_ bundle: String) -> String {
        """
        tell application id "\(bundle)"
            if (count of windows) is 0 then return ""
            if mode of front window is "incognito" then return ""
            return URL of active tab of front window
        end tell
        """
    }

    @MainActor
    static func frontURL(of bundle: String) -> String? {
        guard let source = scripts[bundle] else { return nil }
        let script = compiled[bundle] ?? NSAppleScript(source: source)
        guard let script else { return nil }
        compiled[bundle] = script
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }
}

/// Claude Code sessions whose transcript (`~/.claude/projects/<cwd>/<id>.jsonl`) was written to recently.
final class ClaudeSessionScanner {
    private let root: URL
    private var cache: [String: ClaudeSession] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.root = root
    }

    func active(since: Date) -> [ClaudeSession] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let projects = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var sessions: [ClaudeSession] = []
        for project in projects {
            let files = (try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= since else { continue }
                if let session = session(file, project: project) { sessions.append(session) }
            }
        }
        return sessions.sorted { $0.id < $1.id }
    }

    private func session(_ file: URL, project: URL) -> ClaudeSession? {
        let id = file.deletingPathExtension().lastPathComponent
        let sidecar = project.appendingPathComponent(id).appendingPathComponent("custom-title.json")
        let customTitle = (try? Data(contentsOf: sidecar)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["customTitle"] as? String
        if let cached = cache[file.path] {
            return customTitle.map { ClaudeSession(id: id, folder: cached.folder, title: ActivityLogic.truncate($0, to: 80)) } ?? cached
        }
        guard let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 512_000) else { return nil }
        try? handle.close()
        let parsed = ActivityLogic.claudeSession(id: id, jsonl: String(decoding: data, as: UTF8.self), customTitle: customTitle)
            ?? ClaudeSession(id: id, folder: ActivityLogic.decodeProjectFolder(project.lastPathComponent), title: customTitle ?? "Untitled session")
        cache[file.path] = parsed
        return parsed
    }
}
