import Foundation

private func row(_ number: Int) -> GitHubPR {
    GitHubPR(url: "https://github.com/acme/api/pull/\(number)", number: number, title: "T\(number)", repo: "acme/api", state: .open, updated: Date())
}

private let rows = (1...5).map(row)
private func url(_ number: Int) -> String { row(number).url }

let githubSelectionTests: [(name: String, run: () throws -> Void)] = [
    ("the selection survives a change of the list only while its pull request is listed", {
        check(GitHubSelection.preserved(url(3), in: rows) == url(3), "kept")
        check(GitHubSelection.preserved(url(3), in: Array(rows.reversed())) == url(3), "kept after a re-sort")
        check(GitHubSelection.preserved(url(3), in: [rows[0], rows[4]]) == nil, "cleared when filtered out")
        check(GitHubSelection.preserved(nil, in: rows) == nil, "nothing stays nothing")
    }),

    ("the arrow keys step through the list and stop at its ends", {
        check(GitHubSelection.step(.next, from: url(2), in: rows)?.number == 3, "next")
        check(GitHubSelection.step(.previous, from: url(2), in: rows)?.number == 1, "previous")
        check(GitHubSelection.step(.previous, from: url(1), in: rows)?.number == 1, "stays at the top")
        check(GitHubSelection.step(.next, from: url(5), in: rows)?.number == 5, "stays at the bottom")
        check(GitHubSelection.step(.next, from: nil, in: rows)?.number == 1, "down selects the first")
        check(GitHubSelection.step(.previous, from: nil, in: rows)?.number == 5, "up selects the last")
        check(GitHubSelection.step(.next, from: url(9), in: rows)?.number == 1, "a selection that is gone starts over")
        check(GitHubSelection.step(.next, from: nil, in: []) == nil, "an empty list selects nothing")
    }),

    ("only the stale or missing neighbours are fetched ahead, at most two at a time", {
        let now = Date()
        func targets(_ selected: Int, fetched: [String: Date] = [:], busy: Set<String> = [], slots: Int = 2) -> [Int] {
            GitHubSelection.prefetchTargets(selected: url(selected), in: rows, fetched: fetched, now: now, excluding: busy, slots: slots).map(\.number)
        }
        check(targets(3) == [4, 2], "next first, then previous")
        check(targets(1) == [2], "no row above the first")
        check(targets(5) == [4], "no row below the last")
        check(targets(3, fetched: [url(4): now.addingTimeInterval(-30)]) == [2], "a fresh cache is left alone")
        check(targets(3, fetched: [url(4): now.addingTimeInterval(-300)]) == [4, 2], "an old cache is fetched again")
        check(targets(3, busy: [url(4)]) == [2], "one already on its way is skipped")
        check(targets(3, slots: 1) == [4], "a free slot limits the count")
        check(targets(3, slots: 0).isEmpty && targets(3, slots: -1).isEmpty, "no free slot")
        check(GitHubSelection.prefetchTargets(selected: nil, in: rows, fetched: [:], now: now).isEmpty, "nothing selected")
    }),

    ("rapid selections run only the last action, a cancel runs none", {
        let queue = DispatchQueue(label: "debounce-test")
        let debouncer = Debouncer(queue: queue)
        let lock = NSLock()
        nonisolated(unsafe) var ran: [Int] = []
        for value in 1...5 {
            debouncer.schedule(after: 0.05) { lock.withLock { ran.append(value) } }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.3)
        check(lock.withLock { ran } == [5], "only the last ran: \(lock.withLock { ran })")
        debouncer.schedule(after: 0.05) { lock.withLock { ran.append(6) } }
        debouncer.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        check(lock.withLock { ran } == [5], "a cancelled action never runs")
    }),

    ("the fetch time of each cached detail is known", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("githubselection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        check(try store.githubDetailFetched().isEmpty, "nothing cached")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try store.saveGitHubDetail(url(1), json: Data("{}".utf8), fetched: when)
        check(try store.githubDetailFetched()[url(1)] == when, "the time is kept")
    }),
]
