import AppKit
import SwiftUI

extension SessionState {
    var color: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .secondary.opacity(0.6)
        case .ended: return .red
        }
    }
}

#if canImport(SwiftTerm)

/// The Sessions section: the list of every Claude session on the left, the selected one's chat or terminal on the right.
struct SessionsView: View {
    @ObservedObject private var model = SessionsModel.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = model.rows(now: context.date)
            HStack(spacing: 0) {
                SessionColumn(rows: rows, now: context.date, model: model)
                    .frame(width: 280)
                Divider()
                if let row = rows.first(where: { $0.id == model.selection }) {
                    SessionPage(row: row, now: context.date, model: model, feed: model.feed(for: row.id))
                        .id(row.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Select a session", systemImage: "terminal",
                                           description: Text("Its chat and its terminal open here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { model.tick() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.tick() }
    }
}

private struct SessionColumn: View {
    let rows: [SessionRow]
    let now: Date
    @ObservedObject var model: SessionsModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search sessions", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            if rows.isEmpty {
                ContentUnavailableView("No Claude sessions yet", systemImage: "terminal",
                                       description: Text("Start one from a pull request with Open in Claude > In this app."))
                    .frame(maxHeight: .infinity)
            } else {
                let sections = SessionList.grouped(SessionList.matching(rows, query: model.query))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.group.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 2)
                                ForEach(section.rows) { row in
                                    Button { model.selection = row.id } label: {
                                        SessionRowLabel(row: row, now: now)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(RoundedRectangle(cornerRadius: 6)
                                                .fill(model.selection == row.id ? Color.primary.opacity(0.1) : .clear))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .overlay(alignment: .top) {
                        if sections.isEmpty { Text("No session matches").foregroundStyle(.secondary).padding(.top, 20) }
                    }
                }
            }
        }
    }
}

private struct SessionRowLabel: View {
    let row: SessionRow
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(row.state.color).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                Text([row.prLabel ?? "No PR", GitHubLogic.updatedText(row.updated, now: now)].joined(separator: " \u{00B7} "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One session: its header, then its chat or its terminal, then what can be sent to it.
private struct SessionPage: View {
    let row: SessionRow
    let now: Date
    @ObservedObject var model: SessionsModel
    @ObservedObject var feed: TranscriptFeed
    @State private var draft = ""
    @State private var height: CGFloat = 26
    @State private var following = true

    private var live: TerminalSession? { EmbeddedTerminalModel.shared.session(for: row.id) }
    private var isRunning: Bool { live?.isRunning ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let live, model.tab == .terminal {
                TerminalHost(session: live).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                composer.padding(12)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(row.state.color).frame(width: 8, height: 8)
                Text(row.state.title).font(.callout).foregroundStyle(.secondary)
                prChip
                Spacer(minLength: 8)
                if live != nil {
                    Picker("View", selection: $model.tab) {
                        Text("Chat").tag(SessionsModel.Tab.chat)
                        Text("Terminal").tag(SessionsModel.Tab.terminal)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                menu
            }
            Text(row.title).font(.title3.weight(.medium)).lineLimit(1).textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var prChip: some View {
        Button { model.openPullRequest(row.url) } label: {
            Label(row.prLabel ?? "No PR", systemImage: "arrow.triangle.branch")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(row.prLabel == nil)
        .help(row.prLabel == nil ? "This session is not on a pull request" : "Show this pull request in GitHub")
    }

    private var menu: some View {
        Menu {
            Button("Copy transcript") { GitHubModel.copy(model.transcriptText(for: row)) }
            if live != nil {
                Button("Stop") { model.stop(row.id) }.disabled(!isRunning)
                Button("Restart") { model.restart(row.id) }
            }
            Divider()
            Button("Larger Text") { _ = EmbeddedTerminal.steppedFontSize(1) }
            Button("Smaller Text") { _ = EmbeddedTerminal.steppedFontSize(-1) }
            Button("Reset Text Size") { _ = EmbeddedTerminal.steppedFontSize(0) }
            Divider()
            Button("Forget Session", role: .destructive) { model.forget(row.url) }
                .disabled(isRunning || row.kind == .review)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Session actions")
    }

    // MARK: Chat

    private static let bottom = "bottom"

    private var transcript: some View {
        let entries = model.entries(for: row)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty && feed.pending.isEmpty { emptyNote }
                    ForEach(entries) { entry in TranscriptLine(entry: entry) }
                    ForEach(feed.pending) { message in PendingLine(text: message.text) }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, atBottom in
                following = atBottom
            }
            .onChange(of: entries.count) { if following { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onChange(of: feed.pending.count) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !following {
                    Button {
                        following = true
                        proxy.scrollTo(Self.bottom, anchor: .bottom)
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    @ViewBuilder private var emptyNote: some View {
        if row.kind == .review {
            EmptyNote(text: "A review run keeps its answer, not a transcript.")
        } else if feed.url == nil {
            EmptyNote(text: isRunning ? "Claude has not written its transcript yet." : "The transcript is no longer on this Mac.")
        } else {
            EmptyNote(text: "No messages yet.")
        }
    }

    // MARK: Composer

    @ViewBuilder private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.state == .waiting, let question = model.question(for: row.id) {
                WaitingCard(question: question,
                            yes: { model.answer(row.id, yes: true) },
                            no: { model.answer(row.id, yes: false) })
            }
            if isRunning {
                HStack(alignment: .bottom, spacing: 8) {
                    ChatComposer(text: $draft, height: $height, placeholder: "Message Claude") { send() }
                        .frame(height: height)
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send (Return)")
                }
            } else if row.kind == .review {
                EmptyNote(text: "Read only.")
            } else if row.sessionID != nil {
                HStack(spacing: 10) {
                    Button("Resume session") { model.resume(row.url) }
                        .buttonStyle(.borderedProminent)
                    Text("Read only until it is resumed.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                EmptyNote(text: "Read only.")
            }
        }
    }

    private func send() {
        if model.send(draft, to: row.id) {
            draft = ""
            following = true
        }
    }
}

private struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WaitingCard: View {
    let question: String
    let yes: () -> Void
    let no: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Claude is waiting for you", systemImage: "questionmark.bubble.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text(question).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("Yes", action: yes).buttonStyle(.borderedProminent)
                Button("No", action: no).buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }
}

private struct TranscriptLine: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .user:
            UserBubble(text: entry.text)
        case .assistant:
            AnswerText(text: entry.text)
        case .tool(let name):
            ToolActivity(name: name, detail: entry.text)
        }
    }
}

private struct PendingLine: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            UserBubble(text: text)
            Text("Sending\u{2026}").font(.caption).foregroundStyle(.secondary)
        }
        .opacity(0.6)
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.07)))
        }
    }
}

/// One line for a tool Claude ran; the click shows what it was given in full.
private struct ToolActivity: View {
    let name: String
    let detail: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Text(name).font(.callout.weight(.medium))
                    Text(detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, !detail.isEmpty {
                Text(detail)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
        .foregroundStyle(.secondary)
    }
}

#else

struct SessionsView: View {
    var body: some View {
        ContentUnavailableView("Sessions need the embedded terminal", systemImage: "terminal")
    }
}

#endif
