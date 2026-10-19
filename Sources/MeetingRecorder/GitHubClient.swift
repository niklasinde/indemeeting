import Foundation

/// Reads pull requests through the user's own `gh` CLI, which holds the sign-in; the app never sees a token.
enum GitHubClient {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    struct Fetch {
        var prs: [GitHubKind: [GitHubPR]] = [:]
        var error: GitHubError?
    }

    nonisolated static func run(_ cli: URL, _ arguments: [String]) -> Output? {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [cli.deletingLastPathComponent().path, environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
            .compactMap { $0 }.joined(separator: ":")
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        nonisolated(unsafe) var errorData = Data()
        let reader = DispatchGroup()
        DispatchQueue.global().async(group: reader) { errorData = err.fileHandleForReading.readDataToEndOfFile() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        reader.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: data, stderr: String(decoding: errorData, as: UTF8.self))
    }

    /// Every tab's pull requests. A tab that cannot be fetched is left out, so its cached rows stay. A single-sign-on
    /// error keeps what the other organisations returned and is reported alongside.
    nonisolated static func fetchAll(cli: URL?) -> Fetch {
        guard let cli else { return Fetch(error: .cliMissing) }
        guard let auth = run(cli, GitHubLogic.authArguments) else { return Fetch(error: .cliMissing) }
        if auth.status != 0 {
            let error = GitHubError.classify(auth.stderr)
            return Fetch(error: error == .rateLimited || error == .offline ? error : .notLoggedIn)
        }
        var fetch = Fetch()
        for kind in GitHubKind.allCases {
            var rows: [GitHubPR] = []
            var failed = false
            for search in GitHubLogic.searches(for: kind) {
                guard let output = run(cli, GitHubLogic.arguments(for: search)) else { return Fetch(prs: fetch.prs, error: .cliMissing) }
                let parsed = try? GitHubLogic.parse(output.stdout)
                if output.status != 0 || parsed == nil {
                    let error = output.status != 0 ? GitHubError.classify(output.stderr) : .failed("unexpected response")
                    fetch.error = fetch.error ?? error
                    if error == .rateLimited { return fetch }
                    failed = failed || parsed == nil
                }
                rows += parsed ?? []
            }
            if !failed { fetch.prs[kind] = rows }
        }
        return fetch
    }

    /// `--github-prs`: prints how many pull requests each tab holds and the newest rows. Reads GitHub, writes nothing.
    static func runFromCommandLine() -> Never {
        let fetch = fetchAll(cli: GitHubLogic.findCLI())
        for kind in GitHubKind.allCases {
            guard let prs = fetch.prs[kind] else { continue }
            let open = prs.filter { $0.state == .open }.count
            print("\(kind.tabTitle): \(prs.count) fetched, \(open) open")
            for pr in GitHubLogic.filter(prs, .init(state: .all)).prefix(5) {
                print("  \(pr.repo) #\(pr.number) [\(pr.state.rawValue)\(pr.isDraft ? ", draft" : ""), checks \(pr.checks.rawValue), "
                      + "review \(pr.review?.rawValue ?? "none")] \(pr.title)  \(GitHubLogic.changesText(additions: pr.additions, deletions: pr.deletions))")
            }
        }
        print(GitHubLogic.menuSummary(fetch.prs))
        if let error = fetch.error {
            FileHandle.standardError.write(Data("Failed: \(error.message)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
