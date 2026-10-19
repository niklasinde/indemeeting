import Foundation
import Observation

struct ChatTurn: Identifiable, Equatable {
    let id = UUID()
    var role: String
    var text: String
    var tools: [String] = []
    var citations: [PhoneCitation] = []
    var isStreaming = false
    var failure: String?
    var isBusy = false

    var isUser: Bool { role == "user" }
}

enum ChatSuggestions {
    static func suggestions(for scope: PhoneChatScope) -> [String] {
        switch scope.kind {
        case "meeting": return ["Summarize this meeting", "List the action items that are mine", "What was decided?", "What questions are still open?"]
        case "day": return ["What did I work on?", "Which tickets did I touch?", "Where did most of the time go?"]
        case "week": return ["What did I work on this week?", "Which projects got the most time?", "Summarize my week for a status update"]
        default: return ["What meetings did I have this week?", "What did I decide about the release?", "What are my open action items?", "What did I work on yesterday?"]
        }
    }
}

/// One conversation with the Mac's on-device model. One question is answered at a time; a second one is held back here
/// and by the Mac, which answers `429 chat_busy`.
@Observable @MainActor
final class ChatModel {
    private(set) var turns: [ChatTurn] = []
    private(set) var isAnswering = false
    let scope: PhoneChatScope
    let title: String

    private let model: AppModel
    private var task: Task<Void, Never>?

    init(model: AppModel, scope: PhoneChatScope = PhoneChatScope(kind: "general"), title: String = "Chat") {
        self.model = model
        self.scope = scope
        self.title = title
    }

    var isMeetingChat: Bool { scope.kind == "meeting" }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        let history = Self.messages(from: turns) + [PhoneChatMessage(role: "user", text: String(question.prefix(8000)))]
        turns.append(ChatTurn(role: "user", text: question))
        turns.append(ChatTurn(role: "assistant", text: "", isStreaming: true))
        isAnswering = true
        task = Task { await run(history) }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        task?.cancel()
        turns = []
    }

    /// The turns the Mac needs to rebuild its context: questions that were answered, at most 40.
    nonisolated static func messages(from turns: [ChatTurn]) -> [PhoneChatMessage] {
        var messages: [PhoneChatMessage] = []
        for (index, turn) in turns.enumerated() {
            let answer = turns.indices.contains(index + 1) ? turns[index + 1] : nil
            let answered = turn.isUser ? answer.map { !$0.isStreaming && $0.failure == nil && !$0.text.isEmpty } ?? false
                : !turn.isStreaming && turn.failure == nil && !turn.text.isEmpty
            if answered { messages.append(PhoneChatMessage(role: turn.role, text: String(turn.text.prefix(8000)))) }
        }
        return Array(messages.suffix(39))
    }

    /// Asks the last question again, after the Mac was busy or the answer failed.
    func retry() {
        guard !isAnswering, turns.count >= 2, turns[turns.count - 2].isUser, turns.last?.failure != nil else { return }
        let question = turns[turns.count - 2].text
        turns.removeLast(2)
        send(question)
    }

    private func update(_ change: (inout ChatTurn) -> Void) {
        guard !turns.isEmpty else { return }
        change(&turns[turns.count - 1])
    }

    private func run(_ messages: [PhoneChatMessage]) async {
        defer {
            isAnswering = false
            update { $0.isStreaming = false }
        }
        do {
            var lines = NDJSONLineBuffer()
            var statusHead: HTTPResponseHead?
            var errorBody = Data()
            var finished = false
            for try await event in try model.chatStream(PhoneChatRequest(scope: scope, messages: messages)) {
                switch event {
                case .head(let head): statusHead = head
                case .body(let data):
                    if statusHead?.status == 200 {
                        for line in lines.feed(data) where apply(line) { finished = true }
                    } else {
                        errorBody.append(data)
                    }
                case .end: break
                }
            }
            model.reportSuccess()
            if let head = statusHead, head.status != 200 {
                let error = try? PhoneAPI.decoder.decode(PhoneError.self, from: errorBody)
                update {
                    $0.isBusy = head.status == 429
                    $0.failure = head.status == 429 ? "The Mac is answering another question. Try again in a moment."
                        : error?.message ?? "The Mac could not answer (\(head.status))."
                }
                if head.status == 401 { model.report(PhoneNetworkError.http(status: 401, error: error)) }
            } else if !finished, let last = lines.flush(), apply(last) {
            } else if !finished, !Task.isCancelled {
                update { if $0.text.isEmpty && $0.failure == nil { $0.failure = "The answer was interrupted." } }
            }
        } catch is CancellationError {
            update { if $0.text.isEmpty { $0.failure = "Stopped." } }
        } catch let error as PhoneNetworkError {
            model.report(error)
            update { $0.failure = error.message }
        } catch {
            update { $0.failure = error.localizedDescription }
        }
        if Task.isCancelled { update { if $0.failure == nil, $0.text.isEmpty { $0.failure = "Stopped." } } }
    }

    /// Applies one line of the stream; true when it was the final answer or an error.
    private func apply(_ line: Data) -> Bool {
        guard let event = try? PhoneAPI.decoder.decode(PhoneChatEvent.self, from: line) else { return false }
        switch event.type {
        case "tool":
            if let note = event.note { update { $0.tools.append(note) } }
        case "token":
            if let text = event.text { update { $0.text += text } }
        case "citations":
            update { $0.citations = event.citations ?? [] }
        case "done":
            update {
                if let text = event.text { $0.text = text }
                $0.isStreaming = false
            }
            return true
        case "error":
            update { $0.failure = event.message ?? "The Mac could not answer." }
            return true
        default: break
        }
        return false
    }
}
