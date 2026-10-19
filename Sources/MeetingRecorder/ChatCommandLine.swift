import Foundation

enum ChatCommandLine {
    /// `--chat "<question>"`: prints the lookups and the streamed answer, then exits. Reads the database without writing.
    static func run(_ job: ChatLogic.ChatJob) -> Never {
        #if canImport(FoundationModels)
        setvbuf(stdout, nil, _IOLBF, 0)
        let store: MeetingStore
        do { store = try MeetingStore.openReadOnly() } catch { fail(error.localizedDescription) }
        let scope: ChatScope
        do { scope = try self.scope(job, store) } catch { fail(error.localizedDescription) }
        let engine = ChatEngine(store: store, scope: scope)
        Task {
            let printed = Counter()
            do {
                let answer = try await engine.ask(job.question, onText: { text in
                    print(String(text.dropFirst(printed.value)), terminator: "")
                    fflush(stdout)
                    printed.value = text.count
                }, onTool: { note in
                    print("  \u{25B8} " + note.replacingOccurrences(of: "\n", with: "\n      "))
                }, onFreshContext: { print("  (started a fresh context)") })
                print(answer.isEmpty ? "(no answer)" : "")
                exit(0)
            } catch {
                fail("\(error.localizedDescription) [\(String(reflecting: error).prefix(200))]")
            }
        }
        dispatchMain()
        #else
        fail("This Mac cannot run the on-device model.")
        #endif
    }

    private static func scope(_ job: ChatLogic.ChatJob, _ store: MeetingStore) throws -> ChatScope {
        if let id = job.meeting {
            guard let meeting = try store.meeting(id: id) else { fail("No meeting with id \(id)") }
            return .meeting(id, label: meeting.title)
        }
        if let day = job.day { return .day(containing: try MCPServer.date(day)) }
        return .general
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Failed: \(message)\n".utf8))
        exit(1)
    }

    private final class Counter: @unchecked Sendable { var value = 0 }
}
