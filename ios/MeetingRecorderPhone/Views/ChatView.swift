import SwiftUI

struct ChatTab: View {
    @Environment(AppModel.self) private var appModel
    @State private var chat: ChatModel?

    var body: some View {
        NavigationStack {
            Group {
                if let chat { ChatView(chat: chat) } else { ProgressView() }
            }
            .navigationTitle("Chat")
        }
        .task { chat = chat ?? ChatModel(model: appModel) }
    }
}

struct ChatSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let scope: PhoneChatScope
    let title: String
    @State private var chat: ChatModel?

    var body: some View {
        NavigationStack {
            Group {
                if let chat { ChatView(chat: chat) } else { ProgressView() }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task { chat = chat ?? ChatModel(model: appModel, scope: scope, title: title) }
        .presentationDetents([.large])
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if appModel.status?.features.chatAvailable == false {
                ProblemView(title: "Chat is unavailable", message: "Apple Intelligence is not available on your Mac right now, so it cannot answer questions.",
                            systemImage: "sparkles.slash")
            } else {
                transcript.safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .toolbar {
            if !chat.turns.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { chat.reset() } label: { Label("New chat", systemImage: "square.and.pencil") }.disabled(chat.isAnswering)
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.turns.isEmpty { welcome }
                    ForEach(chat.turns) { turn in
                        TurnView(turn: turn, isMeetingChat: chat.isMeetingChat, meetingId: chat.scope.meetingId, retry: { chat.retry() }, open: open)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.turns) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tint)
            Text(chat.isMeetingChat ? "Ask about this meeting" : "Ask about your meetings and work").font(.title3.bold())
            Text("Answers come from the on-device model on your Mac, using your meetings and activity. Nothing leaves your Mac.")
                .font(.subheadline).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(ChatSuggestions.suggestions(for: chat.scope), id: \.self) { suggestion in
                    Button(suggestion) { chat.send(suggestion) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 24)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a question", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassBackground(RoundedRectangle(cornerRadius: 22))
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: chat.isAnswering ? chat.cancel : send) {
                Image(systemName: chat.isAnswering ? "stop.fill" : "arrow.up")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .prominentGlassButton()
            .buttonBorderShape(.circle)
            .disabled(!chat.isAnswering && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(chat.isAnswering ? "Stop" : "Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func send() {
        guard !chat.isAnswering else { return }
        chat.send(draft)
        draft = ""
    }

    private func open(meeting id: Int64, title: String?, seconds: Double?) {
        dismiss()
        router.open(meeting: id, title: title, seek: seconds)
    }
}

private struct TurnView: View {
    let turn: ChatTurn
    let isMeetingChat: Bool
    let meetingId: Int64?
    let retry: () -> Void
    let open: (Int64, String?, Double?) -> Void

    var body: some View {
        if turn.isUser {
            Text(turn.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: .rect(cornerRadius: 18))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
                .accessibilityLabel("You: \(turn.text)")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let first = turn.tools.first {
                    DisclosureGroup {
                        Text(turn.tools.dropFirst().joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label(first, systemImage: "magnifyingglass").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .disabled(turn.tools.count < 2)
                }
                if turn.text.isEmpty, turn.failure == nil {
                    HStack(spacing: 8) { ProgressView(); Text("Thinking on your Mac\u{2026}").foregroundStyle(.secondary) }.font(.subheadline)
                } else if !turn.text.isEmpty {
                    Text(MarkdownText.attributed(isMeetingChat ? PhoneFormat.linkTimes(in: turn.text) : turn.text))
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            guard let seconds = PhoneFormat.seekSeconds(url) else { return .systemAction }
                            if let meetingId { open(meetingId, nil, seconds) }
                            return .handled
                        })
                }
                if let failure = turn.failure {
                    Label(failure, systemImage: turn.isBusy ? "hourglass" : "exclamationmark.triangle").font(.subheadline).foregroundStyle(turn.isBusy ? Color.orange : .red)
                    if turn.isBusy || turn.failure != nil { Button("Try again", action: retry).buttonStyle(.bordered).controlSize(.small) }
                }
                if !turn.citations.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(turn.citations, id: \.meetingId) { citation in
                            Button { open(citation.meetingId, citation.title, citation.seconds) } label: {
                                Label(citation.title, systemImage: "waveform").lineLimit(1).font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint("Opens the meeting")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 24)
        }
    }
}
