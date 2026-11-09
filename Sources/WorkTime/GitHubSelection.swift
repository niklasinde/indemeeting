import Foundation

/// Which pull request is selected in the list, and which neighbours are worth fetching ahead of a click.
enum GitHubSelection {
    enum Direction { case previous, next }

    /// A cached detail older than this is fetched again in the background when it is next to the selection.
    static let staleAfter: TimeInterval = 120
    static let settleDelay: TimeInterval = 0.3
    static let prefetchSlots = 2

    /// The selection when the list changes: kept while the pull request is still in it, otherwise none.
    static func preserved(_ selected: String?, in prs: [GitHubPR]) -> String? {
        selected.flatMap { url in prs.contains { $0.url == url } ? url : nil }
    }

    /// The pull request one step from the selection; the first or last one when nothing is selected, the same one at the ends.
    static func step(_ direction: Direction, from selected: String?, in prs: [GitHubPR]) -> GitHubPR? {
        guard !prs.isEmpty else { return nil }
        guard let index = prs.firstIndex(where: { $0.url == selected }) else { return direction == .next ? prs.first : prs.last }
        return prs[min(max(index + (direction == .next ? 1 : -1), 0), prs.count - 1)]
    }

    /// The next and previous rows whose cached detail is missing or stale, next first, at most `slots`.
    static func prefetchTargets(selected: String?, in prs: [GitHubPR], fetched: [String: Date], now: Date,
                                excluding busy: Set<String> = [], slots: Int = prefetchSlots) -> [GitHubPR] {
        guard let index = prs.firstIndex(where: { $0.url == selected }) else { return [] }
        let neighbours = [index + 1, index - 1].filter { prs.indices.contains($0) }.map { prs[$0] }
        return Array(neighbours.filter { pr in
            !busy.contains(pr.url) && fetched[pr.url].map { now.timeIntervalSince($0) > staleAfter } ?? true
        }.prefix(max(0, slots)))
    }
}

/// Runs only the last action scheduled, once no newer one arrived for the delay.
final class Debouncer: @unchecked Sendable {
    private let queue: DispatchQueue
    private var pending: DispatchWorkItem?

    init(queue: DispatchQueue = .main) { self.queue = queue }

    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: action)
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
