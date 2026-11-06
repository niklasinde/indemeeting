import AppKit
import Combine

/// Gives a new recording its row with its audio expiry, and records which app its call is in, and its name. Within
/// the first minute the source is looked at again and updated once if the window says more by then.
@MainActor
final class MeetingSourceTracker {
    static let checks: [TimeInterval] = [0, 15, 30, 45, 60]

    private let recorder: Recorder
    private let store: MeetingStore
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?

    init(recorder: Recorder, store: MeetingStore) {
        self.recorder = recorder
        self.store = store
    }

    func start() {
        subscription = recorder.$meeting.removeDuplicates().sink { [weak self] in self?.follow($0) }
    }

    private func follow(_ meeting: URL?) {
        task?.cancel()
        guard let file = meeting?.lastPathComponent else { return }
        let created = RecordingLogic.date(fromFileName: file) ?? Date()
        try? store.beginRecording(file, created: created,
                                  audioExpiresAt: AudioRetention.expiry(created: created, developerMode: AudioRetention.developerMode()))
        task = Task { [weak self] in
            let started = Date()
            var stored: MeetingSource?
            for check in Self.checks {
                try? await Task.sleep(nanoseconds: UInt64(max(0, check - Date().timeIntervalSince(started)) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let found = Self.detect()
                guard let current = stored else {
                    guard let found else { continue }
                    stored = try? store.setSource(file, found)
                    if stored != found { return }
                    continue
                }
                if let better = MeetingSourceLogic.refined(current, with: found) {
                    try? store.setSource(file, better, replacing: true)
                    return
                }
            }
        }
    }

    /// The source of the call, looked for in the apps taking the microphone, then any app with a call in it, then
    /// the frontmost app. Window titles come through Accessibility and browser tabs through Apple Events, both only
    /// where the activity tracker already has the permission; nothing is asked for.
    static func detect() -> MeetingSource? {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        let micUsers = MicUsers.others(MicrophoneActivityMonitor.inputUsers, ownPID: getpid(), ownBundleID: Bundle.main.bundleIdentifier)
        let owners = MeetingApps.candidates(micOwners: micUsers.sorted(), frontmost: nil, running: [])
        let frontmost = workspace.frontmostApplication?.bundleIdentifier
        let candidates = MeetingApps.candidates(micOwners: owners, frontmost: frontmost, running: apps.compactMap(\.bundleIdentifier))
        func source(_ bundle: String, trusted: Bool) -> MeetingSource? {
            guard let app = apps.first(where: { $0.bundleIdentifier == bundle }) else { return nil }
            let tabs = Browsers.supports(bundle) && Permissions.automationGranted(bundle) ? Browsers.tabs(of: bundle) : []
            return MeetingSourceLogic.source(app: bundle, trusted: trusted, windowTitles: ActivityTracker.windowTitles(of: app.processIdentifier),
                                             tabs: tabs)
        }
        return candidates.lazy.compactMap { source($0, trusted: owners.contains($0)) }.first
            ?? frontmost.flatMap { candidates.contains($0) ? source($0, trusted: true) : nil }
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundle: String) -> NSImage? {
        if let icon = cache[bundle] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundle] = icon
        return icon
    }
}
