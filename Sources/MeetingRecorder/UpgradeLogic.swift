import Foundation

/// The version, build and executable date of an app bundle.
struct BuildIdentity: Equatable {
    let version: String
    let build: String
    let executableModified: Date
}

enum UpgradeLogic {
    static let bannerTitle = "Upgrade is ready. Restart Meeting Recorder to upgrade."
    static let recordingMessage = "A recording is in progress. Restart after it ends."

    enum RestartDecision: Equatable {
        case blocked
        case confirm(sessions: Int)
        case restart
    }

    /// Identity of the bundle at `bundle`, or nil while its Info.plist or executable is missing (a copy still being written).
    static func identity(of bundle: URL) -> BuildIdentity? {
        guard let info = info(of: bundle),
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              let modified = modificationDate(of: executable(of: bundle, info: info))
        else { return nil }
        return BuildIdentity(version: version, build: build, executableModified: modified)
    }

    /// An upgrade is ready when the copy on disk no longer matches the one that launched.
    static func isReady(launched: BuildIdentity, installed: BuildIdentity?) -> Bool {
        installed.map { $0 != launched } ?? false
    }

    static func restartDecision(recording: Bool, sessions: Int) -> RestartDecision {
        if recording { return .blocked }
        return sessions > 0 ? .confirm(sessions: sessions) : .restart
    }

    static func confirmMessage(sessions: Int) -> String {
        "Restarting ends \(sessions) Claude session\(sessions == 1 ? "" : "s"). Their conversations are saved and can be resumed."
    }

    /// Why the newer copy cannot be opened, or nil when it can.
    static func launchProblem(of bundle: URL) -> String? {
        let executable = executable(of: bundle, info: info(of: bundle))
        return FileManager.default.isExecutableFile(atPath: executable.path) ? nil : "The app at \(bundle.path) can't be opened."
    }

    /// Waits for the old process to exit, then opens the bundle as a new instance.
    static func relaunchScript(pid: pid_t, bundle: URL) -> [String] {
        ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n \"$2\"", "sh", String(pid), bundle.path]
    }

    /// The banner stays until Later hides it, and that choice lasts for this launch only.
    static func showsBanner(ready: Bool, dismissed: Bool) -> Bool {
        ready && !dismissed
    }

    private static func info(of bundle: URL) -> [String: Any]? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    private static func executable(of bundle: URL, info: [String: Any]?) -> URL {
        let name = info?["CFBundleExecutable"] as? String ?? "MeetingRecorder"
        return bundle.appendingPathComponent("Contents/MacOS/\(name)")
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
