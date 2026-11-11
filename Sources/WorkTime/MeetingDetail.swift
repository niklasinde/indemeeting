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
    @ObservedObject private var inCall = InCallHelp.shared

    private var language: MeetingLanguage { library.language(of: entry) }
    private var audioUnavailable: String? { library.audioUnavailable(entry) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if recorder.meeting == entry.audio && inCall.meeting == entry.audio {
                Divider()
                InCallSidebar()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar(playback: playback, fallbackDuration: entry.duration ?? 0, unavailable: audioUnavailable)
        }
        .onAppear {
            playback.load(audioUnavailable == nil ? entry.audio : nil)
            editor.open(entry, library: library)
        }
        .onDisappear { editor.save() }
        .onChange(of: library.title(of: entry)) { editor.titleDidChange($1) }
        .onChange(of: entry.duration) { playback.load(entry.audio, force: true) }
        .onChange(of: audioUnavailable) { playback.load($1 == nil ? entry.audio : nil, force: true) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                TextField(LibraryLogic.fallbackTitle, text: $editor.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .medium))
                    .onSubmit { editor.save() }
                    .disabled(!library.canEdit)
                if !entry.inProgress, let meeting = library.meeting(of: entry) {
                    AskButton(meeting: meeting, title: library.title(of: entry), notes: library.tab == .notes)
                }
                if !entry.inProgress {
                    RetranscribeButton(entry: entry, recorder: recorder, processor: processor, unavailable: audioUnavailable)
                }
                if !entry.inProgress, !recorder.isBusy, audioUnavailable == nil { ContinueButton(recorder: recorder, entry: entry) }
            }
            HStack(spacing: 8) {
                Text(subtitle)
                if let source = library.sourceLabel(of: entry) {
                    SourceLabel(text: source, icon: library.sourceIcon(of: entry))
                }
                if recorder.meeting == entry.audio { RecordingStatus(recorder: recorder) }
                if processor.processing == entry.audio {
                    ProgressView().controlSize(.mini)
                    Text(processor.status ?? "Working\u{2026}").lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            let meeting = library.meeting(of: entry)
            let info = meeting.flatMap { meeting in
                let parts = [LibraryLogic.transcriptionInfo(at: meeting.transcribedAt, engine: meeting.transcriptEngine),
                             LibraryLogic.summaryInfo(engine: meeting.summaryEngine)].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
            }
            if info != nil || !library.versions.isEmpty || meeting?.transcribed == true || meeting?.audioExpiresAt != nil {
                HStack(spacing: 8) {
                    if let info { Text(info).foregroundStyle(.tertiary) }
                    if let meeting, !entry.inProgress {
                        AudioStatus(entry: entry, meeting: meeting, recorder: recorder, processor: processor, library: library)
                    }
                    if !library.versions.isEmpty { EarlierVersionsMenu(library: library) }
                }
                .font(.caption)
                .padding(.top, 2)
            }
            MeetingMentionsLine(fileName: entry.fileName).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            if let version = library.viewedVersion {
                EarlierVersionBar(entry: entry, version: version, library: library, processor: processor)
            }
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
        case .transcript where recorder.meeting == entry.audio && entry.inProgress:
            LiveTranscriptTab(recorder: recorder, live: recorder.live) { EmptyView() } fallback: { note in
                scrolling { recordingNote(note) }
            }
        case .transcript where recorder.meeting == entry.audio:
            LiveTranscriptTab(recorder: recorder, live: recorder.live) {
                transcript
                Divider().padding(.vertical, 8)
            } fallback: { _ in
                scrolling { transcript }
            }
        case .summary where entry.inProgress, .transcript where entry.inProgress:
            scrolling { recordingNote(nil) }
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
            scrolling(maxWidth: library.comparing ? 1200 : 680) { transcript }
        }
    }

    private var transcript: some View {
        TranscriptView(entry: entry, language: language, processor: processor, library: library, playback: playback,
                       audioUnavailable: audioUnavailable)
    }

    private func recordingNote(_ note: String?) -> some View {
        Text(note ?? "The transcript and summary are written after you stop recording. You can take notes meanwhile.")
            .foregroundStyle(.secondary)
            .padding(.top, 12)
    }

    private func scrolling<Content: View>(maxWidth: CGFloat = 680, @ViewBuilder _ content: () -> Content) -> some View {
        let content = content()
        return ScrollViewReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
            }
            .task(id: library.seekTarget) { await scroll(proxy) }
        }
    }

    /// Scrolls the transcript to the paragraph holding the moment a chat answer pointed at.
    private func scroll(_ proxy: ScrollViewProxy) async {
        guard let target = library.seekTarget, library.tab == .transcript else { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let rows = SpeakerLogic.rows(library.content(of: entry)?.segments ?? [])
        guard let row = rows.last(where: { $0.paragraph.start <= target }) ?? rows.first else { return }
        withAnimation { proxy.scrollTo(row.paragraph.start, anchor: .top) }
        library.seekTarget = nil
    }
}

/// The live lines of the meeting being recorded, below what `stored` shows; `fallback` while they are off or cannot be heard.
private struct LiveTranscriptTab<Stored: View, Fallback: View>: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var live: LiveTranscription
    @ViewBuilder let stored: () -> Stored
    @ViewBuilder let fallback: (String?) -> Fallback
    @AppStorage(LiveTranscriptLogic.enabledKey) private var enabled = true

    var body: some View {
        if LiveTranscriptLogic.showsInline(enabled: enabled, note: live.note) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Live preview \u{00B7} the final transcript is written when you stop")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, RecordingDetail.gutter)
                    .padding(.bottom, 4)
                LiveLines(live: live, placeholder: LiveTranscriptLogic.placeholder(
                              enabled: enabled, note: live.note, paused: recorder.isPaused, recording: recorder.isRecording),
                          inset: EdgeInsets(top: 8, leading: RecordingDetail.gutter, bottom: 28, trailing: RecordingDetail.gutter),
                          maxWidth: 680, leading: stored)
            }
        } else {
            fallback(live.note)
        }
    }
}

/// Transcribes, recognises speakers and summarises the stored audio again with the current transcription settings.
private struct RetranscribeButton: View {
    let entry: RecordingEntry
    @ObservedObject var recorder: Recorder
    @ObservedObject var processor: MeetingProcessor
    let unavailable: String?

    var body: some View {
        Button { processor.process(entry.audio) } label: {
            Label("Re-transcribe", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
        }
        .disabled(processor.processing == entry.audio || recorder.meeting == entry.audio || unavailable != nil)
        .help(unavailable.map { "Cannot re-transcribe. \($0)." }
              ?? "Transcribe, recognise speakers and summarise again with the current transcription settings")
    }
}

/// Whether the meeting's audio is still on this Mac, with "Delete audio now" while it is.
private struct AudioStatus: View {
    let entry: RecordingEntry
    let meeting: Meeting
    @ObservedObject var recorder: Recorder
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var library: RecordingLibrary
    @State private var confirming = false

    var body: some View {
        switch AudioRetention.state(of: meeting, now: Date()) {
        case .deleted(let date):
            Text(AudioRetention.deletedText(date)).foregroundStyle(.tertiary)
        case .waiting(let reason):
            Text(reason).foregroundStyle(.tertiary)
                .help("The audio is deleted once the transcript and summary are saved; until then it is kept so processing can be retried")
        case .kept, .due:
            if meeting.transcribed, library.audioUnavailable(entry) == nil {
                Button("Delete audio now") { confirming = true }
                    .buttonStyle(.link)
                    .disabled(processor.processing == entry.audio || recorder.meeting == entry.audio)
                    .help("Remove this recording\u{2019}s audio from this Mac; the transcript, summary and notes stay")
                    .confirmationDialog("Delete this meeting\u{2019}s audio?", isPresented: $confirming) {
                        Button("Delete Audio", role: .destructive) { library.deleteAudio(entry) }
                    } message: {
                        Text("The audio is removed for good, not moved to the Trash. The transcript, summary and notes stay, "
                             + "but the meeting can no longer be played or transcribed again.")
                    }
            }
        }
    }
}

/// Lists the transcripts a re-transcription replaced; picking one shows it read-only.
private struct EarlierVersionsMenu: View {
    @ObservedObject var library: RecordingLibrary

    var body: some View {
        Menu("Earlier versions") {
            ForEach(library.versions) { version in
                Button(TranscriptVersionLogic.label(version)) { library.showVersion(version) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Transcripts and summaries replaced by re-transcribing, and the transcript written live while recording")
    }
}

private struct EarlierVersionBar: View {
    let entry: RecordingEntry
    let version: TranscriptVersionInfo
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var processor: MeetingProcessor
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Viewing earlier version \u{00B7} " + TranscriptVersionLogic.label(version)).lineLimit(1)
            Spacer()
            if library.canCompare {
                Toggle("Compare with current", isOn: Binding(get: { library.comparing }, set: { compare in
                    library.comparing = compare
                    if compare { library.tab = .transcript }
                }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Show this version next to the current transcript, lined up by time")
            }
            Button("Delete", role: .destructive) { confirmingDelete = true }
            Button("Restore") { library.restore(version, of: entry) }
                .disabled(processor.processing == entry.audio)
                .help("Make this the current transcript and summary; the current ones are kept as an earlier version")
            Button("Back") { library.showVersion(nil) }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
        .padding(.top, 10)
        .confirmationDialog("Delete this earlier version?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { library.delete(version) }
        } message: {
            Text("Its transcript and summary are removed. The current ones are not changed.")
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
    let audioUnavailable: String?

    var body: some View {
        let content = library.content(of: entry)
        let rows = SpeakerLogic.rows(content?.segments ?? [])
        if let content, let current = library.comparedContent(of: entry) {
            ComparedTranscript(version: content, current: current, playback: playback, audioUnavailable: audioUnavailable)
        } else if rows.isEmpty {
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
                            TimestampButton(start: row.paragraph.start, playback: playback, audioUnavailable: audioUnavailable)
                            PartEngine(engine: row.paragraph.engine)
                        }
                        .font(.caption.monospacedDigit())
                        Text(row.paragraph.text)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .id(row.paragraph.start)
                }
            }
        }
    }
}

private struct TimestampButton: View {
    let start: TimeInterval
    let playback: AudioPlayback
    let audioUnavailable: String?

    var body: some View {
        Button(LibraryLogic.durationText(start)) { playback.play(from: start) }
            .buttonStyle(.plain)
            .foregroundStyle(audioUnavailable == nil ? Color.accentColor : .secondary)
            .disabled(audioUnavailable != nil)
            .help(audioUnavailable ?? "Play from here")
    }
}

/// Names the engine of a part of a live transcript that another engine wrote than the rest.
private struct PartEngine: View {
    let engine: String?

    var body: some View {
        if let engine { Text(TranscriptionEngine.displayName(stored: engine)).foregroundStyle(.tertiary) }
    }
}

/// An earlier version next to the current transcript, paragraphs that were said at the same time on one row.
private struct ComparedTranscript: View {
    let version: MeetingContent
    let current: MeetingContent
    let playback: AudioPlayback
    let audioUnavailable: String?

    var body: some View {
        let rows = TranscriptVersionLogic.sideBySide(version: SpeakerLogic.rows(version.segments).map(\.paragraph),
                                                     current: SpeakerLogic.rows(current.segments).map(\.paragraph))
        Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 18) {
            GridRow {
                Text("This version")
                Text("Current")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    cell(row.version, names: version.names)
                    cell(row.current, names: current.names)
                }
            }
        }
    }

    @ViewBuilder private func cell(_ paragraph: TranscriptSegment?, names: SpeakerNames) -> some View {
        if let paragraph {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let speaker = paragraph.speaker {
                        Text(names.name(of: speaker, in: .english)).foregroundStyle(.secondary)
                    }
                    TimestampButton(start: paragraph.start, playback: playback, audioUnavailable: audioUnavailable)
                    PartEngine(engine: paragraph.engine)
                }
                .font(.caption.monospacedDigit())
                Text(paragraph.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
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
    var unavailable: String?

    private var total: TimeInterval { playback.duration > 0 ? playback.duration : fallbackDuration }

    var body: some View {
        HStack(spacing: 12) {
            if let unavailable {
                Image(systemName: "speaker.slash")
                Text(unavailable)
                Spacer()
                Text(LibraryLogic.durationText(fallbackDuration))
            } else {
                controls
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, RecordingDetail.gutter)
        .frame(height: 40)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var controls: some View {
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
