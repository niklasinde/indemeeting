#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-incall <folder> [--incall-fixture <transcript.txt>]` builds a made-up library in
/// `<folder>/data`, replays the fixture (or a sample call) through in-call help without network lookups, writes what it
/// spotted and found to `<folder>/fixture-report.txt`, and saves PNGs of the notch cards, the meeting's sidebar and the setting.
@MainActor
enum InCallPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-incall", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let data = output.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.removeItem(at: data)
        let now = Date()
        let store: MeetingStore
        do {
            store = try MeetingStore.open(at: data.appendingPathComponent("meetings.sqlite"))
            try seed(store, now: now)
        } catch {
            FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let lines = PhoneCommandLine.value("--incall-fixture", in: CommandLine.arguments).flatMap(fixture) ?? sampleCall
        Task { @MainActor in
            let help = InCallHelp.shared
            let meeting = data.appendingPathComponent("Recordings/Meeting-2026-11-11-1000.m4a")
            try? store.beginRecording(meeting.lastPathComponent, created: now, audioExpiresAt: nil)
            help.replay(lines, store: store, meeting: meeting, event: event(now))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !help.cards.contains(where: { if case .answer = $0.kind { true } else { false } }) { help.ask() }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let report = self.report(help, store: store, file: meeting.lastPathComponent)
            print(report)
            try? report.write(to: output.appendingPathComponent("fixture-report.txt"), atomically: true, encoding: .utf8)

            let bar = NotchBar(screen: NSScreen.main ?? NSScreen.screens[0])
            @MainActor func shot(_ name: String, _ view: some View, appearance: NSAppearance.Name = .darkAqua) async {
                await NotchPreview.render(view, appearance: appearance, to: output.appendingPathComponent("\(name).png"))
            }
            await shot("notch-replayed", bar.sample(list: nil, hasNotch: true, peeking: true).frame(width: 640).padding(.bottom, 8)
                .background(Color.gray.opacity(0.35)))
            help.showSample(cards: sampleCards(now), meeting: meeting, unseen: 3, store: store)
            await shot("notch-badge", bar.sample(list: nil, hasNotch: true).frame(width: 640, height: 80, alignment: .top)
                .background(Color.gray.opacity(0.35)))
            await shot("notch-cards", bar.sample(list: nil, hasNotch: true, peeking: true).frame(width: 640).padding(.bottom, 8)
                .background(Color.gray.opacity(0.35)))
            await shot("notch-cards-with-list", bar.sample(list: .jira, hasNotch: true).frame(width: 640).padding(.bottom, 8)
                .background(Color.gray.opacity(0.35)))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                let page = { (view: AnyView) in view.background(Color(nsColor: .windowBackgroundColor)) }
                await shot("sidebar-\(suffix)", page(AnyView(InCallSidebar().frame(height: 760))), appearance: appearance)
                await shot("mentions-line-\(suffix)", page(AnyView(MeetingMentionsLine(fileName: meeting.lastPathComponent, store: store)
                    .font(.caption).foregroundStyle(.secondary).padding(20).frame(width: 640, alignment: .leading))), appearance: appearance)
                await shot("settings-\(suffix)", page(AnyView(InCallSettingsSection().padding(24).frame(width: 520))), appearance: appearance)
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    /// One line per transcript line: `[mm:ss] text`, or the text alone, eight seconds apart.
    private static func fixture(_ path: String) -> [LiveLine]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated().map { index, raw in
            if let match = raw.wholeMatch(of: #/\s*\[(\d+):(\d\d)\]\s*(.*)/#), let minutes = Double(match.1), let seconds = Double(match.2) {
                return LiveLine(speaker: .others, start: minutes * 60 + seconds, text: String(match.3), isFinal: true)
            }
            return LiveLine(speaker: .others, start: Double(index) * 8, text: raw, isFinal: true)
        }
    }

    private static func report(_ help: InCallHelp, store: MeetingStore, file: String) -> String {
        var lines = ["Spotted:"]
        lines += help.entities.map { "  \($0.id)  @\(Int($0.at))s  \u{201C}\($0.line)\u{201D}" }
        lines.append("Cards (as shown):")
        for card in help.visible {
            switch card.kind {
            case .about(let event): lines.append("  about: \(event.title) \u{00B7} \(event.attendees.map(\.label).joined(separator: ", ")) \u{00B7} \(event.notes ?? "")")
            case .ticket(let ticket): lines.append("  ticket: \(ticket.key) \(ticket.summary ?? "?") \(ticket.url?.absoluteString ?? "")")
            case .pullRequest(let pr): lines.append("  pr: \(pr.label) \(pr.title ?? "?") \(pr.checks ?? "") \(pr.review ?? "")")
            case .meeting(let meeting, let because):
                lines.append("  meeting: #\(meeting.id) \(meeting.title) because \(because) line: \(meeting.line ?? "-") decisions: \(meeting.decisions.prefix(2))")
            case .answer(let answer, let question): lines.append("  answer to \u{201C}\(question)\u{201D}: \(answer.text) [\(answer.meetingTitle ?? "-")]")
            }
        }
        lines.append("Stored with the meeting: \(InCallLogic.mentioned((try? store.mentions(of: file)) ?? []) ?? "-") \u{00B7} event: \((try? store.calendarEvent(of: file))?.event.title ?? "-")")
        return lines.joined(separator: "\n")
    }

    private static let sampleCall: [LiveLine] = [
        "Hej allihop, ska vi börja med exporten till Gaia?",
        "Ja, kvidly 90 31 är nästan klar, PR:en ligger i finq api.",
        "PR 2688, checksen gick igenom i morse.",
        "Och Q D L Y 8178 om sökningen, den är i review.",
        "Great, and the admin UI part is finq.admin-ui#664.",
        "Vad bestämde vi förra gången om formatet?",
    ].enumerated().map { LiveLine(speaker: $0.offset.isMultiple(of: 2) ? .you : .others, start: Double($0.offset) * 9, text: $0.element, isFinal: true) }

    private static func event(_ now: Date) -> CalendarEventInfo {
        CalendarEventInfo(id: "e-today", seriesID: "gaia-weekly", title: "Gaia \u{00B7} weekly export sync", start: now.addingTimeInterval(-120),
                          end: now.addingTimeInterval(1680),
                          attendees: [CalendarAttendee(name: "Anna Berg", email: "anna@gaia.example"), CalendarAttendee(name: "Bo Lind", email: "bo@quiddly.example"),
                                      CalendarAttendee(name: nil, email: "elin@gaia.example")],
                          notes: "Agenda:\n1. CSV export status (QDLY-9031)\n2. Search fields\n\nMicrosoft Teams meeting\nJoin on your computer\nhttps://teams.microsoft.com/l/meetup-join/x\nMeeting ID: 123",
                          url: nil, location: "Microsoft Teams Meeting")
    }

    private static func seed(_ store: MeetingStore, now: Date) throws {
        try store.write {
            try store.db.run("INSERT INTO jira_sites (prefix, site, updated) VALUES ('QDLY', 'quiddly.atlassian.net', 0), ('ISD', 'quiddly.atlassian.net', 0)")
            try store.db.run("INSERT INTO tickets (key, title, site, updated) VALUES ('QDLY-9031', 'Export invoices to Gaia as CSV', 'quiddly.atlassian.net', 0)")
        }
        _ = try store.addProject("Gaia")
        let day: TimeInterval = 86400
        let earlier: [(file: String, daysAgo: Double, summary: MeetingSummary, mentions: [SpottedEntity], event: CalendarEventInfo?)] = [
            ("Meeting-2026-11-04-1000.m4a", 7,
             MeetingSummary(title: "Gaia-exporten blir CSV", actionItems: [.init(task: "Testa exporten mot Gaias testmiljö", owner: "Anna")],
                            topics: [.init(title: "Format", points: ["Exporten går som CSV med semikolon.", "Excel-formatet väntar till Q1."])]),
             [SpottedEntity(kind: .ticket, key: "QDLY-9031", line: "QDLY 9031, exporten, ska vi köra CSV?", at: 40)],
             CalendarEventInfo(id: "e-last", seriesID: "gaia-weekly", title: "Gaia \u{00B7} weekly export sync", start: now.addingTimeInterval(-7 * day),
                               end: now.addingTimeInterval(-7 * day + 1800), attendees: [CalendarAttendee(name: "Anna Berg", email: "anna@gaia.example")])),
            ("Meeting-2026-10-28-1400.m4a", 14,
             MeetingSummary(title: "Release av sökningen", actionItems: [.init(task: "Skriva release notes", owner: nil)],
                            topics: [.init(title: "Sökning", points: ["QDLY-8178 släpps på tisdag."])]),
             [SpottedEntity(kind: .pullRequest, key: "quiddly-com/finq.api#2688", line: "PR 2688 needs one more review", at: 300)], nil),
        ]
        for meeting in earlier {
            try store.beginRecording(meeting.file, created: now.addingTimeInterval(-meeting.daysAgo * day), audioExpiresAt: nil)
            try store.saveSummary(meeting.file, ParsedSummary(meeting.summary, engine: "sample"))
            try store.saveMentions(meeting.file, meeting.mentions)
            if let event = meeting.event { try store.saveCalendarEvent(meeting.file, StoredMeetingEvent(event: event, agenda: nil)) }
        }
        let pr = GitHubPR(url: "https://github.com/quiddly-com/finq.api/pull/2688", number: 2688, title: "QDLY-9031: Export invoices as CSV",
                          repo: "quiddly-com/finq.api", updated: now, review: .approved, checks: .passed)
        let ui = GitHubPR(url: "https://github.com/quiddly-com/finq.admin-ui/pull/664", number: 664, title: "QDLY-8178: Search the fields the count came from",
                          repo: "quiddly-com/finq.admin-ui", updated: now, review: .required, checks: .running)
        try store.saveGitHubPRs([.created: [pr, ui]])
        GitHubModel.shared.showSample(prs: [.created: [pr, ui]], directory: try store.ticketDirectory())
    }

    private static func sampleCards(_ now: Date) -> [InCallCard] {
        var about = event(now)
        about.notes = CalendarLogic.agenda(about.notes)
        var last = PastMeeting(id: 1, title: "Gaia-exporten blir CSV", date: now.addingTimeInterval(-7 * 86400), line: "QDLY 9031, exporten, ska vi köra CSV?")
        last.decisions = ["Exporten går som CSV med semikolon.", "Excel-formatet väntar till Q1."]
        return [
            InCallCard(id: "about", kind: .about(about), added: now),
            InCallCard(id: "ticket:QDLY-9031", kind: .ticket(.init(key: "QDLY-9031", summary: "Export invoices to Gaia as CSV", status: "In Review",
                                                                   assignee: "Niklas Inde")), added: now.addingTimeInterval(10)),
            InCallCard(id: "pr:quiddly-com/finq.api#2688", kind: .pullRequest(.init(repo: "quiddly-com/finq.api", number: 2688,
                                                                                      title: "QDLY-9031: Export invoices as CSV", state: "Open",
                                                                                      checks: "Checks passed", review: "Approved")), added: now.addingTimeInterval(20)),
            InCallCard(id: "meeting:1", kind: .meeting(last, because: ["QDLY-9031"]), added: now.addingTimeInterval(25)),
            InCallCard(id: "answer", kind: .answer(InCallAnswer(text: "Ni bestämde CSV med semikolon; Excel väntar till Q1. Anna testar mot Gaias testmiljö.",
                                                                meetingID: 1, meetingTitle: last.title, date: last.date),
                                                   question: "Vad bestämde vi förra gången om formatet?"), added: now.addingTimeInterval(30)),
        ]
    }
}
#endif
