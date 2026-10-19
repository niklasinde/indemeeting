import Combine
import Foundation

/// The MeetingRecorder plugin for Claude Code (`plugin/` in this repository), installed through the `claude` CLI.
enum ClaudePlugin {
    static let name = "meetingrecorder"
    static let marketplace = "indemeeting"
    static let githubSource = "niklasinde/indemeeting"
    static var id: String { "\(name)@\(marketplace)" }
    static let slashCommands = "/plugin marketplace add \(githubSource)\n/plugin install \(id)"

    enum Status: Equatable {
        case cliMissing
        case notInstalled
        case installed(lastEvent: Date?)
    }

    static func status(cli: URL?, installed: Bool, lastEvent: Date?) -> Status {
        if installed { return .installed(lastEvent: lastEvent) }
        return cli == nil ? .cliMissing : .notInstalled
    }

    static func statusText(_ status: Status, now: Date) -> String {
        switch status {
        case .cliMissing: return "Claude CLI not found"
        case .notInstalled: return "Not installed"
        case .installed(nil): return "Installed"
        case .installed(let date?): return "Installed \u{00B7} last event \(ago(date, now: now))"
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 86_400 { return ActivityLogic.hoursText(seconds) + " ago" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// Where the `claude` CLI may be, in order: the PATH, the installer's locations, Homebrew, then the newest copy
    /// the Claude app keeps.
    static func cliCandidates(path: String?, home: URL, appVersions: [URL]) -> [URL] {
        let fromPath = (path ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        let known = [".claude/local/claude", ".local/bin/claude"].map { home.appendingPathComponent($0) }
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].map { URL(fileURLWithPath: $0) }
        let bundled = appVersions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .flatMap { version in
                ((try? FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? [])
                    .map { $0.appendingPathComponent("claude.app/Contents/MacOS/claude") }
            }
        var seen = Set<String>()
        return (fromPath + known + bundled).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func findCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        fileManager: FileManager = .default) -> URL? {
        let app = home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
        let versions = (try? fileManager.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? []
        return cliCandidates(path: environment["PATH"], home: home, appVersions: versions)
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Whether `~/.claude/plugins/installed_plugins.json` lists the plugin from any marketplace.
    static func isInstalled(installedPlugins data: Data?) -> Bool {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let plugins = object["plugins"] as? [String: Any] ?? object
        return plugins.contains { key, value in
            key.hasPrefix(name + "@") && !((value as? [Any])?.isEmpty ?? false)
        }
    }

    /// The marketplace's source in `~/.claude/plugins/known_marketplaces.json`: a GitHub repository or a folder.
    static func marketplaceSource(knownMarketplaces data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = (object[marketplace] as? [String: Any])?["source"] as? [String: Any] else { return nil }
        return (source["repo"] ?? source["path"] ?? source["url"]) as? String
    }

    /// A checkout of this repository to install from while developing: next to the app, else `~/git/inde/indemeeting`.
    static func localCheckout(app: URL = Bundle.main.bundleURL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              fileManager: FileManager = .default) -> URL? {
        [app.deletingLastPathComponent(), home.appendingPathComponent("git/inde/indemeeting")].first {
            fileManager.fileExists(atPath: $0.appendingPathComponent(".claude-plugin/marketplace.json").path)
                && fileManager.fileExists(atPath: $0.appendingPathComponent("plugin/.claude-plugin/plugin.json").path)
        }?.standardizedFileURL
    }

    /// `install --marketplace` adds the marketplace first when it is not there yet.
    static func installArguments(source: String) -> [[String]] {
        [["plugin", "install", name, "--marketplace", source]]
    }

    /// The marketplace goes too, so the next install can come from another source.
    static let removeArguments = [["plugin", "uninstall", id], ["plugin", "marketplace", "remove", marketplace]]
}

/// Runs the `claude` CLI for the Settings buttons, off the main thread, and keeps what it printed.
@MainActor
final class ClaudePluginModel: ObservableObject {
    @Published private(set) var cli: URL?
    @Published private(set) var installed = false
    @Published private(set) var source: String?
    @Published private(set) var output: String?
    @Published private(set) var running = false
    let localCheckout = ClaudePlugin.localCheckout()
    private let plugins = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plugins", isDirectory: true)

    func refresh() {
        cli = ClaudePlugin.findCLI()
        installed = ClaudePlugin.isInstalled(installedPlugins: try? Data(contentsOf: plugins.appendingPathComponent("installed_plugins.json")))
        source = installed ? ClaudePlugin.marketplaceSource(knownMarketplaces: try? Data(contentsOf: plugins.appendingPathComponent("known_marketplaces.json"))) : nil
    }

    func install(fromLocal: Bool) {
        let source = fromLocal ? localCheckout?.path : ClaudePlugin.githubSource
        run(ClaudePlugin.installArguments(source: source ?? ClaudePlugin.githubSource))
    }

    func remove() { run(ClaudePlugin.removeArguments) }

    private func run(_ commands: [[String]]) {
        guard let cli, !running else { return }
        running = true
        output = nil
        Task {
            let text = await Task.detached { Self.run(cli, commands) }.value
            output = text
            running = false
            refresh()
        }
    }

    /// The app's environment with the CLI's folder and the usual tool folders on the PATH, which a menu bar app starts without.
    nonisolated static func environment(for cli: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [cli.deletingLastPathComponent().path, environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
            .compactMap { $0 }.joined(separator: ":")
        return environment
    }

    nonisolated static func run(_ cli: URL, _ commands: [[String]]) -> String {
        var lines: [String] = []
        for arguments in commands {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = environment(for: cli)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            lines.append("$ claude " + arguments.joined(separator: " "))
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
                if process.terminationStatus != 0 {
                    lines.append("Failed with exit code \(process.terminationStatus)")
                    break
                }
            } catch {
                lines.append(error.localizedDescription)
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}
