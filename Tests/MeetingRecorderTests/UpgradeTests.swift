import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private let launchDate = Date(timeIntervalSince1970: 1_800_000_000)

private func identity(version: String = "1.2", build: String = "40", modified: Date = launchDate) -> BuildIdentity {
    BuildIdentity(version: version, build: build, executableModified: modified)
}

/// A bundle with an Info.plist and an executable, in a fresh temporary folder.
private func makeBundle(version: String = "1.2", build: String = "40") throws -> URL {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("upgrade-\(UUID().uuidString).app", isDirectory: true)
    let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleExecutable": "MeetingRecorder", "CFBundleShortVersionString": version, "CFBundleVersion": build]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    let executable = macOS.appendingPathComponent("MeetingRecorder")
    try Data("binary".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try FileManager.default.setAttributes([.modificationDate: launchDate], ofItemAtPath: executable.path)
    return bundle
}

let upgradeTests: [(name: String, run: () throws -> Void)] = [
    ("an upgrade is ready when the version, the build or the executable date changes", {
        let launched = identity()
        check(!UpgradeLogic.isReady(launched: launched, installed: identity()), "same identity is not an upgrade")
        check(UpgradeLogic.isReady(launched: launched, installed: identity(version: "1.3")), "version change")
        check(UpgradeLogic.isReady(launched: launched, installed: identity(build: "41")), "build change")
        check(UpgradeLogic.isReady(launched: launched, installed: identity(modified: launchDate.addingTimeInterval(60))), "executable date change")
        check(!UpgradeLogic.isReady(launched: launched, installed: nil), "a missing installed copy is not an upgrade")
    }),

    ("the identity of a bundle is read from its plist and executable, and a touched executable is a new build", {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        guard let launched = UpgradeLogic.identity(of: bundle) else {
            failures.append("a complete bundle has no identity")
            return
        }
        check(launched == identity(), "identity \(launched)")
        check(!UpgradeLogic.isReady(launched: launched, installed: UpgradeLogic.identity(of: bundle)), "unchanged bundle is not an upgrade")

        let executable = bundle.appendingPathComponent("Contents/MacOS/MeetingRecorder")
        try FileManager.default.setAttributes([.modificationDate: launchDate.addingTimeInterval(120)], ofItemAtPath: executable.path)
        check(UpgradeLogic.isReady(launched: launched, installed: UpgradeLogic.identity(of: bundle)), "touched executable is an upgrade")

        let rebuilt = try makeBundle(build: "41")
        defer { try? FileManager.default.removeItem(at: rebuilt) }
        check(UpgradeLogic.isReady(launched: launched, installed: UpgradeLogic.identity(of: rebuilt)), "a copy with a new build is an upgrade")
        check(UpgradeLogic.identity(of: bundle.appendingPathComponent("missing.app")) == nil, "no bundle has no identity")
    }),

    ("a recording in progress blocks the restart", {
        check(UpgradeLogic.restartDecision(recording: true, sessions: 0) == .blocked, "recording without sessions")
        check(UpgradeLogic.restartDecision(recording: true, sessions: 3) == .blocked, "recording with sessions")
    }),

    ("live Claude sessions need confirmation, and none restarts directly", {
        check(UpgradeLogic.restartDecision(recording: false, sessions: 2) == .confirm(sessions: 2), "two sessions")
        check(UpgradeLogic.restartDecision(recording: false, sessions: 0) == .restart, "no sessions")
        check(UpgradeLogic.confirmMessage(sessions: 2) == "Restarting ends 2 Claude sessions. Their conversations are saved and can be resumed.", "plural")
        check(UpgradeLogic.confirmMessage(sessions: 1).hasPrefix("Restarting ends 1 Claude session."), "singular")
    }),

    ("Later hides the banner, and the banner shows only when an upgrade is ready", {
        check(UpgradeLogic.showsBanner(ready: true, dismissed: false), "ready shows the banner")
        check(!UpgradeLogic.showsBanner(ready: true, dismissed: true), "later hides it")
        check(!UpgradeLogic.showsBanner(ready: false, dismissed: false), "nothing ready, no banner")
        check(UpgradeLogic.bannerTitle == "Upgrade is ready. Restart Meeting Recorder to upgrade.", "title")
    }),

    ("a bundle whose executable cannot be opened is reported before the app quits", {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        check(UpgradeLogic.launchProblem(of: bundle) == nil, "a runnable bundle has no problem")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundle.appendingPathComponent("Contents/MacOS/MeetingRecorder").path)
        check(UpgradeLogic.launchProblem(of: bundle) != nil, "a non-executable bundle is a problem")
    }),

    ("the relaunch waits for the old process and opens the bundle with open -n", {
        let arguments = UpgradeLogic.relaunchScript(pid: 4242, bundle: URL(fileURLWithPath: "/Applications/Meeting Recorder.app"))
        let script = arguments.joined(separator: " ")
        check(script.contains("/usr/bin/open -n \"$2\""), "opens a new instance")
        check(script.contains("kill -0 \"$1\""), "waits for the old pid")
        check(arguments.last == "/Applications/Meeting Recorder.app", "the bundle path is the last argument")
        check(arguments.contains("4242"), "the pid is passed")
    }),

    ("the restart path quits through the normal terminate and never kills the process", {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MeetingRecorder", isDirectory: true)
        let sources = ["AppUpgrade.swift", "UpgradeLogic.swift"]
        let texts = sources.map { (try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) ?? "" }
        for (name, text) in zip(sources, texts) {
            check(!text.contains("kill("), "\(name) has no kill(")
            check(!text.contains("SIGKILL"), "\(name) has no SIGKILL")
        }
        check(texts[0].contains("NSApp.terminate(nil)"), "restart quits through NSApp.terminate")
        check(texts[0].contains("relaunching"), "the quit prompt is bypassed while relaunching")
    }),
]
