import Foundation

private func parsed(_ text: String) -> GitHubLink.Target? { GitHubLink.parse(text) }

private let finqAPI = GitHubLink.Target(repo: "quiddly-com/finq.api", number: 2483)
private let encodedFinqAPI = "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fquiddly-com%2Ffinq.api%2Fpull%2F2483"

private let linkSourceFiles = ["Sources/MeetingRecorder/GitHubLink.swift", "Sources/MeetingRecorder/GitHubLinkHandler.swift"]

let githubLinkTests: [(name: String, run: () throws -> Void)] = [
    ("a link with the pull request address in the query opens that pull request", {
        check(parsed(encodedFinqAPI) == finqAPI, "percent-encoded query")
        check(parsed("meetingrecorder://pr?url=https://github.com/quiddly-com/finq.api/pull/2483") == finqAPI, "unencoded query")
    }),

    ("a link with owner, repo and number in the path opens that pull request", {
        check(parsed("meetingrecorder://pr/quiddly-com/finq.api/2483") == finqAPI, "path form")
        check(parsed("meetingrecorder://pr/quiddly%2Dcom/finq%2Eapi/2483") == finqAPI, "percent-encoded path segments")
        check(parsed("MEETINGRECORDER://PR/quiddly-com/finq.api/2483") == finqAPI, "scheme and host are not case sensitive")
    }),

    ("dots, dashes and underscores in the repository name are accepted", {
        check(parsed("meetingrecorder://pr/a-b/my.repo-x_y/7") == GitHubLink.Target(repo: "a-b/my.repo-x_y", number: 7), "dots, dashes, underscores")
        check(parsed("meetingrecorder://pr/o/.github/1") == GitHubLink.Target(repo: "o/.github", number: 1), "a leading dot")
    }),

    ("the pull request address must be a GitHub pull request page and nothing more", {
        let bad = [
            "meetingrecorder://pr?url=http%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgitlab.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com.evil.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr?url=https%3A%2F%2Fevil.com%40github.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%3A8443%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1%2Ffiles",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1%3Fx%3D1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1%23top",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1%26x%3D1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1%2F",
            "meetingrecorder://pr?url=",
            "meetingrecorder://pr?url=not%20a%20link",
        ]
        for text in bad { check(parsed(text) == nil, "rejects \(text)") }
    }),

    ("the link must name only the pr host, one url parameter and no extra parts", {
        let bad = [
            "https://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://issue?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr.evil.com/o/r/1",
            "meetingrecorder://user@pr/o/r/1",
            "meetingrecorder://pr:80/o/r/1",
            "meetingrecorder://pr/o/r/1#top",
            "meetingrecorder://pr/o/r/1/files",
            "meetingrecorder://pr/o/r",
            "meetingrecorder://pr/o/r/1?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr/extra?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1&other=1",
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1&url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F2",
            "meetingrecorder://pr?other=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1",
            "meetingrecorder://pr",
            "meetingrecorder://",
            "",
        ]
        for text in bad { check(parsed(text) == nil, "rejects \(text)") }
    }),

    ("a number must be a positive whole number without signs, zeros or words", {
        for number in ["abc", "12a", "+5", "-1", "0", "01", "1.5", "1%2F2", "9999999999", " 3"] {
            check(parsed("meetingrecorder://pr/o/r/\(number)") == nil, "rejects number \(number)")
        }
        check(parsed("meetingrecorder://pr/o/r/999999999") == GitHubLink.Target(repo: "o/r", number: 999_999_999), "nine digits")
    }),

    ("owner and repository names GitHub would not accept are rejected", {
        let bad = [
            "meetingrecorder://pr/-owner/r/1", "meetingrecorder://pr/owner-/r/1", "meetingrecorder://pr/own_er/r/1",
            "meetingrecorder://pr/\(String(repeating: "a", count: 40))/r/1",
            "meetingrecorder://pr/o%2Fx/r/1", "meetingrecorder://pr/o/./1", "meetingrecorder://pr/o/../1",
            "meetingrecorder://pr/o/r%20x/1", "meetingrecorder://pr/o/r%3Fx/1", "meetingrecorder://pr//r/1",
        ]
        for text in bad { check(parsed(text) == nil, "rejects \(text)") }
        check(parsed("meetingrecorder://pr/\(String(repeating: "a", count: 39))/r/1") != nil, "39 characters is the longest owner")
    }),

    ("an attempt to smuggle a second address or a query through the parameter is refused", {
        let bad = [
            "meetingrecorder://pr?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1%2520https%3A%2F%2Fevil.com",
            "meetingrecorder://pr?url=https%253A%252F%252Fgithub.com%252Fo%252Fr%252Fpull%252F1",
            "meetingrecorder://pr?url=javascript%3Aalert(1)",
        ]
        for text in bad { check(parsed(text) == nil, "rejects \(text)") }
    }),

    ("the copied app link opens the same pull request it was copied from", {
        check(GitHubLink.appLink(for: finqAPI.url) == encodedFinqAPI, "copy string")
        check(GitHubLink.appLink(for: "https://github.com/quiddly-com/finq.api/pull/2483") == encodedFinqAPI, "copy string from the page address")
        check(parsed(GitHubLink.appLink(for: finqAPI.url)) == finqAPI, "round trip")
    }),

    ("the link files never mention the write paths", {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = ["GitHubAction", "merge", "close", "approve"]
        for file in linkSourceFiles {
            let text = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
            check(!text.isEmpty, "\(file) is readable")
            for word in forbidden { check(!text.localizedCaseInsensitiveContains(word), "\(file) mentions \(word)") }
        }
    }),
]
