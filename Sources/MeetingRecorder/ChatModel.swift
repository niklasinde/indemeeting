import AppKit
import SwiftUI

/// The chat window's state: the stored chats, the open one, and the answer being written.
@MainActor
final class ChatModel: ObservableObject {
    static let freshContextNote = "Started a fresh context"

    @Published private(set) var chats: [Chat] = []
    @Published private(set) var current: Chat?
    @Published private(set) var scope = ChatScope.general
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var streaming: String?
    @Published private(set) var isResponding = false
    @Published private(set) var failure: String?
    @Published private(set) var meetingTitles: [Int64: String] = [:]
    @Published private(set) var unavailable: SummaryNotice?
    @Published var draft = ""

    let store: MeetingStore
    /// Shown instead of the chat, for the previews.
    var forcedUnavailable: SummaryNotice?
    var openMeeting: (Int64, TimeInterval?) -> Void = { _, _ in }
    private var engine: ChatEngine?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(store: MeetingStore) {
        self.store = store
    }

    var groups: [ChatLogic.ChatGroup] { ChatLogic.groups(chats, meetingTitles: meetingTitles) }
    var title: String { current?.title ?? "New chat" }
    var chipTitle: String { scope.chipTitle(meetingTitle: scope.meetingID.flatMap { meetingTitles[$0] }) }

    var suggestions: [ChatLogic.Suggestion] {
        ChatLogic.suggestions(for: scope, language: scope.meetingID.flatMap { id in (try? store.meeting(id: id))?.flatMap(\.language) } ?? .current)
    }

    func start() {
        guard observer == nil else { return refresh() }
        observer = NotificationCenter.default.addObserver(forName: MeetingStore.chatsDidChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        chats = (try? store.chats()) ?? []
        meetingTitles = Dictionary(((try? store.meetings()) ?? []).map { ($0.id, $0.title) }) { $1 }
        unavailable = forcedUnavailable ?? Self.availability
    }

    private static var availability: SummaryNotice? {
        #if canImport(FoundationModels)
        return ChatEngine.unavailable
        #else
        return SummaryNotice(.requiresMacOS26)
        #endif
    }

    /// An empty chat about `scope`; nothing is stored until the first question.
    func newChat(scope: ChatScope = .general) {
        stop()
        current = nil
        messages = []
        failure = nil
        self.scope = scope
        engine = nil
        refresh()
    }

    func open(_ chat: Chat) {
        stop()
        current = chat
        scope = chat.scope
        messages = (try? store.messages(ofChat: chat.id)) ?? []
        failure = nil
        engine = nil
        refresh()
    }

    func removeScope() {
        guard !scope.isGeneral else { return }
        scope = .general
        engine = nil
        guard let chat = current else { return }
        try? store.setScope(ofChat: chat.id, .general)
        current?.scope = .general
    }

    func rename(_ chat: Chat, to title: String) {
        try? store.renameChat(chat.id, to: title)
        if current?.id == chat.id { current?.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func delete(_ chat: Chat) {
        try? store.deleteChat(chat.id)
        if current?.id == chat.id { newChat(scope: .general) }
    }

    @discardableResult
    func deleteAll() -> Int {
        let count = (try? store.deleteAllChats()) ?? 0
        newChat(scope: .general)
        return count
    }

    func stop() {
        task?.cancel()
    }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding, unavailable == nil else { return }
        draft = ""
        failure = nil
        guard let chat = ensureChat(first: question) else { return }
        append(.user, question, to: chat)
        let engine = self.engine(for: chat)
        isResponding = true
        streaming = ""
        let isFirst = messages.filter { $0.role == .user }.count == 1
        task = Task { [weak self] in
            var answer = ""
            var failed = false
            do {
                answer = try await engine.ask(question, onText: { text in
                    Task { @MainActor in if self?.isResponding == true { self?.streaming = text } }
                }, onTool: { note in
                    Task { @MainActor in self?.append(.tool, "", note: note, to: chat) }
                }, onFreshContext: {
                    Task { @MainActor in self?.append(.tool, "", note: Self.freshContextNote, to: chat) }
                })
            } catch {
                failed = !Task.isCancelled
                if failed { self?.failure = error.localizedDescription }
            }
            self?.finish(chat, question: question, answer: answer, failed: failed, engine: engine, isFirst: isFirst)
        }
    }

    private func engine(for chat: Chat) -> ChatEngine {
        if let engine { return engine }
        let engine = ChatEngine(store: store, scope: chat.scope, history: messages.filter { $0.role != .tool }.dropLast().map { $0 })
        self.engine = engine
        return engine
    }

    private func finish(_ chat: Chat, question: String, answer: String, failed: Bool, engine: ChatEngine, isFirst: Bool) {
        let partial = streaming ?? ""
        streaming = nil
        isResponding = false
        let text = answer.isEmpty && !failed ? partial : answer
        guard !text.isEmpty else { return }
        if answer.isEmpty { engine.remember(question, text) }
        append(.assistant, text, to: chat)
        guard isFirst else { return }
        Task {
            guard let title = await ChatEngine.title(for: question) else { return }
            rename(chat, to: title)
        }
    }

    private func ensureChat(first question: String) -> Chat? {
        if let current { return current }
        guard let chat = try? store.createChat(title: ChatLogic.fallbackTitle(question), scope: scope) else { return nil }
        current = chat
        return chat
    }

    private func append(_ role: ChatRole, _ text: String, note: String? = nil, to chat: Chat) {
        guard current?.id == chat.id, let message = try? store.addMessage(chat: chat.id, role: role, text: text, toolNote: note) else { return }
        messages.append(message)
    }

    /// The meetings the lookups before the answer at `index` returned, in a chat that is not about one meeting.
    func sources(before index: Int) -> [Int64] {
        guard !scope.isAboutMeeting, messages.indices.contains(index), messages[index].role == .assistant else { return [] }
        var ids: [Int64] = []
        for message in messages[..<index].reversed() {
            if message.role == .user { break }
            ids += ChatLogic.meetingIDs(inNote: message.toolNote ?? "")
        }
        return Array(NSOrderedSet(array: ids.reversed())) as? [Int64] ?? []
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens a link in an answer: a time in the meeting or a meeting.
    func handle(_ url: URL) -> OpenURLAction.Result {
        if let seconds = ChatLogic.seekTarget(url), let id = scope.meetingID {
            openMeeting(id, seconds)
            return .handled
        }
        if let id = ChatLogic.meetingTarget(url) {
            openMeeting(id, nil)
            return .handled
        }
        return .systemAction
    }
}
