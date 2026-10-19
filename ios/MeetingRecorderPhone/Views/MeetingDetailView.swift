import SwiftUI

struct MeetingDetailView: View {
    enum Page: String, CaseIterable, Identifiable {
        case summary = "Summary", notes = "Notes", transcript = "Transcript", actions = "Actions"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var appModel
    @Environment(Router.self) private var router
    let route: MeetingRoute
    @State private var resource: Resource<PhoneMeetingDetail>?
    @State private var page = Page.summary
    @State private var asking = false

    var body: some View {
        Group {
            if let resource, let meeting = resource.value {
                content(meeting, resource)
            } else if let error = resource?.error {
                ProblemView(title: error.problemTitle, message: error.hint, actionTitle: "Try again") { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(route.title ?? "Meeting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let meeting = resource?.value {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: PhoneFormat.markdown(for: meeting), subject: Text(meeting.title), message: nil) {
                        Label("Share summary", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { asking = true } label: { Label("Ask about this meeting", systemImage: "bubble.left.and.text.bubble.right") }
                }
            }
        }
        .sheet(isPresented: $asking) {
            if let meeting = resource?.value {
                ChatSheet(scope: PhoneChatScope(kind: "meeting", meetingId: meeting.id), title: meeting.title)
            }
        }
        .task { await load() }
        .onChange(of: router.pendingSeek[route.id]) { _, _ in consumeSeek() }
    }

    private func load() async {
        let resource = resource ?? Resource<PhoneMeetingDetail>(model: appModel)
        self.resource = resource
        await resource.load("meeting.\(route.id)", .get("/v1/meetings/\(route.id)"), idleTimeout: 30)
        appModel.cache?.trim(prefix: "meeting.", keeping: 40)
        consumeSeek()
    }

    private func consumeSeek() {
        guard let meeting = resource?.value, meeting.audio.available, let seek = router.pendingSeek.removeValue(forKey: meeting.id) else { return }
        appModel.player.load(track(meeting), autoplay: true, at: seek)
        page = .transcript
    }

    private func track(_ meeting: PhoneMeetingDetail) -> AudioPlayer.Track {
        AudioPlayer.Track(meetingId: meeting.id, title: meeting.title, duration: meeting.audio.duration ?? meeting.duration ?? 0)
    }

    private func content(_ meeting: PhoneMeetingDetail, _ resource: Resource<PhoneMeetingDetail>) -> some View {
        List {
            SyncBanner(error: resource.error, syncedAt: resource.syncedAt) { Task { await load() } }
                .listRowBackground(Color.orange.opacity(0.12))
            Section {
                header(meeting)
            }
            if meeting.audio.available {
                Section { AudioCard(track: track(meeting)) }
            }
            Section {
                Picker("Section", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            switch page {
            case .summary: SummarySection(meeting: meeting)
            case .notes: NotesSection(meeting: meeting)
            case .transcript: TranscriptSection(meeting: meeting, track: track(meeting))
            case .actions: ActionItemsSection(meeting: meeting)
            }
        }
        .listSectionSpacing(.compact)
        .refreshable { await load() }
    }

    private func header(_ meeting: PhoneMeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.summaryTitle ?? meeting.title).font(.title3.bold())
            Text([meeting.date.formatted(date: .abbreviated, time: .shortened), meeting.duration.map(PhoneFormat.duration)].compactMap { $0 }.joined(separator: " \u{00B7} "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(meeting.languages, id: \.self) { Chip(text: $0.uppercased() + (meeting.languageDetected ? " detected" : ""), systemImage: "globe") }
                if let engine = meeting.engines.summary { Chip(text: engine == "apple-intelligence" ? "Apple Intelligence" : engine, systemImage: "sparkles", tint: .accentColor) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SummarySection: View {
    let meeting: PhoneMeetingDetail

    var body: some View {
        if meeting.topics.isEmpty {
            Section {
                ProblemView(title: "No summary", message: meeting.summaryUnavailable ?? "This meeting has no summary yet.", systemImage: "text.badge.xmark")
                    .listRowBackground(Color.clear)
            }
        } else {
            ForEach(Array(meeting.topics.enumerated()), id: \.offset) { _, topic in
                Section(topic.title) {
                    ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                        Label { MarkdownText(point) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary) }
                            .labelStyle(TopAlignedLabel())
                    }
                }
            }
        }
    }
}

private struct TopAlignedLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.baselineOffset(3)
            configuration.title
        }
    }
}

private struct NotesSection: View {
    let meeting: PhoneMeetingDetail

    var body: some View {
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Section {
            if notes.isEmpty {
                ProblemView(title: "No notes", message: "You did not take notes in this meeting.", systemImage: "note.text").listRowBackground(Color.clear)
            } else {
                MarkdownText(notes).textSelection(.enabled)
            }
        }
    }
}

private struct ActionItemsSection: View {
    let meeting: PhoneMeetingDetail

    var body: some View {
        Section {
            if meeting.actionItems.isEmpty {
                ProblemView(title: "No action items", message: "Nothing was noted as a to-do in this meeting.", systemImage: "checklist").listRowBackground(Color.clear)
            }
            ForEach(meeting.actionItems, id: \.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle").foregroundStyle(item.done ? Color.green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        MarkdownText(item.text).strikethrough(item.done)
                        if let owner = item.owner { Chip(text: owner, systemImage: "person", tint: Color.tint(for: owner)) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.done ? "Done" : "Open")
            }
        }
    }
}

private struct TranscriptSection: View {
    @Environment(AppModel.self) private var appModel
    let meeting: PhoneMeetingDetail
    let track: AudioPlayer.Track

    var body: some View {
        let player = appModel.player
        let current = player.isCurrent(meeting.id) ? player.currentTime : nil
        Section {
            if meeting.transcript.isEmpty {
                ProblemView(title: "No transcript", message: "This meeting has not been transcribed.", systemImage: "text.alignleft").listRowBackground(Color.clear)
            }
            ForEach(Array(meeting.transcript.enumerated()), id: \.offset) { _, segment in
                let active = current.map { $0 >= segment.start && $0 < segment.end } ?? false
                Button {
                    guard meeting.audio.available else { return }
                    player.load(track, autoplay: true, at: segment.start)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if let name = segment.speakerName ?? segment.speaker {
                                Text(name).font(.caption.weight(.semibold)).foregroundStyle(Color.tint(for: segment.speaker ?? name))
                            }
                            Text(PhoneFormat.clock(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(segment.text).font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .listRowBackground(active ? Color.accentColor.opacity(0.16) : nil)
                .accessibilityHint(meeting.audio.available ? "Plays from here" : "")
            }
        }
    }
}

/// The recording of the open meeting: a play button, or the full controls while it is the one playing.
struct AudioCard: View {
    @Environment(AppModel.self) private var appModel
    let track: AudioPlayer.Track

    var body: some View {
        let player = appModel.player
        if player.isCurrent(track.meetingId) {
            PlayerControls(player: player)
        } else {
            Button { player.load(track, autoplay: true) } label: {
                Label("Play recording \u{00B7} \(PhoneFormat.clock(track.duration))", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowBackground(Color.clear)
        }
    }
}
