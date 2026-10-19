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
    private var branches = BranchIndex()
    private static let backfilledKey = "activityLinksBackfilled"
    private var cleanedUp = Date.distantPast
    private var typing = TypingWatch()
    private let claude = ClaudeSessionScanner()
    private var inbox = ClaudeInbox(url: AppPaths.claudeInbox)
    private var hookSessions = ClaudeSessions()

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
        if store.isAvailable, !UserDefaults.standard.bool(forKey: Self.backfilledKey) {
            backfillLinks()
            UserDefaults.standard.set(true, forKey: Self.backfilledKey)
        }
        tick()
    }

    /// Fills the repository, owner and branch of stored blocks from their addresses; returns how many changed.
    @discardableResult
    func backfillLinks() -> Int {
        flush()
        do {
            let count = try store.backfillLinks(branches: branchIndex(Date()))
            FileHandle.standardError.write(Data("Activity links filled in for \(count) blocks\n".utf8))
            return count
        } catch {
            FileHandle.standardError.write(Data("Activity links not filled in: \(error.localizedDescription)\n".utf8))
            return 0
        }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ActivitySettings.enabledKey)
        if enabled, !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
    }

    func setPaused(_ paused: Bool) {
        UserDefaults.standard.set(paused, forKey: ActivitySettings.pausedKey)
    }

    func setList(_ list: [String], forKey key: String) {
        UserDefaults.standard.set(list, forKey: key)
    }

    /// Adds `entry` to the list under `key` unless it is there already (apps compare without case).
    func add(_ entry: String, toListAt key: String) {
        let list = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !list.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) else { return }
        setList(list + [entry], forKey: key)
    }

    func remove(_ entry: String, fromListAt key: String) {
        let list = UserDefaults.standard.stringArray(forKey: key) ?? []
        setList(list.filter { $0.caseInsensitiveCompare(entry) != .orderedSame }, forKey: key)
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
        guard let filtered = ActivityLogic.filtered(sample, settings: settings) else { return flush() }
        let result = ActivityLogic.collapse(current, with: filtered)
        if let closed = result.closed {
            save(closed)
            typing.blockChanged()
        }
        var open = result.open
        if open.id == 0 {
            open.id = saveReturningID(open)
            _ = try? store.learnTickets(from: open.key)
        } else {
            save(open)
        }
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
        let now = Date()
        hookSessions.apply(inbox.read())
        guard isTracking else { return flush() }
        cleanUp(now)
        if away || idleSeconds() > settings.idleSeconds { return ingest(.idle(at: now)) }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return ingest(.idle(at: now)) }
        var sample = ActivitySample(time: now, appBundle: app.bundleIdentifier, appName: app.localizedName)
        sample.windowTitle = Self.focusedWindowTitle(of: app.processIdentifier)
        if settings.urls || settings.needsHost, let bundle = app.bundleIdentifier, Browsers.supports(bundle) {
            sample.url = ActivityLogic.cleanURL(Browsers.frontURL(of: bundle))
        }
        if settings.git, DeveloperApps.contains(app.bundleIdentifier), let repo = ActivityLogic.repository(inTitle: sample.windowTitle, repositories: repositories(now)) {
            sample.repo = repo.lastPathComponent
            sample.branch = ActivityLogic.branch(ofRepository: repo)
        }
        if settings.claude { addClaude(to: &sample, now: now) }
        sample.ticket = ActivityLogic.ticket(in: sample.branch, sample.claudeFocus.flatMap { id in sample.claude.first { $0.id == id }?.title },
                                             sample.windowTitle, sample.url)
        sample.link(branches: branchIndex(now))
        ingest(sample)
        let excerpt = settings.typing && current != nil && current?.key.redaction == nil && !IsSecureEventInputEnabled()
            ? Self.focusedTextExcerpt(of: app.processIdentifier) : nil
        if let kept = typing.update(excerpt, now: now), current != nil {
            current?.typedExcerpt = kept
            save(current!)
        }
    }

    /// The sessions working, and while Claude is frontmost the one the user is in, with its repository and branch.
    private func addClaude(to sample: inout ActivitySample, now: Date) {
        let activity = claudeActivity(now)
        sample.claude = activity.filter(\.working).map(\.session)
        guard ActivityLogic.isClaudeWindow(bundle: sample.appBundle, title: sample.windowTitle) else { return }
        let open = current?.key.appBundle == sample.appBundle ? current : nil
        guard let id = ActivityLogic.focusedSession(activity, now: now, window: ActivitySettings.claudeLookback, sticky: open?.key.claudeFocus),
              let session = activity.first(where: { $0.session.id == id })?.session ?? open?.key.claude.first(where: { $0.id == id }) else { return }
        sample.claudeFocus = id
        if !sample.claude.contains(session) { sample.claude.append(session) }
        sample.claudePrompt = activity.first { $0.session.id == id }?.lastPrompt
        if settings.git, let checkout = ActivityLogic.claudeCheckout(cwd: session.folder) {
            sample.repo = checkout.repo
            sample.branch = ActivityLogic.branch(ofRepository: checkout.checkout)
        }
    }

    /// The sessions the plugin's hook events report; sessions it has not seen (started before it was installed, or
    /// without it) come from their transcripts being written to.
    private func claudeActivity(_ now: Date) -> [ClaudeActivity] {
        hookSessions.forget(before: now.addingTimeInterval(-ClaudeSessions.keep))
        let reported = hookSessions.active(now: now, lookback: ActivitySettings.claudeLookback).compactMap { state, working -> ClaudeActivity? in
            let transcript = state.transcriptPath.map { URL(fileURLWithPath: $0) }
            let parsed = transcript.flatMap(claude.session)
            let session = ClaudeSession(id: state.id, folder: state.cwd.isEmpty ? parsed?.folder ?? "" : state.cwd,
                                        title: parsed?.title ?? "Untitled session")
            let prompt = state.prompt.flatMap { ActivityLogic.promptExcerpt($0) } ?? transcript.flatMap(claude.lastUser)?.text
            return ClaudeActivity(session: session, lastUser: state.lastPrompt, lastPrompt: prompt, working: working)
        }
        let known = hookSessions.ids
        return reported + claude.active(since: now.addingTimeInterval(-ActivitySettings.claudeLookback)).filter { !known.contains($0.session.id) }
    }

    private func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func repositories(_ now: Date) -> [URL] {
        if now.timeIntervalSince(repositoriesScanned) > 300 {
            repositories = ActivityLogic.repositories(under: repositoriesRoot)
            branches = BranchIndex.scan(repositories)
            repositoriesScanned = now
        }
        return repositories
    }

    private func branchIndex(_ now: Date) -> BranchIndex {
        _ = repositories(now)
        return branches
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
    private var tails: [String: (modified: Date, user: (time: Date?, text: String)?)] = [:]
    private static let tailBytes: UInt64 = 256_000

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.root = root
    }

    func active(since: Date) -> [ClaudeActivity] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let projects = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var sessions: [ClaudeActivity] = []
        for project in projects {
            let files = (try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= since else { continue }
                if let session = session(file) {
                    let user = lastUser(file, modified: modified)
                    sessions.append(ClaudeActivity(session: session, lastUser: user?.time, lastPrompt: user?.text))
                }
            }
        }
        return sessions.sorted { $0.session.id < $1.session.id }
    }

    func lastUser(_ file: URL) -> (time: Date?, text: String)? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.flatMap { lastUser(file, modified: $0) }
    }

    /// The last message the user typed, from the end of the transcript; re-read only when the file changed.
    private func lastUser(_ file: URL, modified: Date) -> (time: Date?, text: String)? {
        if let cached = tails[file.path], cached.modified == modified { return cached.user }
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        let offset = size > Self.tailBytes ? size - Self.tailBytes : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        let user = ActivityLogic.lastUserMessage(inJSONL: text)
        tails[file.path] = (modified, user)
        return user
    }

    /// The session of a transcript, with its title; nil until its first user message is written.
    func session(_ file: URL) -> ClaudeSession? {
        let id = file.deletingPathExtension().lastPathComponent
        let project = file.deletingLastPathComponent()
        let sidecar = project.appendingPathComponent(id).appendingPathComponent("custom-title.json")
        let customTitle = (try? Data(contentsOf: sidecar)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["customTitle"] as? String
        if let cached = cache[file.path] {
            return customTitle.map { ClaudeSession(id: id, folder: cached.folder, title: ActivityLogic.truncate($0, to: 80)) } ?? cached
        }
        guard let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 512_000) else { return nil }
        try? handle.close()
        guard let parsed = ActivityLogic.claudeSession(id: id, jsonl: String(decoding: data, as: UTF8.self), customTitle: customTitle) else {
            return ClaudeSession(id: id, folder: ActivityLogic.decodeProjectFolder(project.lastPathComponent), title: customTitle ?? "Untitled session")
        }
        cache[file.path] = parsed
        return parsed
    }
}
