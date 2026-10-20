import Foundation

extension GitHubLogic {
    /// A branch name as one shell word: as is when it only holds safe characters, otherwise in single quotes.
    static func shellWord(_ name: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./@%+=:,")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(safe.contains) else {
            return "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return name
    }

    static func gitCheckoutCommand(_ branch: String) -> String { "git checkout \(shellWord(branch))" }

    static func ghCheckoutCommand(number: Int, repo: String) -> String { "gh pr checkout \(number) --repo \(shellWord(repo))" }
}

extension MeetingStore {
    /// The head branch of a cached pull request, when its page has been fetched.
    func githubHeadBranch(_ url: String) -> String? {
        ((try? githubDetail(url)) ?? nil).flatMap { $0.head.isEmpty ? nil : $0.head }
    }
}
