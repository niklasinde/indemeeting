import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let patch = "@@ -10,4 +10,5 @@ func a() {\n context\n-old\n+new\n+added\n tail\n\\ No newline at end of file\n@@ -40,2 +41,2 @@\n x\n-y\n+z"

let githubDiffTests: [(name: String, run: () throws -> Void)] = [
    ("the first files open by default, all of them when there are fewer", {
        let paths = (1...8).map { "f\($0).swift" }
        check(GitHubDiffLogic.initiallyExpanded(paths) == Set(paths.prefix(GitHubDiffLogic.initiallyOpen)), "eight files")
        check(GitHubDiffLogic.initiallyExpanded(["a", "b"]) == ["a", "b"], "two files")
        check(GitHubDiffLogic.initiallyExpanded([]).isEmpty, "no files")
    }),

    ("the diff cache keeps the most recently stored keys", {
        var cache = RecentCache<Int>(limit: 2)
        cache.store(1, for: "a")
        cache.store(2, for: "b")
        cache.store(3, for: "a")
        cache.store(4, for: "c")
        check(cache["b"] == nil && cache["a"] == 3 && cache["c"] == 4, "\(cache.keys)")
        check(cache.keys == ["a", "c"], "\(cache.keys)")
    }),

    ("a unified diff is numbered from its hunk headers, old and new apart", {
        let rows = GitHubDiffLogic.rows(patch)
        check(rows.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context, .note, .hunk, .context, .removed, .added], "\(rows.map(\.kind))")
        check(rows[1].old == 10 && rows[1].new == 10 && rows[1].text == "context", "context \(rows[1])")
        check(rows[2].old == 11 && rows[2].new == nil && rows[2].text == "old", "removed \(rows[2])")
        check(rows[3].new == 11 && rows[3].old == nil && rows[4].new == 12, "added")
        check(rows[5].old == 12 && rows[5].new == 13, "context after \(rows[5])")
        check(rows[8].old == 40 && rows[8].new == 41 && rows[9].old == 41 && rows[10].new == 42, "second hunk")
        check(GitHubDiffLogic.rows("@@ -1 +1 @@\n-a\n+b\n").count == 3, "a trailing newline adds no row")
        check(GitHubDiffLogic.hunkStart("@@ -0,0 +1,3 @@") == (0, 1), "new file")
    }),

    ("files parse from a pull request page and from a commit, renames and missing patches kept", {
        let page = Data(#"[{"filename":"b.js","previous_filename":"a.js","status":"renamed","additions":1,"deletions":0,"patch":"@@ -1 +1 @@"},{"filename":"logo.png","status":"added"}]"#.utf8)
        let files = try GitHubDiffLogic.parseFiles(page)
        check(files.count == 2 && files[0].change == .renamed && files[0].title == "a.js \u{2192} b.js" && files[0].patch != nil, "\(files)")
        check(files[1].patch == nil && files[1].title == "logo.png", "binary")
        let commit = Data(#"{"sha":"abc","files":[{"filename":"c.swift","status":"modified","additions":2,"deletions":1,"patch":"@@ -1 +1 @@"}]}"#.utf8)
        check(try GitHubDiffLogic.parseFiles(commit).map(\.path) == ["c.swift"], "commit")
        check(GitHubDiffLogic.filesArguments(repo: "acme/api", number: 7, page: 2) == ["api", "repos/acme/api/pulls/7/files?per_page=100&page=2"], "arguments")
    }),

    ("review threads land under their line on the right side, and the rest is listed apart", {
        let rows = GitHubDiffLogic.rows(patch)
        let threads = [GitHubThread(id: "new", path: "a", line: 11), GitHubThread(id: "old", path: "a", line: 11, isLeft: true),
                       GitHubThread(id: "context", path: "a", line: 13), GitHubThread(id: "outdated", path: "a", line: nil, originalLine: 3),
                       GitHubThread(id: "file", path: "a", line: 11, isFile: true), GitHubThread(id: "far", path: "a", line: 500)]
        let result = GitHubDiffLogic.placement(threads, in: rows)
        check(result.placed[3]?.map(\.id) == ["new"], "added line \(result.placed)")
        check(result.placed[2]?.map(\.id) == ["old"], "removed line")
        check(result.placed[5]?.map(\.id) == ["context"], "context line by its new number")
        check(result.unplaced.map(\.id) == ["outdated", "file", "far"], "\(result.unplaced.map(\.id))")
    }),
]
