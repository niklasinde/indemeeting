import SwiftUI

/// The Claude API chat: the chats in the store, the reply being streamed, and the key and model it uses.
@MainActor
final class ClaudeAPIChatModel: ObservableObject {
    @Published private(set) var chats: [ClaudeAPIChat] = []
    @Published private(set) var current: ClaudeAPIChat?
    @Published private(set) var messages: [ClaudeAPIStoredMessage] = []
    /// The reply so far while one is being streamed; nil otherwise.
    @Published private(set) var streaming: String?
    @Published private(set) var failure: String?
    @Published var draft = ""
    @Published var includesPullRequest = false
    @Published private(set) var hasKey = false
    /// The pull request the context chip offers, read on `reload` rather than on every render of a streamed reply.
    @Published private(set) var pullRequest: ClaudeAPIContext.PullRequest?

    let store: MeetingStore
    let keys: ClaudeAPIKeyStore
    var client: ClaudeAPIClient
    /// The pull request selected in GitHub, read when a message is sent with the context chip on.
    var selectedPullRequest: () -> ClaudeAPIContext.PullRequest?
    private var task: Task<Void, Never>?

    init(store: MeetingStore, keys: ClaudeAPIKeyStore = .live, client: ClaudeAPIClient = ClaudeAPIClient(),
         selectedPullRequest: @escaping () -> ClaudeAPIContext.PullRequest? = { nil }) {
        self.store = store
        self.keys = keys
        self.client = client
        self.selectedPullRequest = selectedPullRequest
        reload()
    }

    var isResponding: Bool { task != nil }

    func reload() {
        hasKey = keys.key() != nil
        pullRequest = selectedPullRequest()
        chats = (try? store.claudeAPIChats()) ?? []
        if let current, let fresh = chats.first(where: { $0.id == current.id }) {
            self.current = fresh
            messages = (try? store.claudeAPIMessages(chat: fresh.id)) ?? []
        } else {
            current = nil
            messages = []
        }
    }

    func newChat() {
        stop()
        current = nil
        messages = []
        failure = nil
        draft = ""
    }

    func open(_ chat: ClaudeAPIChat) {
        stop()
        current = chat
        failure = nil
        reload()
    }

    func delete(_ chat: ClaudeAPIChat) {
        try? store.deleteClaudeAPIChat(chat.id)
        if current?.id == chat.id { newChat() }
        reload()
    }

    func deleteAll() {
        stop()
        _ = try? store.deleteAllClaudeAPIChats()
        newChat()
        reload()
    }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        guard let key = keys.key() else {
            failure = ClaudeAPIError.noKey.message
            return
        }
        failure = nil
        draft = ""
        do {
            let chat: ClaudeAPIChat
            if let current {
                chat = current
            } else {
                let id = try store.createClaudeAPIChat(title: ClaudeAPIChat.title(for: question))
                chat = try store.claudeAPIChats().first { $0.id == id } ?? ClaudeAPIChat(id: id, title: "New chat", created: Date(), updated: Date())
                current = chat
            }
            try store.addClaudeAPIMessage(chat: chat.id, role: .user, text: question)
        } catch {
            failure = error.localizedDescription
            return
        }
        reload()

        let context = includesPullRequest ? selectedPullRequest().map(ClaudeAPIContext.text(for:)) : nil
        let history = messages.map { ClaudeAPIMessage(role: $0.role, text: $0.text) }
        let chatID = current?.id
        let client = client
        let model = ClaudeAPIModel.stored(UserDefaults.standard.string(forKey: ClaudeAPIModel.storageKey)).rawValue
        streaming = ""
        task = Task { [weak self] in
            var text = ""
            var saved = false
            do {
                for try await event in client.reply(key: key, model: model, system: ClaudeAPIRequest.system(context: context), messages: history) {
                    switch event {
                    case .text(let piece):
                        text += piece
                        self?.streaming = text
                    case .finished(let usage):
                        if let chatID, !text.isEmpty {
                            try? self?.store.addClaudeAPIMessage(chat: chatID, role: .assistant, text: text, usage: usage)
                            saved = true
                        }
                    }
                }
            } catch {
                self?.failure = (error as? ClaudeAPIError)?.message ?? error.localizedDescription
            }
            if !saved, let chatID, !text.isEmpty {
                try? self?.store.addClaudeAPIMessage(chat: chatID, role: .assistant, text: text)
            }
            self?.streaming = nil
            self?.task = nil
            self?.reload()
        }
    }

    func stop() {
        task?.cancel()
    }
}
