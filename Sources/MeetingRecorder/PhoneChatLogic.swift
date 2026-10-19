import Foundation

/// Lets one chat generation run at a time, since the on-device model answers one question at once.
final class PhoneChatGate: @unchecked Sendable {
    static let shared = PhoneChatGate()

    private let lock = NSLock()
    private var busy = false

    func acquire() -> Bool { lock.withLock { busy ? false : { busy = true; return true }() } }
    func release() { lock.withLock { busy = false } }
}

enum PhoneChatLogic {
    /// The text added since `previous`; the whole of `current` when it does not continue it.
    static func delta(from previous: String, to current: String) -> String {
        current.hasPrefix(previous) ? String(current.dropFirst(previous.count)) : current
    }

    static func citations(notes: [String], title: (Int64) -> String?) -> [PhoneCitation] {
        var seen = Set<Int64>()
        return notes.flatMap(ChatLogic.meetingIDs(inNote:)).compactMap { id in
            guard seen.insert(id).inserted, let title = title(id) else { return nil }
            return PhoneCitation(meetingId: id, title: title)
        }
    }
}
