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
            notes = (try? String(contentsOf: entry.notes, encoding: .utf8)) ?? ""
        }
    }

    func titleDidChangeOnDisk(_ title: String) {
        guard !titleChanged else { return }
        load { self.title = title }
    }

    func save() {
        pending?.cancel()
        guard let entry, let library else { return }
        if titleChanged {
            let aiTitle = library.summary(of: entry)?.title
            library.updateMeta(of: entry) { $0.title = LibraryLogic.titleOverride(title, aiTitle: aiTitle) }
        }
        if notesChanged {
            if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(at: entry.notes)
            } else {
                try? notes.write(to: entry.notes, atomically: true, encoding: .utf8)
            }
        }
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
        .onChange(of: library.title(of: entry)) { editor.titleDidChangeOnDisk($0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(LibraryLogic.fallbackTitle, text: $editor.title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .medium))
                .onSubmit { editor.save() }
            Text(subtitle)
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
        parts.append(language.displayName)
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private var content: some View {
        switch library.tab {
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
                .overlay(alignment: .topLeading) {
                    if editor.notes.isEmpty {
                        Text("Write notes\u{2026}").foregroundStyle(.tertiary).padding(.horizontal, Self.gutter).allowsHitTesting(false)
                    }
                }
        case .transcript:
            scrolling { TranscriptView(entry: entry, processor: processor, library: library, playback: playback) }
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

    var body: some View {
        if let summary = library.summary(of: entry), summary.unavailable == nil, !summary.isEmpty {
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
            let unavailable = library.summary(of: entry)?.unavailable
            EmptyState(entry: entry, processor: processor, title: unavailable == nil ? "No summary yet" : "Summary unavailable",
                       message: unavailable ?? emptyMessage)
        }
    }

    private var emptyMessage: String {
        entry.hasTranscript
            ? "There is a transcript but no summary. Summarise it on this Mac with Apple Intelligence."
            : "Transcribe and summarise this recording on this Mac. Nothing leaves your computer."
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
        Toggle(isOn: Binding(get: { item.done }, set: { done in
            library.updateMeta(of: entry) { $0.checked[item.key] = done }
        })) {
            Text(checklistText(item))
                .foregroundStyle(item.done ? .secondary : .primary)
        }
        .toggleStyle(.checkbox)
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
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var library: RecordingLibrary
    let playback: AudioPlayback

    var body: some View {
        let paragraphs = LibraryLogic.paragraphs(LibraryLogic.transcriptSegments(library.text(of: entry.transcript) ?? ""))
        if paragraphs.isEmpty {
            EmptyState(entry: entry, processor: processor, title: "No transcript yet",
                       message: "Transcribe this recording on this Mac. Nothing leaves your computer.")
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    VStack(alignment: .leading, spacing: 3) {
                        Button(LibraryLogic.durationText(paragraph.start)) { playback.play(from: paragraph.start) }
                            .buttonStyle(.plain)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                            .help("Play from here")
                        Text(paragraph.text)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct EmptyState: View {
    let entry: RecordingEntry
    @ObservedObject var processor: MeetingProcessor
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.body.weight(.medium))
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if processor.processing == entry.audio {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(processor.status ?? "Working\u{2026}").foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } else {
                Button("Summarise") { processor.process(entry.audio) }
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
