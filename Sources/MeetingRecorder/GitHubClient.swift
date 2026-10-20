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
        /// GraphQL points the searches cost, and what was left of the hourly allowance after the last one.
        var cost = 0
        var remaining: Int?
    }

    nonisolated static func run(_ cli: URL, _ arguments: [String], directory: URL? = nil) -> Output? {
        let process = Process()
        process.currentDirectoryURL = directory
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
                let page = try? GitHubLogic.parsePage(output.stdout)
                let parsed = page?.prs
                fetch.cost += page?.cost ?? 0
                fetch.remaining = page?.remaining ?? fetch.remaining
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

    /// One pull request in full, with the response it was parsed from so it can be cached.
    nonisolated static func fetchDetail(cli: URL?, repo: String, number: Int) -> Result<(detail: GitHubPRDetail, json: Data), GitHubError> {
        guard let cli, let output = run(cli, GitHubLogic.detailArguments(repo: repo, number: number)) else { return .failure(.cliMissing) }
        if output.status != 0, (try? GitHubLogic.parseDetail(output.stdout)) == nil { return .failure(GitHubError.classify(output.stderr)) }
        do { return .success((try GitHubLogic.parseDetail(output.stdout), output.stdout)) } catch {
            return .failure(error as? GitHubError ?? .failed("unexpected response"))
        }
    }

    /// One page of a pull request's comments, the first or the one after `cursors`, with the response it was parsed from.
    nonisolated static func fetchComments(cli: URL?, repo: String, number: Int, after cursors: GitHubComments.Cursors? = nil)
        -> Result<(page: GitHubComments, json: Data), GitHubError> {
        guard let cli, let output = run(cli, GitHubLogic.commentsArguments(repo: repo, number: number, after: cursors)) else { return .failure(.cliMissing) }
        if output.status != 0, (try? GitHubLogic.parseComments(output.stdout)) == nil { return .failure(GitHubError.classify(output.stderr)) }
        do { return .success((try GitHubLogic.parseComments(output.stdout), output.stdout)) } catch {
            return .failure(error as? GitHubError ?? .failed("unexpected response"))
        }
    }

    /// `--github-pr <owner/repo#n>`: prints the parsed summary of one pull request. Reads GitHub, writes nothing.
    static func runDetailFromCommandLine(_ reference: String) -> Never {
        guard let target = GitHubLogic.reference(reference) else {
            FileHandle.standardError.write(Data("Usage: --github-pr owner/repo#number\n".utf8))
            exit(2)
        }
        switch fetchDetail(cli: GitHubLogic.findCLI(), repo: target.repo, number: target.number) {
        case .success(let result):
            print(GitHubLogic.summary(result.detail, now: Date()))
            let started = Date()
            _ = try? GitHubLogic.parseDetail(result.json)
            print(String(format: "Parse of the cached response: %.1f ms for %d bytes", Date().timeIntervalSince(started) * 1000, result.json.count))
            if let limit = GitHubLogic.detailCost(result.json) {
                print("GraphQL cost: \(limit.cost) points, \(limit.remaining.map(String.init) ?? "?") left of the hourly allowance")
            }
            exit(0)
        case .failure(let error):
            FileHandle.standardError.write(Data("Failed: \(error.message)\n".utf8))
            exit(1)
        }
    }

    /// `--github-prs`: prints how many pull requests each tab holds and the newest rows. Reads GitHub, writes nothing.
    static func runFromCommandLine() -> Never {
        let fetch = fetchAll(cli: GitHubLogic.findCLI())
        for kind in GitHubKind.allCases {
            guard let prs = fetch.prs[kind] else { continue }
            let open = prs.filter { $0.state == .open }.count
            print("\(kind.tabTitle): \(prs.count) fetched, \(open) open")
            for pr in GitHubLogic.filter(prs, .init(state: .open, sort: .needsAttention)).prefix(8) {
                print("  \(pr.repo) #\(pr.number) [\(pr.state.rawValue)\(pr.isDraft ? ", draft" : ""), checks \(pr.checks.rawValue), "
                      + "review \(pr.review?.rawValue ?? "none")] \(pr.title)  \(GitHubLogic.changesText(additions: pr.additions, deletions: pr.deletions))")
                print("      \(GitHubLogic.signalsText(GitHubLogic.signals(pr), now: Date()))")
            }
        }
        print(GitHubLogic.menuSummary(fetch.prs))
        print("GraphQL cost: \(fetch.cost) points for the searches, \(fetch.remaining.map(String.init) ?? "?") left of the hourly allowance")
        if let error = fetch.error {
            FileHandle.standardError.write(Data("Failed: \(error.message)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
