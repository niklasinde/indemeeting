import SwiftUI

/// One meeting brief in the notch bar: the meeting's title and time, then a row per section.
struct MeetingBriefCardView: View {
    let brief: MeetingBrief
    var now = Date()
    var onDismiss: ((MeetingBrief) -> Void)? = { MeetingBriefModel.shared.dismiss($0) }
    var onRecord: (() -> Void)? = { MeetingBriefModel.shared.startRecording() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting brief \u{00B7} \(starts)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(brief.event.title).font(.headline).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if let onDismiss {
                    Button { onDismiss(brief) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
                }
            }
            ForEach(Array(MeetingBriefLogic.sections(brief).enumerated()), id: \.offset) { _, section in row(section) }
            if MeetingBriefLogic.isEmpty(brief) {
                Text("Nothing earlier or named in the invitation to go on.").font(.caption).foregroundStyle(.secondary)
            }
            if let onRecord {
                Button("Start recording", action: onRecord).buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.blue)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private var starts: String {
        let minutes = Int((brief.event.start.timeIntervalSince(now) / 60).rounded(.up))
        let time = MeetingBriefLogic.time(brief.event.start)
        return minutes > 0 ? "\(time), in \(minutes) min" : time
    }

    private func row(_ section: BriefSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading).lineLimit(2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                    Text(section.lines.count > 1 ? "\u{2022} \(line)" : line).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The briefs waiting in the open notch bar.
struct MeetingBriefNotchStack: View {
    @ObservedObject private var briefs = MeetingBriefModel.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(briefs.visible) { MeetingBriefCardView(brief: $0) }
        }
        .padding(.horizontal, 16)
        .onAppear { briefs.markSeen() }
        .onHover { if $0 { briefs.markSeen() } }
    }
}

struct MeetingBriefSettingsSection: View {
    @AppStorage(MeetingBriefLogic.leadKey) private var lead = MeetingBriefLogic.defaultLead
    @AppStorage(MeetingBriefLogic.enabledKey) private var stored: Bool?
    @State private var calendarAccess = InCallHelp.shared.calendar.hasAccess

    private var enabled: Bool { stored ?? calendarAccess }

    var body: some View {
        SettingsSection("Meeting briefs", footer: "Shortly before a calendar meeting with someone else invited or a call link, a notification and a card "
                        + "in the notch bar say who is in it, what the last meetings with them decided and left open, the tickets and pull requests "
                        + "it names, and its agenda. Ministral adds a short aim on mains power.") {
            SettingsRow("Meeting briefs") {
                Toggle("Meeting briefs", isOn: Binding(get: { enabled }, set: { on in
                    stored = on
                    if on { CalendarAccessRow.request { calendarAccess = $0 } }
                    MeetingBriefModel.shared.tick()
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Show", detail: "How long before the meeting starts") {
                Picker("Show", selection: $lead) {
                    ForEach(MeetingBriefLogic.leadChoices, id: \.self) { Text("\($0) min before").tag($0) }
                }.labelsHidden().fixedSize().disabled(!enabled)
            }
            Divider().padding(.leading, 14)
            CalendarAccessRow(granted: "The calendar is read to find the meetings", missing: "Briefs need access to your calendar",
                              enabled: enabled, access: $calendarAccess)
        }
    }
}
