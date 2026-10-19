import SwiftUI

/// "Ask" on a meeting: one click starts a chat about the meeting (about its notes while the Notes tab is open); the menu
/// lists the chats already held about it.
struct AskButton: View {
    let meeting: Meeting
    let title: String
    let notes: Bool
    @State private var chats: [Chat] = []

    var body: some View {
        Menu {
            Button("New Chat About This Meeting") { ChatWindow.shared.show(scope: .meeting(meeting.id, label: title)) }
            Button("New Chat About My Notes") { ChatWindow.shared.show(scope: .notes(meeting.id, label: title)) }
            if !chats.isEmpty {
                Divider()
                ForEach(chats) { chat in Button(chat.title) { ChatWindow.shared.show(chat: chat) } }
            }
        } label: {
            Label(chats.isEmpty ? "Ask" : "Ask \u{00B7} \(chats.count)", systemImage: "bubble.left.and.text.bubble.right")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            ChatWindow.shared.show(scope: notes ? .notes(meeting.id, label: title) : .meeting(meeting.id, label: title))
        }
        .fixedSize()
        .help(notes ? "Ask about these notes" : "Ask about this meeting")
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: MeetingStore.chatsDidChange)) { _ in reload() }
    }

    private func reload() {
        chats = ChatWindow.shared.model.flatMap { try? $0.store.chats().filter { $0.scope.meetingID == meeting.id } } ?? []
    }
}

struct ChatSettingsSection: View {
    @State private var count = 0
    @State private var confirming = false

    var body: some View {
        SettingsSection("Chat", footer: "Chats stay on this Mac: your questions, the answers and a note of what was looked up. "
                        + "The meeting and activity text read to answer them is not stored.") {
            SettingsRow("Delete all chats", detail: count == 0 ? "No chats stored" : "\(count) chat\(count == 1 ? "" : "s") stored") {
                Button("Delete All Chats\u{2026}") { confirming = true }.disabled(count == 0)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: MeetingStore.chatsDidChange)) { _ in reload() }
        .alert("Delete all chats?", isPresented: $confirming) {
            Button("Delete", role: .destructive) {
                ChatWindow.shared.model?.deleteAll()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(count) chat\(count == 1 ? "" : "s") and their messages are removed. Meetings and activity are not touched.")
        }
    }

    private func reload() {
        count = (try? ChatWindow.shared.model?.store.chats().count) ?? 0
    }
}
