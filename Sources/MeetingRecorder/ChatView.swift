import AppKit
import SwiftUI

@MainActor
final class ChatWindow {
    static let shared = ChatWindow()

    private(set) var model: ChatModel?
    private var window: AppWindow?

    func configure(store: MeetingStore, openMeeting: @escaping (Int64, TimeInterval?) -> Void) {
        let model = ChatModel(store: store)
        model.openMeeting = openMeeting
        self.model = model
        window = AppWindow { Self.makeWindow(ChatView(model: model)) }
    }

    /// Opens the window; `scope` starts an empty chat about it and `chat` shows a stored one.
    func show(scope: ChatScope? = nil, chat: Chat? = nil) {
        guard let model else { return }
        model.start()
        if let chat { model.open(chat) } else if let scope { model.newChat(scope: scope) }
        window?.show()
    }

    static func makeWindow(_ view: ChatView) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: controller)
        window.title = "Chat"
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 940, height: 660))
        return window
    }
}

struct ChatView: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        NavigationSplitView {
            ChatSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            ChatDetail(model: model)
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refresh() }
    }
}

private struct ChatSidebar: View {
    @ObservedObject var model: ChatModel
    @State private var renaming: Chat?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            Button { model.newChat() } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.current == nil ? Color.primary.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n")
            .padding(.horizontal, 8)
            .help("Start a new chat (\u{2318}N)")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.groups, id: \.key) { group in
                        Text(group.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(group.chats) { row($0) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .padding(.top, 8)
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newName)
            Button("Rename") { renaming.map { model.rename($0, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ chat: Chat) -> some View {
        Button { model.open(chat) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).lineLimit(1).foregroundStyle(.primary)
                Text(chat.updated.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.current?.id == chat.id ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename\u{2026}") {
                newName = chat.title
                renaming = chat
            }
            Button("Delete", role: .destructive) { model.delete(chat) }
        }
    }
}

struct ChatDetail: View {
    @ObservedObject var model: ChatModel
    @State private var height: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = model.unavailable {
                ScrollView { ChatUnavailableNotice(notice: ChatLogic.unavailableNotice(notice)) }
            } else {
                conversation
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.openURL, OpenURLAction { model.handle($0) })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.title).font(.system(size: 20, weight: .medium)).lineLimit(1)
            Spacer()
            if !model.scope.isGeneral { ScopeChip(model: model) }
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var conversation: some View {
        if model.messages.isEmpty, !model.isResponding {
            ScrollView { ChatEmptyState(model: model) }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            MessageRow(message: message, sources: model.sources(before: index), model: model)
                        }
                        if model.isResponding { PendingAnswer(model: model) }
                        if let failure = model.failure {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, RecordingDetail.gutter)
                    .padding(.bottom, 12)
                }
                .onChange(of: model.messages.count) { proxy.scrollTo("end") }
                .onChange(of: model.streaming) { proxy.scrollTo("end") }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ChatComposer(text: $model.draft, height: $height, placeholder: model.scope.isGeneral
                         ? "Ask about your meetings and work" : "Ask about \(model.chipTitle)") { model.send(model.draft) }
                .frame(height: height)
            Button {
                if model.isResponding { model.stop() } else { model.send(model.draft) }
            } label: {
                Image(systemName: model.isResponding ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(model.isResponding || !model.draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.accentColor : .secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(model.isResponding ? "Stop" : "Send (Return)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, RecordingDetail.gutter - 14)
        .padding(.bottom, 16)
    }
}

private struct ScopeChip: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let id = model.scope.meetingID { model.openMeeting(id, nil) }
            } label: {
                Label(model.chipTitle, systemImage: icon).lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(model.scope.meetingID == nil)
            Button { model.removeScope() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Stop limiting this chat to \(model.chipTitle)")
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }

    private var icon: String {
        switch model.scope.kind {
        case .meeting: return "waveform"
        case .notes: return "note.text"
        case .activityBlock, .day, .week: return "clock"
        case .general: return "sparkles"
        }
    }
}

private struct ChatEmptyState: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.scope.isGeneral ? "Ask about your meetings and work" : "Ask about \(model.chipTitle)")
                .font(.system(size: 17, weight: .medium))
            Text("Answers come from your meetings and activity on this Mac, written by Apple Intelligence on the device. Nothing leaves your computer.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 8) {
                ForEach(model.suggestions, id: \.label) { suggestion in
                    Button(suggestion.label) { model.send(suggestion.prompt) }
                        .buttonStyle(SuggestionStyle())
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.top, 40)
    }
}

private struct SuggestionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07)))
            .contentShape(Capsule())
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let sources: [Int64]
    @ObservedObject var model: ChatModel
    @State private var hovering = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.07)))
                    .overlay(alignment: .bottomLeading) { copyButton.offset(x: -26) }
            }
            .onHover { hovering = $0 }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                AnswerText(text: message.text, linkifyTimes: model.scope.isAboutMeeting)
                HStack(spacing: 8) {
                    ForEach(sources, id: \.self) { id in
                        Button { model.openMeeting(id, nil) } label: {
                            Label(model.meetingTitles[id] ?? "Meeting", systemImage: "doc.text").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Open this meeting")
                    }
                    copyButton
                }
            }
            .onHover { hovering = $0 }
        case .tool:
            ToolNoteRow(note: message.toolNote ?? "", model: model)
        }
    }

    private var copyButton: some View {
        Button { model.copy(message.text) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("Copy")
    }
}

private struct ToolNoteRow: View {
    let note: String
    @ObservedObject var model: ChatModel
    @State private var expanded = false

    var body: some View {
        let summary = ChatLogic.noteSummary(note)
        let details = ChatLogic.noteDetails(note)
        let fresh = summary == ChatModel.freshContextNote
        VStack(alignment: .leading, spacing: 3) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: fresh ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                    Text(summary).lineLimit(1)
                    if !details.isEmpty { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)) }
                }
            }
            .buttonStyle(.plain)
            .disabled(details.isEmpty)
            if expanded {
                ForEach(details, id: \.self) { line in
                    if let id = ChatLogic.meetingIDs(inNote: line).first {
                        Button { model.openMeeting(id, nil) } label: { Text(line).lineLimit(2).multilineTextAlignment(.leading) }
                            .buttonStyle(.plain)
                            .help("Open this meeting")
                    } else {
                        Text(line).lineLimit(2)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct PendingAnswer: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        if let text = model.streaming, !text.isEmpty {
            AnswerText(text: text, linkifyTimes: model.scope.isAboutMeeting)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.messages.last?.role == .tool ? "Reading\u{2026}" : "Thinking\u{2026}").foregroundStyle(.secondary)
            }
        }
    }
}

/// An answer with its Markdown blocks laid out and, in a chat about one meeting, its times as links that open the recording.
struct AnswerText: View {
    let text: String
    var linkifyTimes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ChatLogic.blocks(linkifyTimes ? ChatLogic.linkifiedTimestamps(text) : text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(AttributedString.inlineMarkdown(text)).font(.headline).textSelection(.enabled)
                case .bullet(let level, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}").foregroundStyle(.secondary)
                        Text(AttributedString.inlineMarkdown(text)).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(level) * 18)
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(number + ".").foregroundStyle(.secondary).monospacedDigit()
                        Text(AttributedString.inlineMarkdown(text)).textSelection(.enabled)
                    }
                case .paragraph(let text):
                    Text(AttributedString.inlineMarkdown(text)).lineSpacing(3).textSelection(.enabled)
                case .task(let level, let done, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? Color.accentColor : .secondary)
                        Text(AttributedString.inlineMarkdown(text)).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(level) * 18)
                case .code(let text):
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                case .table(let rows):
                    Text(GitHubLogic.alignedTable(rows))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                case .image(let alt, let url):
                    Button { URL(string: url).map { NSWorkspace.shared.open($0) } } label: {
                        Label("Image: \(alt.isEmpty ? "untitled" : alt)", systemImage: "photo")
                    }
                    .buttonStyle(.link)
                    .help("Opens in the browser; GitHub images need you to be signed in there")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatUnavailableNotice: View {
    let notice: SummaryNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(notice.title).font(.body.weight(.medium))
            Text(notice.message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let settings = notice.settings {
                Button(settings.title) { Permissions.open(settings) }.padding(.top, 6)
            }
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
