import AppKit
import SwiftUI

/// The editable parts of one meeting (title and notes), saved shortly after typing stops.
@MainActor
final class MeetingEditor: ObservableObject {
    @Published var title = "" { didSet { changed(\.titleChanged, oldValue != title) } }
    @Published var notes = "" { didSet { changed(\.notesChanged, oldValue != notes) } }

    private var entry: RecordingEntry?
    private weak var library: RecordingLibrary?
    private var titleChanged = false
    private var notesChanged = false
    private var loading = false
    private var pending: Task<Void, Never>?

    func open(_ entry: RecordingEntry, library: RecordingLibrary) {
        self.entry = entry
        self.library = library
        load {
            title = library.title(of: entry)
            notes = library.meeting(of: entry)?.notes ?? ""
        }
    }

    func titleDidChange(_ title: String) {
        guard !titleChanged else { return }
        load { self.title = title }
    }

    func save() {
        pending?.cancel()
        guard let entry, let library else { return }
        if titleChanged { library.setTitle(title, of: entry) }
        if notesChanged { library.setNotes(notes, of: entry) }
        titleChanged = false
        notesChanged = false
    }

    private func load(_ body: () -> Void) {
        loading = true
        body()
        loading = false
    }

    private func changed(_ flag: ReferenceWritableKeyPath<MeetingEditor, Bool>, _ didChange: Bool) {
        guard !loading, didChange else { return }
        self[keyPath: flag] = true
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
}

struct RecordingDetail: View {
    static let gutter: CGFloat = 28

    let entry: RecordingEntry
    @ObservedObject var recorder: Recorder
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var playback: AudioPlayback
    @StateObject private var editor = MeetingEditor()

    private var language: MeetingLanguage { library.language(of: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar(playback: playback, fallbackDuration: entry.duration ?? 0)
        }
        .onAppear {
            playback.load(entry.audio)
            editor.open(entry, library: library)
        }
        .onDisappear { editor.save() }
        .onChange(of: library.title(of: entry)) { editor.titleDidChange($1) }
        .onChange(of: entry.duration) { playback.load(entry.audio, force: true) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                TextField(LibraryLogic.fallbackTitle, text: $editor.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .medium))
                    .onSubmit { editor.save() }
                    .disabled(!library.canEdit)
                if !entry.inProgress, !recorder.isBusy { ContinueButton(recorder: recorder, entry: entry) }
            }
            HStack(spacing: 8) {
                Text(subtitle)
                if recorder.meeting == entry.audio { RecordingStatus(recorder: recorder) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            HStack(spacing: 2) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Button(tab.rawValue) { library.tab = tab }
                        .buttonStyle(PillButtonStyle(selected: library.tab == tab))
                }
            }
            .padding(.top, 18)
            .padding(.leading, -8)
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var subtitle: String {
        var parts = [entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                     entry.date.formatted(date: .omitted, time: .shortened)]
        if let duration = entry.duration { parts.append(LibraryLogic.minutesText(duration)) }
        parts.append(language.displayName + (library.languageDetected(of: entry) ? " (auto)" : ""))
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private var content: some View {
        switch library.tab {
        case .summary where entry.inProgress, .transcript where entry.inProgress:
            scrolling {
                Text("The transcript and summary are written after you stop recording. You can take notes meanwhile.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        case .summary:
            scrolling { SummaryView(entry: entry, language: language, processor: processor, library: library) }
        case .notes:
            TextEditor(text: $editor.notes)
                .font(.body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 690, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.gutter - 5)
                .padding(.bottom, 12)
                .disabled(!library.canEdit)
                .overlay(alignment: .topLeading) {
                    if editor.notes.isEmpty {
                        Text("Write notes\u{2026}").foregroundStyle(.tertiary).padding(.horizontal, Self.gutter).allowsHitTesting(false)
                    }
                }
        case .transcript:
            scrolling { TranscriptView(entry: entry, language: language, processor: processor, library: library, playback: playback) }
        }
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.gutter)
                .padding(.top, 8)
                .padding(.bottom, 28)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(selected ? .medium : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.08 : configuration.isPressed ? 0.04 : 0)))
            .contentShape(Capsule())
    }
}

struct SummaryView: View {
    let entry: RecordingEntry
    let language: MeetingLanguage
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var library: RecordingLibrary

    private var content: MeetingContent? { library.content(of: entry) }

    var body: some View {
        if let summary = content?.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 26) {
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        heading(language.headings.actionItems)
                        ForEach(summary.actionItems) { checklistRow($0) }
                    }
                }
                ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 7) {
                        heading(section.heading)
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in bodyLine(line) }
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            let meeting = content?.meeting
            EmptyState(entry: entry, processor: processor, notice: .make(
                status: meeting?.status, statusMessage: meeting?.statusMessage,
                hasTranscript: content?.segments.isEmpty == false,
                currentReason: Summarizer.unavailableReason(for: language)))
        }
    }

    private func heading(_ text: String) -> some View {
        Text(.inlineMarkdown(text)).font(.body.weight(.medium))
    }

    @ViewBuilder private func bodyLine(_ line: MarkdownBlock) -> some View {
        switch line {
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\u{2022}")
                Text(.inlineMarkdown(text))
            }
            .foregroundStyle(.secondary)
        case .paragraph(let text), .heading(_, let text), .task(let text, _):
            Text(.inlineMarkdown(text)).foregroundStyle(.secondary)
        }
    }

    private func checklistRow(_ item: ChecklistItem) -> some View {
        Toggle(isOn: Binding(get: { item.done }, set: { library.setChecked(item, $0) })) {
            Text(checklistText(item))
                .foregroundStyle(item.done ? .secondary : .primary)
        }
        .toggleStyle(.checkbox)
        .disabled(!library.canEdit)
    }

    private func checklistText(_ item: ChecklistItem) -> AttributedString {
        var text = AttributedString.inlineMarkdown(item.task)
        if let owner = item.owner {
            var suffix = AttributedString(" \u{00B7} \(owner)")
            suffix.foregroundColor = .secondary
            text += suffix
        }
        if item.done { text.strikethroughStyle = .single }
        return text
    }
}

struct TranscriptView: View {
    let entry: RecordingEntry
    let language: MeetingLanguage
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var library: RecordingLibrary
    let playback: AudioPlayback

    var body: some View {
        let content = library.content(of: entry)
        let rows = SpeakerLogic.rows(content?.segments ?? [])
        if rows.isEmpty {
            EmptyState(entry: entry, processor: processor, notice: SummaryNotice(
                title: "No transcript yet", message: "Transcribe this recording on this Mac. Nothing leaves your computer."))
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if row.showsSpeaker, let speaker = row.paragraph.speaker {
                                SpeakerLabel(speaker: speaker, name: content?.names[speaker], enabled: library.canEdit) {
                                    library.renameSpeaker(speaker, of: entry, to: $0)
                                }
                            }
                            Button(LibraryLogic.durationText(row.paragraph.start)) { playback.play(from: row.paragraph.start) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .help("Play from here")
                        }
                        .font(.caption.monospacedDigit())
                        Text(row.paragraph.text)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// A speaker's name in the transcript; clicking it renames the speaker for this meeting.
private struct SpeakerLabel: View {
    let speaker: Speaker
    let name: String?
    let enabled: Bool
    let rename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button(name ?? speaker.name(in: .english)) {
            draft = name ?? ""
            editing = true
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .help("Rename this speaker")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name \(speaker.name(in: .english))").font(.headline)
                TextField(speaker.name(in: .english), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(save)
                Text(speaker == .you || speaker == .others ? "Used in this meeting\u{2019}s transcript and summary."
                     : "Also remembers the voice, so later meetings recognise it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 248)
        }
    }

    private func save() {
        editing = false
        if draft != (name ?? "") { rename(draft) }
    }
}

struct EmptyState: View {
    let entry: RecordingEntry
    @ObservedObject var processor: MeetingProcessor
    let notice: SummaryNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(notice.title).font(.body.weight(.medium))
            Text(notice.message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let details = notice.details {
                Text(details)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if processor.processing == entry.audio {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(processor.status ?? "Working\u{2026}").foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } else if notice.showsSettings || notice.canSummarise {
                HStack(spacing: 8) {
                    if let settings = notice.settings { Button(settings.title) { Permissions.open(settings) } }
                    if notice.canSummarise { Button("Summarise") { processor.summarise(entry.audio) } }
                }
                .padding(.top, 6)
            }
        }
        .padding(.top, 12)
    }
}

struct PlayerBar: View {
    @ObservedObject var playback: AudioPlayback
    let fallbackDuration: TimeInterval

    private var total: TimeInterval { playback.duration > 0 ? playback.duration : fallbackDuration }

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(playback.duration == 0)
            Text(LibraryLogic.durationText(playback.position))
            ProgressTrack(value: total > 0 ? playback.position / total : 0) { playback.seek(to: $0 * total) }
            Text(LibraryLogic.durationText(total))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, RecordingDetail.gutter)
        .frame(height: 40)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }
}

struct ProgressTrack: View {
    let value: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.accentColor).frame(width: geometry.size.width * min(max(value, 0), 1))
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                seek(min(max(drag.location.x / max(geometry.size.width, 1), 0), 1))
            })
        }
        .frame(height: 16)
    }
}

extension AttributedString {
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
