import SwiftUI

/// The Meetings section: the meeting list beside the selected meeting. Below the compact width the list and the meeting take
/// turns, with a back button, as the GitHub page does.
struct MeetingsView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var library: RecordingLibrary
    let playback: AudioPlayback
    let newMeeting: () -> Void
    @State private var showsDetail = false

    private static let listWidth = 260.0

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < GitHubLayout.compactBelow {
                if showsDetail, let entry = library.selected {
                    VStack(spacing: 0) {
                        HStack {
                            Button { showsDetail = false } label: { Label("Meetings", systemImage: "chevron.left") }
                                .buttonStyle(.borderless)
                            Spacer()
                        }
                        .padding(8)
                        detail(entry)
                    }
                } else {
                    list
                }
            } else {
                HStack(spacing: 0) {
                    list.frame(width: Self.listWidth)
                    Divider()
                    if let entry = library.selected {
                        detail(entry)
                    } else {
                        Text(library.recordings.isEmpty ? "No recordings yet" : "Select a meeting")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onChange(of: library.selection) { showsDetail = library.selection != nil }
    }

    private func detail(_ entry: RecordingEntry) -> some View {
        RecordingDetail(entry: entry, recorder: recorder, processor: processor, library: library, playback: playback)
            .id(entry.id)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SearchField(text: $library.query)
                Button(action: newMeeting) {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(recorder.isBusy ? "A meeting is being recorded; this shows it" : "New meeting (\u{2318}N)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(LibraryLogic.grouped(library.visibleRecordings, now: Date()), id: \.group) { group, entries in
                        Text(group.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(entries) { row($0, group: group) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .onMoveCommand { direction in
                if direction == .up { library.moveSelection(by: -1) }
                if direction == .down { library.moveSelection(by: 1) }
            }
        }
    }

    private func row(_ entry: RecordingEntry, group: DateGroup) -> some View {
        Button { library.select(entry) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(library.title(of: entry))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if recorder.meeting == entry.audio {
                        RecordingStatus(recorder: recorder)
                    } else {
                        Text(([dateText(entry.date, group: group)] + [entry.duration.map(LibraryLogic.minutesText)].compactMap { $0 })
                            .joined(separator: " \u{00B7} "))
                    }
                    if processor.processing == entry.audio { ProgressView().controlSize(.mini) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(library.selected?.id == entry.id ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dateText(_ date: Date, group: DateGroup) -> String {
        switch group {
        case .today, .yesterday: return date.formatted(date: .omitted, time: .shortened)
        case .thisWeek: return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .earlier: return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
    }
}
