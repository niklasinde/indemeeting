import AppKit
import SwiftUI

@MainActor
final class ClaudeAPIWindow {
    static let shared = ClaudeAPIWindow()

    private(set) var model: ClaudeAPIChatModel?
    private var window: AppWindow?

    func configure(store: MeetingStore) {
        let model = ClaudeAPIChatModel(store: store, selectedPullRequest: { ClaudeAPIWindow.selectedPullRequest() })
        self.model = model
        window = AppWindow(onClose: { model.stop() }) { Self.makeWindow(ClaudeAPIView(model: model)) }
    }

    func show() {
        guard let model else { return }
        model.reload()
        window?.show()
    }

    /// The pull request selected in GitHub, with its cached description and checks; nil when none is selected.
    static func selectedPullRequest() -> ClaudeAPIContext.PullRequest? {
        let github = GitHubModel.shared
        guard let url = github.selectedURL, let pr = github.prs.values.lazy.flatMap({ $0 }).first(where: { $0.url == url }) else { return nil }
        let detail = (try? github.store?.githubDetail(url)) ?? nil
        return ClaudeAPIContext.PullRequest(title: pr.title, url: pr.url, repo: pr.repo,
                                            checks: detail.map { GitHubLogic.checkSummary($0.checks) } ?? pr.checks.rawValue,
                                            description: detail?.body)
    }

    static func makeWindow(_ view: ClaudeAPIView) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Claude API"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 860, height: 620))
        return window
    }
}

struct ClaudeAPIView: View {
    @ObservedObject var model: ClaudeAPIChatModel
    @ObservedObject private var github = GitHubModel.shared
    @State private var height: CGFloat = 26
    @AppStorage(ClaudeAPIModel.storageKey) private var modelID = ClaudeAPIModel.defaultModel.rawValue

    var body: some View {
        HStack(spacing: 0) {
            chatList.frame(width: 220)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.hasKey {
                    conversation
                    composer
                } else {
                    missingKey
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: MeetingStore.claudeAPIDidChange)) { _ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: ClaudeAPIKeyStore.didChange)) { _ in model.reload() }
        .onReceive(github.$selectedURL) { _ in model.reload() }
    }

    private var chatList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude API").font(.headline)
                Spacer()
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New chat")
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.chats) { chat in
                        Button { model.open(chat) } label: {
                            Text(chat.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(model.current?.id == chat.id ? Color.primary.opacity(0.08) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Delete Chat", role: .destructive) { model.delete(chat) } }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.current?.title ?? "New chat").font(.system(size: 20, weight: .medium)).lineLimit(1)
            Spacer()
            Text(ClaudeAPIModel.stored(modelID).title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var missingKey: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No API key yet").font(.body.weight(.medium))
            Text("Add your Anthropic API key in Settings, under Claude API. It is kept in your Keychain.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440, alignment: .leading)
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var conversation: some View {
        if model.messages.isEmpty, model.streaming == nil {
            ScrollView {
                Text("Ask Claude anything. Replies come from the Anthropic API and are billed to your account.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, RecordingDetail.gutter)
                    .padding(.top, 12)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { message in
                            ClaudeAPIBubble(message: message)
                        }
                        if let streaming = model.streaming {
                            VStack(alignment: .leading, spacing: 6) {
                                if streaming.isEmpty {
                                    ProgressView().controlSize(.small)
                                } else {
                                    AnswerText(text: streaming)
                                }
                            }
                        }
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
        VStack(alignment: .leading, spacing: 8) {
            if let pr = model.pullRequest {
                Button { model.includesPullRequest.toggle() } label: {
                    Label("Include the current PR", systemImage: model.includesPullRequest ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.includesPullRequest ? Color.accentColor : .secondary)
                .help("Adds \(pr.title) (title, link, checks and description) to this message. Read-only.")
            }
            HStack(alignment: .bottom, spacing: 10) {
                ChatComposer(text: $model.draft, height: $height, placeholder: "Message Claude") { model.send(model.draft) }
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
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, RecordingDetail.gutter - 14)
        .padding(.bottom, 16)
    }
}

/// One message: the user's on the right, Claude's on the left with its token counts under it.
struct ClaudeAPIBubble: View {
    let message: ClaudeAPIStoredMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                AnswerText(text: message.text)
                if let usage = message.usage {
                    Text("\(usage.inputTokens) in \u{00B7} \(usage.outputTokens) out tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ClaudeAPISettingsSection: View {
    @State private var stored: String?
    @State private var entry = ""
    @State private var problem: String?
    @State private var chatCount = 0
    @State private var confirming = false
    @AppStorage(ClaudeAPIModel.storageKey) private var modelID = ClaudeAPIModel.defaultModel.rawValue

    var keys = ClaudeAPIKeyStore.live
    /// The store the chat count reads; the open chat window's store when nil.
    var store: MeetingStore?

    init(keys: ClaudeAPIKeyStore = .live, store: MeetingStore? = nil) {
        self.keys = keys
        self.store = store
    }

    var body: some View {
        SettingsSection("Claude API", footer: "Stored in your Keychain. Messages are sent to Anthropic and billed to your account.") {
            SettingsRow("API key", detail: stored.map(ClaudeAPIKey.masked) ?? "No key saved") {
                if stored != nil {
                    Button("Remove") { remove() }
                }
            }
            HStack(spacing: 8) {
                SecureField("API key", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(save)
                Button("Save", action: save).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).padding(.horizontal, 14)
            }
            SettingsRow("Model", detail: ClaudeAPIModel.stored(modelID).detail) {
                Picker("Model", selection: $modelID) {
                    ForEach(ClaudeAPIModel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            SettingsRow("Chats", detail: chatCount == 0 ? "No Claude API chats stored" : "\(chatCount) chat\(chatCount == 1 ? "" : "s") stored") {
                Button("Delete All Claude API Chats\u{2026}") { confirming = true }.disabled(chatCount == 0)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: MeetingStore.claudeAPIDidChange)) { _ in reload() }
        .alert("Delete all Claude API chats?", isPresented: $confirming) {
            Button("Delete", role: .destructive) {
                _ = try? (store ?? ClaudeAPIWindow.shared.model?.store)?.deleteAllClaudeAPIChats()
                ClaudeAPIWindow.shared.model?.reload()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(chatCount) chat\(chatCount == 1 ? "" : "s") and their messages are removed. Claude Code chats are not touched.")
        }
    }

    private func reload() {
        stored = keys.key()
        chatCount = (try? (store ?? ClaudeAPIWindow.shared.model?.store)?.claudeAPIChats().count) ?? 0
    }

    private func save() {
        let key = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try keys.save(key)
            entry = ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        reload()
    }

    private func remove() {
        keys.remove()
        reload()
    }
}
