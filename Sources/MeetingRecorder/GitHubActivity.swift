import Foundation

/// What the list query reports about the discussion on a pull request. Stored as it came; the signals are derived from it.
struct GitHubActivity: Codable, Equatable {
    struct Actor: Codable, Equatable {
        var login: String
        var isBot = false
    }

    struct Event: Codable, Equatable {
        var actor: Actor
        var date: Date
    }

    struct Review: Codable, Equatable {
        var actor: Actor
        var state: String
        var date: Date
    }

    /// The signed-in user, to tell their own activity from the others'.
    var me = ""
    var authorIsBot = false
    /// All review threads, of which only the first 50 are looked at.
    var threads = 0
    /// The last comment of each unresolved thread.
    var open: [Event] = []
    var reviews: [Review] = []
    var reviewCount = 0
    var lastComment: Event?
    var lastCommit: Date?
    var requested: [String] = []
}

enum GitHubSort: String, CaseIterable, Identifiable {
    case updated = "Updated"
    case needsAttention = "Needs attention"
    case mostDiscussed = "Most discussed"
    case unresolved = "Unresolved first"
    case failing = "Failing checks first"

    var id: String { rawValue }
}

enum GitHubQuickFilter: String, CaseIterable, Identifiable {
    case unresolved = "Has unresolved comments"
    case newFeedback = "New feedback"
    case changesRequested = "Changes requested"
    case failing = "Failing checks"
    case waitingOnMe = "Waiting on me"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .unresolved: return "bubble.left.and.exclamationmark.bubble.right"
        case .newFeedback: return "bell"
        case .changesRequested: return "exclamationmark.bubble"
        case .failing: return "xmark.circle"
        case .waitingOnMe: return "person.crop.circle.badge.clock"
        }
    }
}

/// What needs doing about an open pull request, derived from its cached discussion, review decision and checks.
struct GitHubSignals: Equatable {
    var unresolved = 0
    var humanUnresolved = 0
    /// Comments and reviews by others, people only, since your last commit, review or reply.
    var newFeedback = 0
    var newBotFeedback = 0
    var lastActor: GitHubActivity.Event?
    var changesRequested = false
    var failingChecks = false
    var waitingOnMe = false
    /// The only activity is from bots, and nothing needs a person's answer.
    var botOnly = false
    var discussed = 0

    /// The needs-attention ordering, one weight per thing in the order of how much it asks of you: a review waiting on you
    /// (50), new feedback from people (40), changes requested (30), failing checks (20) and unresolved threads (10); the
    /// number of new comments and unresolved threads (each at most 9) breaks ties between pull requests with the same flags.
    var attention: Int {
        (waitingOnMe ? 50 : 0) + (newFeedback > 0 ? 40 : 0) + (changesRequested ? 30 : 0) + (failingChecks ? 20 : 0)
            + (unresolved > 0 ? 10 : 0) + min(newFeedback, 9) + min(unresolved, 9)
    }

    func matches(_ filter: GitHubQuickFilter) -> Bool {
        switch filter {
        case .unresolved: return unresolved > 0
        case .newFeedback: return newFeedback > 0 || newBotFeedback > 0
        case .changesRequested: return changesRequested
        case .failing: return failingChecks
        case .waitingOnMe: return waitingOnMe
        }
    }
}

extension GitHubLogic {
    private static let feedbackStates: Set<String> = ["COMMENTED", "CHANGES_REQUESTED"]

    static func signals(_ pr: GitHubPR) -> GitHubSignals {
        guard pr.state == .open else { return GitHubSignals() }
        var signals = GitHubSignals(changesRequested: pr.review == .changesRequested, failingChecks: pr.checks == .failed)
        guard let activity = pr.activity else { return signals }
        let me = activity.me
        let mine = pr.author == me
        let reviews = activity.reviews.map { GitHubActivity.Event(actor: $0.actor, date: $0.date) }
        let cutoff = feedbackCutoff(pr)
        signals.unresolved = activity.open.count
        signals.humanUnresolved = activity.open.filter { !$0.actor.isBot }.count
        signals.discussed = pr.comments + activity.threads + activity.reviewCount
        signals.lastActor = (activity.open + reviews + [activity.lastComment].compactMap { $0 }).max { $0.date < $1.date }
        if let cutoff {
            let threads = activity.open.filter { $0.actor.login != me && $0.date > cutoff }
            let comment = activity.lastComment.flatMap { $0.actor.login != me && $0.date > cutoff ? $0 : nil }
            let inThreads = Set(threads.map(\.actor.login))
            let reviewed = activity.reviews.filter {
                $0.actor.login != me && $0.date > cutoff && feedbackStates.contains($0.state) && !inThreads.contains($0.actor.login)
            }.map { GitHubActivity.Event(actor: $0.actor, date: $0.date) }
            let all = threads + [comment].compactMap { $0 } + reviewed
            signals.newFeedback = all.filter { !$0.actor.isBot }.count
            signals.newBotFeedback = all.filter(\.actor.isBot).count
        }
        if !mine {
            let myReview = activity.reviews.filter { $0.actor.login == me }.map(\.date).max()
            let authorSince = { (date: Date) in
                (activity.open + [activity.lastComment].compactMap { $0 }).contains { $0.actor.login == pr.author && $0.date > date }
                    || (activity.lastCommit.map { $0 > date } ?? false)
            }
            signals.waitingOnMe = activity.requested.contains(me) || (myReview.map(authorSince) ?? false)
        }
        let people = signals.newFeedback > 0 || signals.humanUnresolved > 0 || signals.changesRequested || signals.waitingOnMe
        signals.botOnly = !people && (activity.authorIsBot || signals.lastActor?.actor.isBot == true)
        return signals
    }

    /// The sorted order of the list; the last update decides between equals.
    static func sorted(_ prs: [GitHubPR], by sort: GitHubSort) -> [GitHubPR] {
        func key(_ pr: GitHubPR) -> Int {
            let signals = signals(pr)
            switch sort {
            case .updated: return 0
            case .needsAttention: return signals.attention
            case .mostDiscussed: return signals.discussed
            case .unresolved: return signals.unresolved
            case .failing: return signals.failingChecks ? 1 : 0
            }
        }
        return prs.map { (key($0), $0) }.sorted { ($0.0, $0.1.updated, $1.1.url) > ($1.0, $1.1.updated, $0.1.url) }.map(\.1)
    }

    /// How many open pull requests you created have new feedback from people.
    static func newFeedbackCount(_ prs: [GitHubPR]) -> Int { prs.filter { signals($0).newFeedback > 0 }.count }

    static func newCommentsText(_ count: Int) -> String { "\(count) new comment\(count == 1 ? "" : "s")" }
}

extension GitHubLogic {
    /// The signals of a pull request on one line, for `--github-prs`.
    static func signalsText(_ signals: GitHubSignals, now: Date) -> String {
        let last = signals.lastActor.map { "last \($0.actor.login)\($0.actor.isBot ? " (bot)" : "") \(updatedText($0.date, now: now))" }
        let flags = [signals.changesRequested ? "changes requested" : nil, signals.failingChecks ? "failing checks" : nil,
                     signals.waitingOnMe ? "waiting on me" : nil, signals.botOnly ? "bot only" : nil].compactMap { $0 }
        return (["attention \(signals.attention)", "unresolved \(signals.unresolved) (\(signals.humanUnresolved) by people)",
                 "new feedback \(signals.newFeedback) (+\(signals.newBotFeedback) bot)", "discussed \(signals.discussed)", last] + flags)
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}
