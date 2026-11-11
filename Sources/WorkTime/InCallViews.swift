import SwiftUI

/// One in-call card: the calendar event, a ticket, a pull request, an earlier meeting or an answer. A click opens it.
struct InCallCardView: View {
    let card: InCallCard
    var onOpen: (InCallCard) -> Void = { InCallHelp.shared.open($0) }
    var onDismiss: ((InCallCard) -> Void)? = { InCallHelp.shared.dismiss($0) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 14, height: 14).foregroundStyle(.secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(caption).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(trailingColor).lineLimit(1).fixedSize() }
                    if let onDismiss {
                        Button { onDismiss(card) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss")
                    }
                }
                content
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { onOpen(card) }
    }

    @ViewBuilder private var icon: some View {
        switch card.kind {
        case .about: Image(systemName: "calendar").resizable().scaledToFit()
        case .ticket: BrandMark.jira.scaledToFit()
        case .pullRequest: BrandMark.gitHub.scaledToFit()
        case .meeting: Image(systemName: "person.2").resizable().scaledToFit()
        case .answer: Image(systemName: "sparkles").resizable().scaledToFit()
        }
    }

    private var caption: String {
        switch card.kind {
        case .about: "About this meeting"
        case .ticket(let ticket): ticket.key
        case .pullRequest(let pr): pr.label
        case .meeting(let meeting, let because):
            "Earlier meeting \u{00B7} \(meeting.date.formatted(.dateTime.day().month(.abbreviated))) \u{00B7} \(because.joined(separator: ", "))"
        case .answer(_, let question): InCallLogic.asksAboutLastTime(question) ? "What we decided last time" : question
        }
    }

    private var trailing: String? {
        switch card.kind {
        case .ticket(let ticket): ticket.status
        case .pullRequest(let pr): pr.checks ?? pr.state
        case .about(let event): "\(event.start.formatted(date: .omitted, time: .shortened))\u{2013}\(event.end.formatted(date: .omitted, time: .shortened))"
        default: nil
        }
    }

    private var trailingColor: Color {
        guard case .pullRequest(let pr) = card.kind, let checks = pr.checks else { return .secondary }
        return checks.hasSuffix("passed") ? .green : checks.hasSuffix("failed") ? .red : .yellow
    }

    @ViewBuilder private var content: some View {
        switch card.kind {
        case .about(let event):
            Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
            if !event.attendees.isEmpty { Text(people(event.attendees)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let agenda = event.notes { Text(agenda).font(.caption).lineLimit(3) }
        case .ticket(let ticket):
            Text(ticket.summary ?? "Looking up\u{2026}").lineLimit(1).foregroundStyle(ticket.summary == nil ? .secondary : .primary)
            if let assignee = ticket.assignee { Text(assignee).font(.caption).foregroundStyle(.secondary) }
        case .pullRequest(let pr):
            Text(pr.title ?? "Looking up\u{2026}").lineLimit(1).foregroundStyle(pr.title == nil ? .secondary : .primary)
            let state = [pr.checks == nil ? nil : pr.state, pr.review].compactMap { $0 }
            if !state.isEmpty { Text(state.joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary) }
        case .meeting(let meeting, _):
            Text(meeting.title).lineLimit(1)
            if let line = meeting.line { Text("\u{201C}\(line)\u{201D}").font(.caption).italic().lineLimit(2) }
            ForEach(Array((meeting.decisions + meeting.actionItems).prefix(2).enumerated()), id: \.offset) { _, point in
                Text("\u{2022} \(point)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case .answer(let answer, _):
            Text(answer.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let title = answer.meetingTitle {
                Text("From \(title)\(answer.date.map { " \u{00B7} " + $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func people(_ attendees: [CalendarAttendee]) -> String {
        let names = attendees.map(\.label)
        return names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " +\(names.count - 4)" : "")
    }
}

/// The cards of the call being recorded, newest first under the meeting's own, with the "last time" question.
struct InCallCardList: View {
    @ObservedObject var help = InCallHelp.shared
    var limit = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { help.ask() } label: {
                Label(help.asking ? "Looking through earlier meetings\u{2026}" : "What did we decide last time?", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(help.asking)
            ForEach(help.visible.prefix(limit)) { InCallCardView(card: $0) }
        }
    }
}

/// The in-call cards in the open notch bar.
struct InCallNotchStack: View {
    @ObservedObject private var help = InCallHelp.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("During this call", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            NotchScroll { InCallCardList(limit: 8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .onAppear { help.markSeen() }
        .onHover { if $0 { help.markSeen() } }
    }
}

/// Below the closed notch while a call is recorded and cards wait: their count. Hovering opens the bar on them.
struct InCallNotchBadge: View {
    let count: Int
    let onHover: () -> Void

    var body: some View {
        Label("\(count)", systemImage: "lightbulb")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.black))
            .contentShape(Rectangle())
            .onHover { if $0 { onHover() } }
            .onTapGesture(perform: onHover)
            .help("Help during this call")
    }
}

/// The recording meeting's sidebar with the live cards.
struct InCallSidebar: View {
    static let width: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("During this call").font(.headline)
                InCallCardList()
            }
            .padding(14)
        }
        .frame(width: Self.width)
        .background(Color.primary.opacity(0.03))
    }
}

/// Under a meeting's title: its calendar event and the tickets and pull requests mentioned in it.
struct MeetingMentionsLine: View {
    let fileName: String
    var store: MeetingStore? = InCallHelp.shared.store
    @State private var event: StoredMeetingEvent?
    @State private var mentioned: String?

    var body: some View {
        HStack(spacing: 10) {
            if let event {
                Label(event.event.title, systemImage: "calendar").lineLimit(1)
                    .help([event.event.attendees.map(\.label).joined(separator: ", "), event.agenda ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
            if let mentioned { Text("Mentioned: \(mentioned)").lineLimit(1).truncationMode(.tail).textSelection(.enabled) }
        }
        .task(id: fileName) { load() }
        .onReceive(NotificationCenter.default.publisher(for: MeetingStore.mentionsDidChange)) { _ in load() }
    }

    private func load() {
        event = try? store?.calendarEvent(of: fileName)
        mentioned = InCallLogic.mentioned((try? store?.mentions(of: fileName)) ?? [])
    }
}

struct InCallSettingsSection: View {
    @AppStorage(InCallLogic.enabledKey) private var enabled = true
    @AppStorage(InCallLogic.ministralKey) private var ministral = true
    @State private var calendarAccess = InCallHelp.shared.calendar.hasAccess

    var body: some View {
        SettingsSection("Help during calls", footer: "While a meeting is recorded, tickets, pull requests and names said in it are looked "
                        + "up and shown as cards behind a badge under the notch and in the meeting's sidebar, with earlier meetings about "
                        + "them. With calendar access the meeting's invitation adds its agenda and people. Ministral runs once a minute "
                        + "on mains power to catch what was missed.") {
            SettingsRow("Help during calls") {
                Toggle("Help during calls", isOn: Binding(get: { enabled }, set: { on in
                    enabled = on
                    if on { requestCalendar() }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Use Ministral", detail: LocalLLM.isAvailable ? "Finds spoken references and answers \u{201C}what did we decide last time?\u{201D}"
                        : "Download Ministral below to use it") {
                Toggle("Use Ministral", isOn: $ministral).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!enabled)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Calendar", detail: calendarAccess ? "The invitation of the meeting being recorded is read"
                        : "Allow access to see what the meeting is about") {
                if calendarAccess {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if !InCallHelp.shared.calendar.canAsk {
                    Text("Off in System Settings").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Allow\u{2026}", action: requestCalendar).disabled(!enabled)
                }
            }
        }
    }

    private func requestCalendar() {
        let calendar = InCallHelp.shared.calendar
        guard calendar.canAsk else { return }
        Task { calendarAccess = await calendar.requestAccess() }
    }
}
