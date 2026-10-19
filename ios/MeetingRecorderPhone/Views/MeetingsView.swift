import SwiftUI

struct MeetingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Router.self) private var router
    @State private var model: MeetingsModel?
    @State private var query = ""

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.meetingPath) {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            .navigationTitle("Meetings")
            .navigationDestination(for: MeetingRoute.self) { MeetingDetailView(route: $0) }
        }
        .task {
            let model = model ?? MeetingsModel(model: appModel)
            self.model = model
            await model.refresh()
        }
    }

    @ViewBuilder
    private func content(_ model: MeetingsModel) -> some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let shown = searching ? model.results ?? [] : model.items
        List {
            if !searching || model.searchIsLocal {
                SyncBanner(error: searching ? model.searchError : model.first.error, syncedAt: model.first.syncedAt) { Task { await model.refresh() } }
                    .listRowBackground(Color.orange.opacity(0.12))
            }
            if searching {
                Section {
                    ForEach(shown, id: \.id) { MeetingRow(meeting: $0) }
                }
            } else {
                ForEach(PhoneFormat.groupByDay(shown, date: \.date), id: \.day) { group in
                    Section(group.title) {
                        ForEach(group.items, id: \.id) { MeetingRow(meeting: $0) }
                    }
                }
                if model.nextBefore != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .onAppear { Task { await model.loadMore() } }
                        .listRowBackground(Color.clear)
                }
            }
        }
        .overlay {
            if searching, shown.isEmpty, model.results != nil {
                ContentUnavailableView.search(text: query)
            } else if !searching, shown.isEmpty {
                emptyState(model)
            }
        }
        .searchable(text: $query, prompt: "Search titles, transcripts and summaries")
        .task(id: query) {
            guard searching else { await model.search(""); return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.search(query)
        }
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private func emptyState(_ model: MeetingsModel) -> some View {
        if model.first.isLoading {
            ProgressView()
        } else if let error = model.first.error {
            ProblemView(title: error.problemTitle, message: error.hint, actionTitle: "Try again") { Task { await model.refresh() } }
        } else {
            ProblemView(title: "No meetings yet", message: "Meetings recorded on your Mac show up here.", systemImage: "waveform")
        }
    }
}

struct MeetingRow: View {
    let meeting: PhoneMeetingSummary

    var body: some View {
        NavigationLink(value: MeetingRoute(id: meeting.id, title: meeting.title)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meeting.title).font(.headline).lineLimit(2)
                    Spacer(minLength: 4)
                    if meeting.hasSummary {
                        Image(systemName: "sparkles").foregroundStyle(.tint).imageScale(.small).accessibilityLabel("Has a summary")
                    }
                }
                HStack(spacing: 6) {
                    Text(meeting.date.timeText)
                    if let duration = meeting.duration { Text("\u{00B7} " + PhoneFormat.duration(duration)) }
                    if let language = meeting.language { Chip(text: language.uppercased(), tint: .secondary) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let snippet = meeting.snippet, !snippet.isEmpty {
                    Text(MarkdownText.attributed(snippet)).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                if !meeting.speakers.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(PhoneFormat.shortSpeakers(meeting.speakers), id: \.self) { Chip(text: $0, tint: Color.tint(for: $0)) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .combine)
    }
}
