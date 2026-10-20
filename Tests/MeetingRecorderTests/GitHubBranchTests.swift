import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

let githubBranchTests: [(name: String, run: () throws -> Void)] = [
    ("checkout commands quote branch names that are not shell safe", {
        check(GitHubLogic.gitCheckoutCommand("NI/QDLY-8771") == "git checkout NI/QDLY-8771", "plain")
        check(GitHubLogic.gitCheckoutCommand("feature/a b") == "git checkout 'feature/a b'", "space")
        check(GitHubLogic.gitCheckoutCommand("it's;rm -rf") == "git checkout 'it'\\''s;rm -rf'", "quote and semicolon")
        check(GitHubLogic.gitCheckoutCommand("$(x)") == "git checkout '$(x)'" && GitHubLogic.gitCheckoutCommand("") == "git checkout ''", "substitution and empty")
        check(GitHubLogic.ghCheckoutCommand(number: 12, repo: "acme/api") == "gh pr checkout 12 --repo acme/api", "gh")
    }),
]
