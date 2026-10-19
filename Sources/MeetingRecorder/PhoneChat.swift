import Foundation

extension PhoneEndpoints {
    static var chatAvailable: Bool {
        #if canImport(FoundationModels)
        return ChatEngine.unavailable == nil
        #else
        return false
        #endif
    }
}

#if canImport(FoundationModels)
extension PhoneChatJob {
    /// The answer as events: lookups and text as they come, then the meetings the lookups returned and the whole answer.
    /// Cancelling the consumer stops the generation. The caller must hold the gate; it is released when the stream ends.
    func events(store: MeetingStore) -> AsyncStream<PhoneChatEvent> {
        AsyncStream { continuation in
            let engine = ChatEngine(store: store, scope: scope, history: history)
            let state = StreamState()
            let task = Task {
                defer { PhoneChatGate.shared.release() }
                do {
                    let answer = try await engine.ask(question, onText: { text in
                        let added = PhoneChatLogic.delta(from: state.sent, to: text)
                        state.sent = text
                        if !added.isEmpty { continuation.yield(.token(added)) }
                    }, onTool: { note in
                        state.notes.append(note)
                        continuation.yield(.tool(note))
                    }, onFreshContext: {
                        continuation.yield(.tool("Started a fresh context"))
                    })
                    if !scope.isAboutMeeting {
                        let citations = PhoneChatLogic.citations(notes: state.notes) { (try? store.meeting(id: $0))?.title }
                        if !citations.isEmpty { continuation.yield(.citations(citations)) }
                    }
                    continuation.yield(.done(answer))
                } catch {
                    continuation.yield(.failed(Task.isCancelled ? "Cancelled" : error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private final class StreamState: @unchecked Sendable {
        var sent = ""
        var notes: [String] = []
    }
}
#endif
