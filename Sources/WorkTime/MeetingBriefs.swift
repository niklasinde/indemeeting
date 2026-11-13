import AppKit
import Combine

/// Briefs the user shortly before a calendar meeting: a notification, and a card in the notch bar until the meeting starts or the
/// card is dismissed. The calendar is polled twice a minute while the setting is on and access was given.
@MainActor
final class MeetingBriefModel: ObservableObject {
    static let shared = MeetingBriefModel()
    static let pollInterval: TimeInterval = 30

    @Published private(set) var briefs: [MeetingBrief] = []
    @Published private(set) var unseen = 0
    var startRecording: () -> Void = {}
    private var dismissed: Set<String> = []
    private var briefed: [String: Date] = [:]
    private var store: MeetingStore?
    private weak var recorder: Recorder?
    private var timer: Timer?
    private var file = AppPaths.briefed
    private var calendar: InCallCalendar { InCallHelp.shared.calendar }

    var visible: [MeetingBrief] { briefs.filter { !dismissed.contains($0.id) } }

    func start(recorder: Recorder, store: MeetingStore, file: URL = AppPaths.briefed) {
        self.recorder = recorder
        self.store = store
        self.file = file
        briefed = MeetingBriefLogic.decodeBriefed(try? Data(contentsOf: file))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func dismiss(_ brief: MeetingBrief) { dismissed.insert(brief.id) }

    func markSeen() { if unseen > 0 { unseen = 0 } }

    /// Opens the notch bar on the briefs, from a clicked notification.
    func show() {
        markSeen()
        AskPanel.shared.peek(for: 20)
    }

    func tick() {
        let now = Date()
        if briefs.contains(where: { $0.event.start <= now }) { briefs.removeAll { $0.event.start <= now } }
        guard let store, calendar.hasAccess, MeetingBriefLogic.isEnabled(hasAccess: true) else { return }
        let lead = MeetingBriefLogic.lead()
        let events = calendar.events(from: now, to: now.addingTimeInterval(TimeInterval(lead) * 60))
        for event in MeetingBriefLogic.due(events, now: now, lead: lead, recording: recorder?.meeting != nil, briefed: Set(briefed.keys)) {
            briefed[MeetingBriefLogic.key(event)] = event.start
            save(now: now)
            Task { await announce(event, store: store) }
        }
    }

    private func announce(_ event: CalendarEventInfo, store: MeetingStore) async {
        var brief = await build(event, store: store)
        guard MeetingBriefLogic.worthShowing(brief) else { return }
        briefs.append(brief)
        unseen += 1
        Notifier.postBrief(title: MeetingBriefLogic.notificationTitle(event, now: Date()), body: MeetingBriefLogic.notificationBody(brief),
                           key: brief.id)
        guard !MeetingBriefLogic.isEmpty(brief), let aim = await aim(for: brief) else { return }
        brief.focus = aim
        if let index = briefs.firstIndex(where: { $0.id == brief.id }) { briefs[index] = brief }
    }

    /// The brief from the library, the invitation, and the Jira and GitHub state of what it names.
    func build(_ event: CalendarEventInfo, store: MeetingStore) async -> MeetingBrief {
        let now = Date()
        var brief = MeetingBrief(event: event, agenda: CalendarLogic.agenda(event.notes))
        let found = await Task.detached { () -> (seeds: [SpottedEntity], earlier: [PastMeeting]) in
            let vocabulary = (try? store.inCallVocabulary()) ?? InCallVocabulary()
            let seeds = CalendarLogic.seeds(event, vocabulary: vocabulary)
            let past = (try? store.pastMeetings(excluding: nil)) ?? []
            let ranked = InCallRetrieval.rank(past, context: MeetingBriefLogic.context(event, entities: seeds, now: now), limit: MeetingBriefLogic.earlierLimit)
            return (seeds, ranked.map { (try? store.pastMeetingDetails($0)) ?? $0 })
        }.value
        brief.earlier = found.earlier
        for seed in found.seeds {
            if seed.kind == .ticket, brief.tickets.count < MeetingBriefLogic.ticketLimit, let ticket = await ticket(seed.key) {
                brief.tickets.append(ticket)
            } else if let said = seed.pullRequest, brief.pullRequests.count < MeetingBriefLogic.pullRequestLimit,
                      let pr = await pullRequest(said) {
                brief.pullRequests.append(pr)
            }
        }
        return brief
    }

    private func ticket(_ key: String) async -> InCallCard.Ticket? {
        if let ticket = await EntityLookups.ticket(key) { return ticket }
        let cached = EntityLookups.ticketPlaceholder(key)
        return cached.summary == nil ? nil : cached
    }

    private func pullRequest(_ said: (repo: String?, number: Int)) async -> InCallCard.PullRequest? {
        guard let found = EntityLookups.resolve(pullRequest: said) else { return nil }
        if let cached = found.cached { return cached }
        return await EntityLookups.fetch(pullRequest: said.number, repo: found.repo)
    }

    /// Ministral's aim for the meeting, on mains power only like the in-call pass, and at the quiet pace.
    private func aim(for brief: MeetingBrief) async -> String? {
        guard InCallLogic.usesMinistral(), LocalLLM.isAvailable, !PowerSource.onBattery else { return nil }
        let prompt = MeetingBriefPrompts.aim(brief)
        let reply = try? await LocalLLM.shared.generate(system: prompt.system, prompt: prompt.prompt, schema: MeetingBriefPrompts.schema, maxTokens: 160)
        return reply.flatMap { MeetingBriefPrompts.parse($0.text) }
    }

    /// `meeting_brief`, handed over by the MCP server through the agent inbox.
    func answer(_ request: BriefRequest, now: Date = Date()) async -> NoticeReply {
        func reply(_ ok: Bool, _ message: String) -> NoticeReply { NoticeReply(id: request.id, ok: ok, notice: nil, message: message) }
        guard abs(now.timeIntervalSince(request.created)) <= AgentInbox.staleAfter else { return reply(false, "The request is too old.") }
        guard let store else { return reply(false, "WorkTime has not opened its library yet.") }
        guard calendar.hasAccess else {
            return reply(false, "WorkTime cannot read the calendar. Allow it under Settings > Meetings > Meeting briefs.")
        }
        let events = calendar.events(from: Calendar.current.startOfDay(for: now), to: now.addingTimeInterval(7 * 86400))
        guard let event = MeetingBriefLogic.pick(events, query: request.event, now: now) else {
            return reply(true, request.event == nil ? "No more meetings today.\n" : "No upcoming meeting matches \u{201C}\(request.event ?? "")\u{201D}.\n")
        }
        var brief = briefs.first { $0.id == MeetingBriefLogic.key(event) }
        if brief == nil { brief = await build(event, store: store) }
        return reply(true, brief.map { MeetingBriefLogic.text($0) } ?? "")
    }

    private func save(now: Date) {
        briefed = MeetingBriefLogic.pruned(briefed, now: now)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? MeetingBriefLogic.encode(briefed).write(to: file, options: .atomic)
    }

    #if DEBUG
    func showSample(_ briefs: [MeetingBrief], unseen: Int = 0) {
        self.briefs = briefs
        self.unseen = unseen
    }
    #endif
}
