import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func at(_ hours: Double) -> Date { Date(timeIntervalSince1970: 1_792_000_000 + hours * 3600) }
private func person(_ login: String) -> GitHubActivity.Actor { GitHubActivity.Actor(login: login) }
private let robot = GitHubActivity.Actor(login: "copilot", isBot: true)
private func event(_ actor: GitHubActivity.Actor, _ hours: Double) -> GitHubActivity.Event { GitHubActivity.Event(actor: actor, date: at(hours)) }
private func review(_ actor: GitHubActivity.Actor, _ state: String, _ hours: Double) -> GitHubActivity.Review {
    GitHubActivity.Review(actor: actor, state: state, date: at(hours))
}

private func pr(_ number: Int = 1, author: String = "me", state: GitHubPR.State = .open, review decision: GitHubPR.Review? = nil,
                checks: GitHubPR.Checks = .passed, updated: Double = 0, comments: Int = 0, activity: GitHubActivity? = GitHubActivity(me: "me")) -> GitHubPR {
    GitHubPR(url: "https://github.com/acme/api/pull/\(number)", number: number, title: "Title \(number)", repo: "acme/api", state: state,
             updated: at(updated), review: decision, checks: checks, author: author, comments: comments, activity: activity)
}

private func listJSON(nodeExtra: String = "") -> Data {
    Data("""
    {"data":{"rateLimit":{"cost":12,"remaining":4900},"viewer":{"login":"me"},"search":{"nodes":[
      {"number":1,"title":"T","url":"https://github.com/acme/api/pull/1","isDraft":false,"state":"OPEN","merged":false,"updatedAt":"2026-10-19T12:00:00Z",
       "reviewDecision":null,"additions":1,"deletions":1,"repository":{"nameWithOwner":"acme/api"},"author":{"login":"me","__typename":"User"},
       "comments":{"totalCount":2},"labels":{"nodes":[]},
       "commits":{"nodes":[{"commit":{"committedDate":"2026-10-19T10:00:00Z","statusCheckRollup":null}}]},
       "lastComment":{"nodes":[{"author":{"login":"elin","__typename":"User"},"createdAt":"2026-10-19T11:00:00Z"}]},
       "reviews":{"totalCount":3},
       "latestReviews":{"nodes":[{"author":{"login":"elin","__typename":"User"},"state":"COMMENTED","submittedAt":"2026-10-19T11:30:00Z"},null,
                                 {"author":null,"state":"APPROVED","submittedAt":"2026-10-19T09:00:00Z"}]},
       "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"johan"}},{"requestedReviewer":{}}]},
       "reviewThreads":{"totalCount":25,"nodes":[
         {"isResolved":true,"comments":{"nodes":[{"author":{"login":"elin","__typename":"User"},"createdAt":"2026-10-19T08:00:00Z"}]}},
         {"isResolved":false,"comments":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"},"createdAt":"2026-10-19T11:45:00Z"}]}},
         {"isResolved":false,"comments":{"nodes":[]}},
         null]}\(nodeExtra)}
    ]}}}
    """.utf8)
}

let githubActivityTests: [(name: String, run: () throws -> Void)] = [
    ("the list response carries the discussion, the viewer and what the query cost", {
        let page = try GitHubLogic.parsePage(listJSON())
        check(page.cost == 12 && page.remaining == 4900 && page.prs.count == 1, "cost")
        let activity = try unwrap(page.prs[0].activity)
        check(activity.me == "me" && !activity.authorIsBot, "viewer")
        check(activity.threads == 25 && activity.open.count == 1 && activity.open[0].actor.isBot && activity.open[0].actor.login == "copilot-pull-request-reviewer",
              "only unresolved threads with a comment, bot flagged")
        check(activity.reviews.map(\.state) == ["COMMENTED", "APPROVED"] && activity.reviews[1].actor.login == "ghost", "reviews, ghost author")
        check(activity.reviewCount == 3 && activity.lastComment?.actor.login == "elin" && activity.requested == ["johan"], "counts and requests")
        check(activity.lastCommit == Date(timeIntervalSince1970: 1_792_404_000), "last commit \(String(describing: activity.lastCommit))")
        check(try GitHubLogic.parse(Data(#"{"data":{"search":{"nodes":[]}}}"#.utf8)).isEmpty, "a response without discussion fields still parses")
        let bare = try GitHubLogic.parsePage(Data(#"{"data":{"search":{"nodes":[{"number":1,"title":"T","url":"https://github.com/a/b/pull/1","updatedAt":"2026-10-19T12:00:00Z","repository":{"nameWithOwner":"a/b"}}]}}}"#.utf8))
        check(bare.prs[0].activity?.open.isEmpty == true && bare.cost == 0, "no fields, no signals")
    }),

    ("the closed searches leave the discussion out and the open ones ask for a page of threads", {
        check(!GitHubLogic.query(discussion: false).contains("reviewThreads") && GitHubLogic.query(discussion: true).contains("reviewThreads(first: \(GitHubLogic.threadPageSize))"), "query")
        check(GitHubLogic.searches(for: .created).map(\.discussion) == [true, false], "created searches")
        check(GitHubLogic.arguments(for: GitHubLogic.searches(for: .created)[1]).joined().contains("reviewThreads") == false, "closed arguments")
    }),

    ("unresolved threads are counted, and those whose last word is a person's apart", {
        var activity = GitHubActivity(me: "me", open: [event(person("elin"), 1), event(robot, 2), event(person("me"), 3)])
        let signals = GitHubLogic.signals(pr(activity: activity))
        check(signals.unresolved == 3 && signals.humanUnresolved == 2, "counts")
        check(signals.lastActor?.actor.login == "me", "last activity is the newest event")
        activity.threads = 40
        check(GitHubLogic.signals(pr(comments: 2, activity: activity)).discussed == 42 + activity.reviewCount, "discussed adds comments, threads and reviews")
    }),

    ("new feedback is what others said after your last commit, review or reply", {
        var activity = GitHubActivity(me: "me", open: [event(person("elin"), 5), event(person("johan"), 1)], lastComment: event(person("sara"), 6), lastCommit: at(2))
        var signals = GitHubLogic.signals(pr(activity: activity))
        check(signals.newFeedback == 2, "one thread and the comment after the push: \(signals.newFeedback)")
        activity.open.append(event(person("me"), 7))
        check(GitHubLogic.signals(pr(activity: activity)).newFeedback == 0, "your own reply later resets it")
        activity.lastComment = event(person("sara"), 8)
        check(GitHubLogic.signals(pr(activity: activity)).newFeedback == 1, "and a newer comment counts again")
        activity = GitHubActivity(me: "me", reviews: [review(person("elin"), "COMMENTED", 5), review(person("johan"), "APPROVED", 5), review(person("sara"), "CHANGES_REQUESTED", 1)],
                                  lastCommit: at(2))
        check(GitHubLogic.signals(pr(activity: activity)).newFeedback == 1, "a comment review counts, an approval and an old review do not")
        activity.open = [event(person("elin"), 5)]
        check(GitHubLogic.signals(pr(activity: activity)).newFeedback == 1, "a review and its thread comment are one piece of feedback")
        signals = GitHubLogic.signals(pr(activity: GitHubActivity(me: "me", open: [event(robot, 5)], lastComment: event(person("elin"), 6), lastCommit: at(2))))
        check(signals.newFeedback == 1 && signals.newBotFeedback == 1, "people and bots are counted apart")
        check(GitHubLogic.signals(pr(activity: GitHubActivity(me: "me", lastComment: event(person("elin"), 6)))).newFeedback == 1, "no commit date: all of it is new")
    }),

    ("on someone else's pull request nothing is new until you took part", {
        let others = GitHubActivity(me: "me", open: [event(person("elin"), 5)], lastComment: event(person("sara"), 6), lastCommit: at(9))
        check(GitHubLogic.signals(pr(author: "elin", activity: others)).newFeedback == 0, "you have not taken part")
        var taken = others
        taken.reviews = [review(person("me"), "COMMENTED", 4)]
        check(GitHubLogic.signals(pr(author: "elin", activity: taken)).newFeedback == 2, "after your review: the thread and the comment")
    }),

    ("waiting on me: a review asked of you, or the author answered after your review", {
        check(GitHubLogic.signals(pr(author: "elin", activity: GitHubActivity(me: "me", requested: ["me", "johan"]))).waitingOnMe, "requested")
        check(!GitHubLogic.signals(pr(author: "elin", activity: GitHubActivity(me: "me", requested: ["johan"]))).waitingOnMe, "someone else requested")
        check(GitHubLogic.signals(pr(author: "elin", activity: GitHubActivity(me: "me", reviews: [review(person("me"), "CHANGES_REQUESTED", 3)], lastCommit: at(4)))).waitingOnMe, "pushed after")
        check(GitHubLogic.signals(pr(author: "elin", activity: GitHubActivity(me: "me", open: [event(person("elin"), 5)], reviews: [review(person("me"), "COMMENTED", 3)]))).waitingOnMe, "replied after")
        check(!GitHubLogic.signals(pr(author: "elin", activity: GitHubActivity(me: "me", open: [event(person("sara"), 5)], reviews: [review(person("me"), "COMMENTED", 3)], lastCommit: at(1)))).waitingOnMe,
              "a third person's comment does not make it wait on you")
        check(!GitHubLogic.signals(pr(author: "me", activity: GitHubActivity(me: "me", requested: ["me"]))).waitingOnMe, "never on your own pull request")
    }),

    ("bot-only activity: a bot's pull request or last word, with nothing for a person to answer", {
        check(GitHubLogic.signals(pr(author: "snyk-bot", activity: GitHubActivity(me: "me", authorIsBot: true))).botOnly, "a bot's pull request")
        check(GitHubLogic.signals(pr(activity: GitHubActivity(me: "me", open: [event(robot, 5)], lastCommit: at(1)))).botOnly, "new bot feedback alone is bot-only")
        let quiet = GitHubActivity(me: "me", open: [event(robot, 5)], lastCommit: at(9))
        check(GitHubLogic.signals(pr(activity: quiet)).botOnly, "a bot spoke before your push")
        check(!GitHubLogic.signals(pr(author: "snyk-bot", activity: GitHubActivity(me: "me", authorIsBot: true, open: [event(person("elin"), 5)]))).botOnly, "a person's thread")
        check(!GitHubLogic.signals(pr(author: "snyk-bot", review: .changesRequested, activity: GitHubActivity(me: "me", authorIsBot: true))).botOnly, "changes requested")
        check(!GitHubLogic.signals(pr(activity: GitHubActivity(me: "me"))).botOnly, "no bots, no activity")
    }),

    ("a pull request that is not open has no signals, and one without cached discussion still has the review and checks", {
        let activity = GitHubActivity(me: "me", open: [event(person("elin"), 5)], lastCommit: at(1))
        check(GitHubLogic.signals(pr(state: .merged, review: .changesRequested, checks: .failed, activity: activity)) == GitHubSignals(), "merged")
        let bare = GitHubLogic.signals(pr(review: .changesRequested, checks: .failed, activity: nil))
        check(bare.changesRequested && bare.failingChecks && bare.unresolved == 0 && !bare.botOnly, "no discussion cached")
    }),

    ("the needs-attention score orders waiting on you, new feedback, changes requested, failing checks, unresolved", {
        let waiting = GitHubSignals(waitingOnMe: true)
        let feedback = GitHubSignals(newFeedback: 1)
        let changes = GitHubSignals(changesRequested: true)
        let failing = GitHubSignals(failingChecks: true)
        let unresolved = GitHubSignals(unresolved: 9)
        let scores = [waiting, feedback, changes, failing, unresolved].map(\.attention)
        check(scores == scores.sorted(by: >) && Set(scores).count == 5, "order \(scores)")
        check(GitHubSignals(unresolved: 2, newFeedback: 3).attention > GitHubSignals(unresolved: 2, newFeedback: 1).attention, "more new comments first")
        check(GitHubSignals(changesRequested: true, failingChecks: true).attention > changes.attention, "flags add up")
        check(GitHubSignals(unresolved: 99, newFeedback: 99).attention == 40 + 10 + 9 + 9, "counts are capped")
        check(GitHubSignals().attention == 0, "nothing")
    }),

    ("the list sorts by updated, attention, discussion, unresolved threads and failing checks", {
        let rows = [
            pr(1, updated: 1, activity: GitHubActivity(me: "me", threads: 5)),
            pr(2, updated: 2, comments: 9, activity: GitHubActivity(me: "me", open: [event(person("elin"), 1), event(person("elin"), 1), event(person("elin"), 1)], lastCommit: at(5))),
            pr(3, checks: .failed, updated: 3),
            pr(4, review: .changesRequested, updated: 4),
            pr(5, author: "elin", updated: 0, activity: GitHubActivity(me: "me", requested: ["me"])),
        ]
        func order(_ sort: GitHubSort) -> [Int] { GitHubLogic.sorted(rows, by: sort).map(\.number) }
        check(order(.updated) == [4, 3, 2, 1, 5], "updated \(order(.updated))")
        check(order(.needsAttention) == [5, 4, 3, 2, 1], "attention \(order(.needsAttention))")
        check(order(.mostDiscussed).prefix(2) == [2, 1], "discussed \(order(.mostDiscussed))")
        check(order(.unresolved).first == 2, "unresolved")
        check(order(.failing).first == 3, "failing")
        check(GitHubLogic.sorted([pr(7, updated: 1), pr(6, updated: 1)], by: .needsAttention).map(\.number) == [6, 7], "equal: by address")
    }),

    ("the quick filters combine, and hiding bot-only activity drops those pull requests", {
        let rows = [
            pr(1, review: .changesRequested, checks: .failed, activity: GitHubActivity(me: "me", open: [event(person("elin"), 5)], lastCommit: at(1))),
            pr(2, checks: .failed),
            pr(3, author: "snyk", activity: GitHubActivity(me: "me", authorIsBot: true)),
            pr(4, author: "elin", activity: GitHubActivity(me: "me", requested: ["me"])),
        ]
        func numbers(_ configure: (inout GitHubLogic.Filter) -> Void) -> [Int] {
            var filter = GitHubLogic.Filter()
            configure(&filter)
            return GitHubLogic.filter(rows, filter).map(\.number).sorted()
        }
        check(numbers { _ in } == [1, 2, 3, 4], "no filter")
        check(numbers { $0.quick = [.failing] } == [1, 2], "failing")
        check(numbers { $0.quick = [.failing, .unresolved] } == [1], "both")
        check(numbers { $0.quick = [.newFeedback] } == [1], "new feedback")
        check(numbers { $0.quick = [.waitingOnMe] } == [4], "waiting")
        check(numbers { $0.quick = [.changesRequested] } == [1], "changes")
        check(numbers { $0.hideBotOnly = true } == [1, 2, 4], "hide bot-only")
        check(GitHubLogic.Filter().refinements == 0 && GitHubLogic.Filter(query: "x", status: .myTurn).refinements == 0, "search and status are not refinements")
        let refined = GitHubLogic.Filter(state: .all, repo: "o/r", query: "x", quick: [.failing, .unresolved], hideBotOnly: true, sort: .mostDiscussed, status: .draft)
        check(refined.refinements == 6, "each menu filter counts \(refined.refinements)")
        check(refined.withoutRefinements == GitHubLogic.Filter(query: "x", status: .draft), "reset keeps the search and the status")
    }),

    ("a pull request is mergeable when approved or needing no review, passing, without conflicts and not a draft", {
        func ready(_ configure: (inout GitHubPR) -> Void = { _ in }) -> Bool {
            var row = pr(review: .approved)
            row.mergeable = .mergeable
            row.mergeState = .clean
            configure(&row)
            return GitHubLogic.isMergeable(row)
        }
        check(ready(), "approved, clean")
        check(ready { $0.review = nil }, "no review required")
        check(ready { $0.checks = .none }, "no checks")
        check(ready { $0.mergeState = .unknown }, "merge state not known yet")
        check(!ready { $0.review = .required }, "review required")
        check(!ready { $0.review = .changesRequested }, "changes requested")
        check(!ready { $0.checks = .failed }, "failing")
        check(!ready { $0.checks = .running }, "running")
        check(!ready { $0.mergeable = .conflicting }, "conflicts")
        check(!ready { $0.mergeable = .unknown }, "mergeability not known")
        check(!ready { $0.mergeState = .blocked }, "blocked")
        check(!ready { $0.mergeState = .behind }, "behind")
        check(!ready { $0.isDraft = true }, "draft")
        check(!ready { $0.state = .merged }, "merged")
        var mergeable = pr(2, review: .approved)
        mergeable.mergeable = .mergeable
        check(GitHubLogic.filter([pr(1), mergeable], GitHubLogic.Filter(), mergeable: true).map(\.number) == [2], "the filter keeps the mergeable ones")
    }),

    ("a pull request's status is on hold, draft, my turn, approved or waiting, in that order", {
        func status(_ configure: (inout GitHubPR) -> Void) -> GitHubStatus? {
            var row = pr(activity: GitHubActivity(me: "me", lastCommit: at(1)))
            configure(&row)
            return GitHubLogic.status(row)
        }
        let commented = GitHubActivity(me: "me", reviews: [review(person("elin"), "COMMENTED", 2)], lastCommit: at(1))
        check(status { _ in } == .waiting, "nothing yet")
        check(status { $0.review = .approved } == .approved, "approved")
        check(status { $0.activity = commented } == .myTurn, "a reviewer commented since my push")
        check(status { $0.activity = GitHubActivity(me: "me", reviews: [review(person("elin"), "CHANGES_REQUESTED", 2)], lastCommit: at(3)) } == .waiting,
              "pushed since the review")
        check(status { $0.activity = GitHubActivity(me: "me", reviews: [review(person("elin"), "COMMENTED", 2)], lastCommit: at(1), requested: ["elin"]) }
              == .waiting, "asked to look again")
        check(status { $0.activity = GitHubActivity(me: "me", reviews: [review(robot, "COMMENTED", 2)], lastCommit: at(1)) } == .waiting, "bots do not count")
        check(status { $0.activity = GitHubActivity(me: "me", reviews: [review(person("elin"), "APPROVED", 2)], lastCommit: at(1)) } == .waiting,
              "an approving review is not feedback")
        check(status { $0.activity = nil; $0.review = .changesRequested } == .myTurn, "changes requested with no discussion cached")
        check(status { $0.activity = commented; $0.review = .approved } == .myTurn, "my turn before approved")
        check(status { $0.activity = commented; $0.isDraft = true } == .draft, "draft before my turn")
        check(status { $0.isDraft = true; $0.labels = ["On hold"] } == .onHold, "on hold before draft")
        check(status { $0.labels = ["on-hold"] } == .onHold && status { $0.labels = ["hold"] } == .onHold, "label spellings")
        check(status { $0.labels = ["household"] } == .waiting, "a word containing hold")
        check(status { $0.state = .merged } == nil, "merged has none")
        check(GitHubLogic.status(pr(author: "elin", activity: GitHubActivity(me: "me", requested: ["me"]))) == .myTurn, "someone else's waiting on me")
    }),

    ("the status tabs filter and count, with on hold only in its own tab", {
        var held = pr(1)
        held.labels = ["on hold"]
        var draft = pr(2)
        draft.isDraft = true
        let rows = [held, draft, pr(3, review: .approved), pr(4), pr(5, state: .merged)]
        func numbers(_ tab: GitHubStatusTab) -> [Int] { GitHubLogic.filter(rows, GitHubLogic.Filter(state: .all, status: tab)).map(\.number).sorted() }
        check(numbers(.all) == [2, 3, 4, 5], "all leaves out on hold \(numbers(.all))")
        check(numbers(.onHold) == [1] && numbers(.draft) == [2] && numbers(.approved) == [3] && numbers(.waiting) == [4] && numbers(.myTurn).isEmpty, "tabs")
        let counts = GitHubLogic.statusCounts(rows, GitHubLogic.Filter())
        check(counts[.all] == 3 && counts[.onHold] == 1 && counts[.myTurn] == 0, "counts of the open ones \(counts)")
        check(GitHubStatusTab.tab(for: "m") == .myTurn && GitHubStatusTab.tab(for: "P") == .approved && GitHubStatusTab.tab(for: "x") == nil, "hotkeys")
        check(GitHubLogic.waitingFirst(rows, status: .onHold).map(\.number) == [1], "the notch list keeps the tab")
    }),

    ("a pull request I review is my turn, waiting on the author, or approved by me", {
        func status(_ activity: GitHubActivity?) -> GitHubStatus { GitHubLogic.reviewStatus(pr(author: "elin", activity: activity)) }
        check(status(GitHubActivity(me: "me", requested: ["me"])) == .myTurn, "review asked and not given")
        check(status(GitHubActivity(me: "me", reviews: [review(person("me"), "APPROVED", 3)], lastCommit: at(1), requested: ["me"])) == .myTurn, "asked again")
        check(status(GitHubActivity(me: "me", reviews: [review(person("me"), "COMMENTED", 3)], lastCommit: at(4))) == .myTurn, "pushed since my review")
        check(status(GitHubActivity(me: "me", open: [event(person("elin"), 5)], reviews: [review(person("me"), "CHANGES_REQUESTED", 3)], lastCommit: at(1))) == .myTurn,
              "the author replied since my review")
        check(status(GitHubActivity(me: "me", reviews: [review(person("me"), "CHANGES_REQUESTED", 3)], lastCommit: at(1))) == .waiting, "on the author")
        check(status(GitHubActivity(me: "me", open: [event(person("sara"), 5)], reviews: [review(person("me"), "COMMENTED", 3)], lastCommit: at(1))) == .waiting,
              "someone else replied")
        check(status(GitHubActivity(me: "me", reviews: [review(person("me"), "APPROVED", 3), review(person("sara"), "CHANGES_REQUESTED", 4)], lastCommit: at(1))) == .approved,
              "approved by me, whatever the others say")
        check(status(GitHubActivity(me: "me", reviews: [review(person("me"), "APPROVED", 3)], lastCommit: at(4))) == .myTurn, "pushed since my approval")
        check(status(GitHubActivity(me: "me", reviews: [review(person("sara"), "APPROVED", 3)], lastCommit: at(1))) == .waiting, "someone else's approval")
        check(status(nil) == .myTurn, "no discussion cached")
    }),

    ("the Reviewing list joins the requested and reviewed searches, once each, open and by others, my turn first", {
        let asked = pr(1, author: "elin", updated: 1, activity: GitHubActivity(me: "me", requested: ["me"]))
        let approved = pr(2, author: "sara", updated: 5, activity: GitHubActivity(me: "me", reviews: [review(person("me"), "APPROVED", 3)], lastCommit: at(1)))
        let waiting = pr(3, author: "johan", updated: 4, activity: GitHubActivity(me: "me", reviews: [review(person("me"), "COMMENTED", 3)], lastCommit: at(1)))
        let merged = pr(4, author: "elin", state: .merged)
        let mine = pr(5, author: "me", updated: 9)
        let prs: [GitHubKind: [GitHubPR]] = [.reviewRequested: [asked, mine], .reviewed: [approved, asked, waiting, merged], .created: [pr(6, updated: 10)]]
        check(GitHubLogic.reviewing(prs).map(\.number) == [1, 2, 3], "deduplicated, my turn first, then newest \(GitHubLogic.reviewing(prs).map(\.number))")
        check(GitHubLogic.reviewing(prs, status: .approved).map(\.number) == [2] && GitHubLogic.reviewing(prs, status: .waiting).map(\.number) == [3], "tabs")
        check(GitHubLogic.reviewingCounts(prs) == [.all: 3, .myTurn: 1, .waiting: 1, .approved: 1], "counts \(GitHubLogic.reviewingCounts(prs))")
        check(GitHubLogic.reviewing([.reviewed: [waiting]]).map(\.number) == [3], "the reviewed search alone")
        check(GitHubLogic.reviewing([:]).isEmpty, "nothing fetched")
    }),

    ("the review queue lists the open requests in the filter's repository and search", {
        let other = GitHubPR(url: "https://github.com/acme/web/pull/2", number: 2, title: "Web", repo: "acme/web", updated: at(2), author: "elin")
        let rows = [pr(1, author: "elin", updated: 1), other, pr(3, author: "elin", state: .closed)]
        check(GitHubLogic.reviewQueue(rows).map(\.number) == [2, 1], "open, newest first")
        check(GitHubLogic.reviewQueue(rows, GitHubLogic.Filter(repo: "acme/api")).map(\.number) == [1], "repository")
        check(GitHubLogic.reviewQueue(rows, GitHubLogic.Filter(query: "web")).map(\.number) == [2], "search")
        check(GitHubLogic.reviewQueue(rows, limit: 1).map(\.number) == [2], "limit")
    }),

    ("the merge state is read from the search and kept in the cache", {
        let parsed = try GitHubLogic.parse(listJSON(nodeExtra: #","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN""#)).first
        check(parsed?.mergeable == .mergeable && parsed?.mergeState == .clean, "parsed \(String(describing: parsed?.mergeable)) \(String(describing: parsed?.mergeState))")
        check(try GitHubLogic.parse(listJSON()).first?.mergeable == .unknown, "absent is unknown")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("githubmerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        var row = pr(1)
        row.mergeable = .conflicting
        row.mergeState = .dirty
        try store.saveGitHubPRs([.created: [row]])
        let read = try store.githubPRs()[.created]?.first
        check(read?.mergeable == .conflicting && read?.mergeState == .dirty, "round trip")
    }),

    ("the discussion is cached with the pull request and read back", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("githubactivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let activity = GitHubActivity(me: "me", authorIsBot: true, threads: 4, open: [event(robot, 2)], reviews: [review(person("elin"), "APPROVED", 1)], reviewCount: 2,
                                      lastComment: event(person("elin"), 3), lastCommit: at(1), requested: ["me"])
        try store.saveGitHubPRs([.created: [pr(1, activity: activity), pr(2, activity: nil)]])
        let rows = try store.githubPRs()[.created] ?? []
        check(rows.first { $0.number == 1 }?.activity == activity, "round trip")
        check(rows.first { $0.number == 2 }?.activity == nil, "no discussion stays none")
    }),

    ("the menu bar line counts your pull requests with new feedback", {
        let created = [pr(1, activity: GitHubActivity(me: "me", lastComment: event(person("elin"), 5), lastCommit: at(1))), pr(2)]
        check(GitHubLogic.menuSummary([.created: created]) == "GitHub: 1 with new feedback", GitHubLogic.menuSummary([.created: created]))
        check(GitHubLogic.menuSummary([.created: [pr(2)]]) == "GitHub: nothing waiting for you", "none")
        check(GitHubLogic.newCommentsText(1) == "1 new comment" && GitHubLogic.newCommentsText(3) == "3 new comments", "text")
    }),
]

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw GitHubError.failed("missing value") }
    return value
}
