import AppKit
import Combine
import EventKit
import IOKit.ps

/// Help during a recorded call: spots tickets, pull requests and known names in the live transcript, looks them up,
/// finds earlier meetings about them and the calendar event the call is in, and answers "what did we decide last time?".
/// The cards wait in the notch behind a badge and in the recording meeting's sidebar; nothing pops up on its own.
@MainActor
final class InCallHelp: ObservableObject {
    static let shared = InCallHelp()

    @Published private(set) var cards: [InCallCard] = []
    @Published private(set) var dismissed: Set<String> = []
    @Published private(set) var unseen = 0
    @Published private(set) var meeting: URL?
    @Published private(set) var asking = false

    var openMeeting: (Int64) -> Void = { _ in }
    let calendar = InCallCalendar()
    private(set) var entities: [SpottedEntity] = []
    private(set) var store: MeetingStore?
    private weak var recorder: Recorder?
    private var subscriptions: Set<AnyCancellable> = []
    private var vocabulary = InCallVocabulary()
    private var event: CalendarEventInfo?
    private var sourceApp: String?
    private var processed = Set<String>()
    private var newLines = 0
    private var lastModelRun: Date?
    private var modelRunning = false
    private var lastQuestion: Date?
    private var recording = 0
    private var online = true

    var visible: [InCallCard] { InCallCard.order(cards, dismissed: dismissed) }

    func start(recorder: Recorder, store: MeetingStore) {
        self.recorder = recorder
        self.store = store
        recorder.$meeting.removeDuplicates().sink { [weak self] meeting in
            MainActor.assumeIsolated { self?.follow(meeting) }
        }.store(in: &subscriptions)
        recorder.live.$transcript.debounce(for: .seconds(1), scheduler: RunLoop.main).sink { [weak self] transcript in
            MainActor.assumeIsolated { self?.hear(transcript) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recorder?.meeting != nil, InCallLogic.isEnabled() != (self.meeting != nil) else { return }
                self.follow(self.recorder?.meeting)
            }
        }.store(in: &subscriptions)
    }

    func dismiss(_ card: InCallCard) { dismissed.insert(card.id) }

    func markSeen() { if unseen > 0 { unseen = 0 } }

    func open(_ card: InCallCard) {
        markSeen()
        switch card.kind {
        case .ticket(let ticket): if let url = ticket.url { NSWorkspace.shared.open(url) }
        case .pullRequest(let pr):
            guard let target = GitHubLink.pullRequest(at: pr.url) else { return }
            if let show = GitHubModel.shared.showInWindow { show(target) } else if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        case .meeting(let meeting, _): openMeeting(meeting.id)
        case .answer(let answer, _): if let id = answer.meetingID { openMeeting(id) }
        case .about: break
        }
    }

    /// Answers from the earlier meetings that match this call best: with Ministral when it is on, else with the best
    /// meeting's decisions.
    func ask(_ question: String = "What did we decide last time?") {
        guard let store, meeting != nil, !asking else { return }
        let file = meeting?.lastPathComponent, generation = recording
        let context = RetrievalContext(entities: Set(entities.map(\.id)), title: event?.title, attendees: event?.attendees.map(\.identity) ?? [],
                                       sourceApp: sourceApp, seriesID: event?.seriesID)
        let useModel = InCallLogic.usesMinistral() && LocalLLM.isAvailable
        let language = recorder?.live.language?.englishName ?? "English"
        asking = true
        lastQuestion = Date()
        Task {
            let best = await Task.detached {
                (try? InCallRetrieval.rank(store.pastMeetings(excluding: file), context: context).map(store.pastMeetingDetails)) ?? []
            }.value
            var answer: InCallAnswer?
            if useModel, !best.isEmpty {
                let prompt = InCallPrompts.decision(question: question, meetings: best, language: language)
                if let reply = try? await LocalLLM.shared.generate(system: prompt.system, prompt: prompt.prompt, schema: InCallPrompts.decisionSchema,
                                                                   maxTokens: 250, urgent: true) {
                    answer = InCallPrompts.parseDecision(reply.text, meetings: best)
                }
            }
            asking = false
            guard generation == recording else { return }
            let found = answer ?? best.first.flatMap(InCallPrompts.fallback) ?? InCallAnswer(text: "No earlier meeting about this was found.")
            insert(InCallCard(id: "answer", kind: .answer(found, question: question), added: Date()))
        }
    }

    private func follow(_ url: URL?) {
        recording += 1
        cards = []
        dismissed = []
        unseen = 0
        entities = []
        processed = []
        event = nil
        sourceApp = nil
        lastModelRun = nil
        newLines = 0
        meeting = InCallLogic.isEnabled() ? url : nil
        guard let url = meeting, let store else { return }
        let file = url.lastPathComponent, generation = recording, start = Date()
        Task {
            let loaded = await Task.detached { ((try? store.inCallVocabulary()) ?? InCallVocabulary(), (try? store.mentions(of: file)) ?? []) }.value
            guard generation == recording else { return }
            vocabulary = loaded.0
            add(loaded.1, save: false)
            if let recorder { hear(recorder.live.transcript) }
            await findEvent(file: file, start: start, generation: generation)
        }
    }

    /// The calendar event of the call, looked for at once and again once the call's app is known.
    private func findEvent(file: String, start: Date, generation: Int) async {
        guard let store else { return }
        if let stored = try? store.calendarEvent(of: file) { return show(stored.event, agenda: stored.agenda, file: file, save: false) }
        guard calendar.hasAccess else { return }
        for delay: UInt64 in [0, 30] {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard generation == recording else { return }
            sourceApp = (try? store.meetings())?.first { $0.audioFile == file }?.source?.app
            if let picked = calendar.event(at: start, sourceApp: sourceApp), picked.id != event?.id {
                show(picked, agenda: CalendarLogic.agenda(picked.notes), file: file, save: true)
            }
            if sourceApp != nil { return }
        }
    }

    private func show(_ found: CalendarEventInfo, agenda: String?, file: String, save: Bool) {
        event = found
        var shown = found
        shown.notes = agenda
        insert(InCallCard(id: "about", kind: .about(shown), added: Date()))
        if save, let store { Task.detached { try? store.saveCalendarEvent(file, StoredMeetingEvent(event: found, agenda: agenda)) } }
        add(CalendarLogic.seeds(found, vocabulary: vocabulary))
        showLastTime()
    }

    /// The earlier meeting most like this one, from its event, as a card of its own.
    private func showLastTime() {
        guard let store, let event else { return }
        let file = meeting?.lastPathComponent, generation = recording
        let context = RetrievalContext(title: event.title, attendees: event.attendees.map(\.identity), sourceApp: sourceApp, seriesID: event.seriesID)
        Task {
            let best = await Task.detached {
                (try? InCallRetrieval.rank(store.pastMeetings(excluding: file), context: context, limit: 1).map(store.pastMeetingDetails)) ?? []
            }.value
            guard generation == recording, let meeting = best.first else { return }
            insert(InCallCard(id: "meeting:\(meeting.id)", kind: .meeting(meeting, because: ["Last time"]), added: Date()))
        }
    }

    private func hear(_ transcript: LiveTranscript) {
        guard meeting != nil else { return }
        let lines = transcript.lines.filter(\.isFinal)
        let fresh = lines.filter { processed.insert("\($0.speaker)|\($0.start)|\($0.text)").inserted }
        guard !fresh.isEmpty else { return }
        for line in fresh {
            let context = InCallLogic.repoContext(entities, at: line.start, vocabulary: vocabulary)
            add(EntitySpotter.spot(line.text, at: line.start, vocabulary: vocabulary, repoContext: context))
            if InCallLogic.asksAboutLastTime(line.text), lastQuestion.map({ Date().timeIntervalSince($0) > 60 }) ?? true { ask(line.text) }
        }
        newLines += fresh.count
        considerModel(lines)
    }

    private func considerModel(_ lines: [LiveLine]) {
        let pending = lines.filter(\.isPending).count
        guard !modelRunning, InCallLogic.shouldAskModel(now: Date(), last: lastModelRun, onBattery: PowerSource.onBattery, pending: pending,
                                                        newLines: newLines, allowed: InCallLogic.usesMinistral() && LocalLLM.isAvailable)
        else { return }
        lastModelRun = Date()
        newLines = 0
        modelRunning = true
        let end = lines.last?.start ?? 0
        let recent = lines.filter { $0.start >= end - InCallLogic.modelWindow }.map { "\($0.speaker == .you ? "Me" : "Them"): \($0.text)" }
        let prompt = InCallPrompts.extraction(lines: recent, vocabulary: vocabulary)
        let vocabulary = vocabulary, generation = recording
        Task {
            let reply = try? await LocalLLM.shared.generate(system: prompt.system, prompt: prompt.prompt, schema: InCallPrompts.extractionSchema,
                                                            maxTokens: 300)
            modelRunning = false
            guard generation == recording, let reply else { return }
            let parsed = InCallPrompts.parseExtraction(reply.text, at: end, vocabulary: vocabulary)
            add(parsed.entities.map { SpottedEntity(kind: $0.kind, key: $0.key, line: recent.last ?? "", at: $0.at) })
            if parsed.asks, lastQuestion.map({ Date().timeIntervalSince($0) > 60 }) ?? true { ask(recent.last ?? "What did we decide last time?") }
        }
    }

    private func add(_ found: [SpottedEntity], save: Bool = true) {
        let merged = InCallLogic.merge(entities, found)
        entities = merged.all
        guard !merged.added.isEmpty else { return }
        if save, let store, let file = meeting?.lastPathComponent {
            let added = merged.added.filter { $0.pullRequest.map { $0.repo != nil } ?? true }
            Task.detached { try? store.saveMentions(file, added) }
        }
        merged.added.forEach(lookUp)
    }

    private func insert(_ card: InCallCard) {
        let isNew = !cards.contains { $0.id == card.id }
        InCallCard.upsert(card, into: &cards)
        if isNew && !dismissed.contains(card.id) { unseen += 1 }
    }

    private func lookUp(_ entity: SpottedEntity) {
        switch entity.kind {
        case .ticket: lookUpTicket(entity.key)
        case .pullRequest: lookUpPullRequest(entity)
        case .name: break
        }
        findMeetings(entity)
    }

    private func lookUpTicket(_ key: String) {
        let id = "ticket:\(key)", generation = recording
        insert(InCallCard(id: id, kind: .ticket(EntityLookups.ticketPlaceholder(key)), added: Date()))
        guard online else { return }
        Task {
            guard let ticket = await EntityLookups.ticket(key), generation == recording else { return }
            insert(InCallCard(id: id, kind: .ticket(ticket), added: Date()))
        }
    }

    private func lookUpPullRequest(_ entity: SpottedEntity) {
        guard let said = entity.pullRequest, let found = EntityLookups.resolve(pullRequest: said) else { return }
        let id = "pr:\(found.repo)#\(said.number)", generation = recording
        if let cached = found.cached {
            insert(InCallCard(id: id, kind: .pullRequest(cached), added: Date()))
            return
        }
        insert(InCallCard(id: id, kind: .pullRequest(.init(repo: found.repo, number: said.number)), added: Date()))
        guard online else { return }
        Task {
            guard let fetched = await EntityLookups.fetch(pullRequest: said.number, repo: found.repo), generation == recording else { return }
            insert(InCallCard(id: id, kind: .pullRequest(fetched), added: Date()))
        }
    }

    private func findMeetings(_ entity: SpottedEntity) {
        guard let store else { return }
        let file = meeting?.lastPathComponent, generation = recording, limit = entity.kind == .name ? 1 : 2
        Task {
            let found = await Task.detached { () -> [PastMeeting] in
                ((try? store.meetings(mentioning: entity, excluding: file, limit: limit)) ?? []).compactMap { hit in
                    guard let meeting = try? store.meeting(id: hit.id) else { return nil }
                    let past = PastMeeting(id: meeting.id, title: meeting.title, date: meeting.created, line: hit.line)
                    return (try? store.pastMeetingDetails(past)) ?? past
                }
            }.value
            guard generation == recording else { return }
            for past in found {
                let id = "meeting:\(past.id)"
                if let index = cards.firstIndex(where: { $0.id == id }), case .meeting(let shown, let because) = cards[index].kind {
                    if !because.contains(entity.label) { cards[index].kind = .meeting(shown, because: because + [entity.label]) }
                } else {
                    insert(InCallCard(id: id, kind: .meeting(past, because: [entity.label]), added: Date()))
                }
            }
        }
    }

    #if DEBUG
    func showSample(cards: [InCallCard], meeting: URL?, unseen: Int, store: MeetingStore? = nil) {
        if let store { self.store = store }
        self.cards = cards
        self.meeting = meeting
        self.unseen = unseen
    }

    /// Runs the spotter over `lines` as if heard live, with `store` as the library, for `--render-incall`.
    func replay(_ lines: [LiveLine], store: MeetingStore, meeting: URL, event: CalendarEventInfo?) {
        online = false
        self.store = store
        self.meeting = meeting
        vocabulary = (try? store.inCallVocabulary()) ?? InCallVocabulary()
        if let event { show(event, agenda: CalendarLogic.agenda(event.notes), file: meeting.lastPathComponent, save: true) }
        var transcript = LiveTranscript()
        transcript.hear(lines.map { TranscriptSegment(start: $0.start, text: $0.text) }, from: .others, isFinal: true)
        hear(transcript)
    }
    #endif
}

/// The Jira and GitHub lookups in-call help and the meeting brief share. Both skip quietly when the service is not set up.
@MainActor
enum EntityLookups {
    static func ticketPlaceholder(_ key: String) -> InCallCard.Ticket {
        let directory = GitHubModel.shared.directory
        let url = JiraModel.shared.site.flatMap { JiraLogic.browseURL(site: $0, key: key) } ?? directory.url(for: key)
        return InCallCard.Ticket(key: key, summary: directory.titles[key], url: url)
    }

    static func ticket(_ key: String) async -> InCallCard.Ticket? {
        let jira = JiraModel.shared
        guard jira.ready, let client = jira.client(), let issue = try? await client.issue(key) else { return nil }
        var ticket = ticketPlaceholder(key)
        ticket.summary = issue.summary
        ticket.status = issue.status
        ticket.assignee = issue.assignee ?? "Unassigned"
        return ticket
    }

    /// The repository a pull request is in, and its cached state when the GitHub lists hold it.
    static func resolve(pullRequest said: (repo: String?, number: Int)) -> (repo: String, cached: InCallCard.PullRequest?)? {
        let github = GitHubModel.shared
        let cached = github.prs.values.flatMap { $0 } + github.watchedPRs
        let matching = cached.filter { $0.number == said.number && (said.repo == nil || $0.repo == said.repo) }
        guard let repo = said.repo ?? (Set(matching.map(\.repo)).count == 1 ? matching.first?.repo : nil) else { return nil }
        return (repo, matching.first { $0.repo == repo }.map(card))
    }

    static func fetch(pullRequest number: Int, repo: String) async -> InCallCard.PullRequest? {
        guard GitHubModel.shared.enabled else { return nil }
        let cli = GitHubLogic.findCLI()
        let result = await Task.detached { GitHubClient.fetchDetail(cli: cli, repo: repo, number: number) }.value
        guard case .success(let fetched) = result else { return nil }
        let detail = fetched.detail
        return InCallCard.PullRequest(repo: repo, number: number, title: detail.title, state: state(detail.state, draft: detail.isDraft),
                                      checks: checks(detail.rollup), review: review(detail.review))
    }

    static func card(_ pr: GitHubPR) -> InCallCard.PullRequest {
        InCallCard.PullRequest(repo: pr.repo, number: pr.number, title: pr.title, state: state(pr.state, draft: pr.isDraft), checks: checks(pr.checks),
                               review: review(pr.review))
    }

    private static func state(_ state: GitHubPR.State, draft: Bool) -> String {
        draft && state == .open ? "Draft" : state.rawValue.capitalized
    }

    private static func checks(_ checks: GitHubPR.Checks) -> String? {
        switch checks {
        case .passed: "Checks passed"
        case .failed: "Checks failed"
        case .running: "Checks running"
        case .none: nil
        }
    }

    private static func review(_ review: GitHubPR.Review?) -> String? {
        switch review {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .required: "Review required"
        case nil: nil
        }
    }
}

/// The user's calendars through EventKit, read only when access was given from the in-call help setting.
final class InCallCalendar {
    private let store = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var canAsk: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    func requestAccess() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }

    func event(at start: Date, sourceApp: String?) -> CalendarEventInfo? {
        guard hasAccess else { return nil }
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-4 * 3600), end: start.addingTimeInterval(3600), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && $0.status != .canceled }.map(Self.info)
        return CalendarLogic.pick(events, at: start, sourceApp: sourceApp)
    }

    /// Events starting in `from..<to`, as the user's calendars hold them.
    func events(from: Date, to: Date) -> [CalendarEventInfo] {
        guard hasAccess else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).map(Self.info)
            .filter { $0.start >= from && $0.start < to }.sorted { $0.start < $1.start }
    }

    private static func info(_ event: EKEvent) -> CalendarEventInfo {
        let attendees = (event.attendees ?? []).filter { !$0.isCurrentUser }.map { person in
            let address = person.url.absoluteString.lowercased().hasPrefix("mailto:") ? String(person.url.absoluteString.dropFirst(7)) : nil
            return CalendarAttendee(name: person.name, email: address)
        }
        return CalendarEventInfo(id: event.calendarItemIdentifier, seriesID: event.hasRecurrenceRules ? event.calendarItemExternalIdentifier : nil,
                                 title: event.title ?? "", start: event.startDate, end: event.endDate, attendees: attendees, notes: event.notes,
                                 url: event.url?.absoluteString, location: event.location, isAllDay: event.isAllDay,
                                 declined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
                                 cancelled: event.status == .canceled)
    }
}

enum PowerSource {
    static var onBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String != kIOPMACPowerKey || ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
