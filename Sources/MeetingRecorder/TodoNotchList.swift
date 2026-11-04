import EventKit
import SwiftUI

@MainActor
final class TodoModel: ObservableObject {
    static let shared = TodoModel()
    @Published private(set) var todos: [TodoItem] = []
    @Published private(set) var meeting: [MeetingTodo] = []
    @Published private(set) var access = TodoAccess.unknown
    @Published private(set) var lists: [TodoList] = []
    @Published private(set) var list: String?
    private var reminders: (any TodoStore)?
    private var store: MeetingStore?
    private var observers: [NSObjectProtocol] = []

    func start(store: MeetingStore, reminders: RemindersStore) {
        self.store = store
        self.reminders = reminders
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .EKEventStoreChanged, object: reminders.events, queue: .main) { _ in
                MainActor.assumeIsolated { TodoModel.shared.reloadReminders() }
            },
            center.addObserver(forName: MeetingStore.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TodoModel.shared.reloadMeetings() }
            },
        ]
        reloadMeetings()
        reloadReminders()
    }

    /// Asks for Reminders access the first time the list is opened, not at launch.
    func open() {
        guard let reminders else { return }
        guard reminders.access == .unknown else { return reloadReminders() }
        Task {
            _ = await reminders.requestAccess()
            reloadReminders()
        }
    }

    func reloadReminders() {
        guard let reminders else { return }
        access = reminders.access
        lists = reminders.lists
        list = TodoLogic.selectedList(stored: UserDefaults.standard.string(forKey: TodoLogic.listKey), lists: lists, defaultID: reminders.defaultListID)
        let list = list
        Task {
            let items = await TodoLogic.load(from: reminders, list: list)
            withAnimation(.easeOut(duration: 0.15)) { todos = items }
        }
    }

    var title: String { TodoLogic.title(of: list, in: lists) }

    func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: TodoLogic.listKey)
        reloadReminders()
    }

    func reloadMeetings() {
        meeting = (try? store?.openActionItems(limit: 100, since: TodoLogic.meetingCutoff(now: Date()))) ?? []
    }

    func add(_ input: String) {
        guard let text = TodoLogic.text(input) else { return }
        try? reminders?.addTodo(text, to: list ?? TodoLogic.allLists)
        reloadReminders()
    }

    func complete(_ id: TodoRow.ID) {
        withAnimation(.easeOut(duration: 0.25)) {
            switch id {
            case .todo(let id): todos.removeAll { $0.id == id }
            case .meeting(let id): meeting.removeAll { $0.id == id }
            }
        }
        switch id {
        case .todo(let id): try? reminders?.complete(id)
        case .meeting(let id): try? store?.setChecked(actionItem: id, true)
        }
    }

    func delete(_ id: String) {
        withAnimation(.easeOut(duration: 0.2)) { todos.removeAll { $0.id == id } }
        try? reminders?.delete(id)
    }
}

enum TodoRow {
    enum ID: Hashable {
        case todo(String)
        case meeting(Int64)
    }
}

/// The notch bar's todo list, after Apple Reminders: round checkboxes that fill and drop out, and a New Reminder row at the end.
struct TodoNotchList: View {
    static let completionDelay = 1.0
    let onHold: (Bool) -> Void
    let onType: (String) -> Void
    @ObservedObject private var model = TodoModel.shared
    @State private var checking: Set<TodoRow.ID> = []
    @State private var adding = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                listPicker
                Spacer()
                Text("\(model.todos.count)").font(.title3.bold()).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            ForEach(model.todos.prefix(TodoLogic.todoLimit)) { todo in
                row(.todo(todo.id), text: todo.text, detail: nil)
                    .contextMenu { Button("Delete", role: .destructive) { model.delete(todo.id) } }
                separator
            }
            if model.access == .denied {
                deniedRow
            } else {
                newReminder
            }
            if !model.meeting.isEmpty {
                Text("From meetings")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                ForEach(model.meeting.prefix(TodoLogic.meetingLimit)) { item in
                    row(.meeting(item.id), text: item.task, detail: [item.owner, item.title].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    if item.id != model.meeting.prefix(TodoLogic.meetingLimit).last?.id { separator }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .onAppear { model.open() }
        .onDisappear { end(keep: true) }
    }

    private var separator: some View {
        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 38)
    }

    private func row(_ id: TodoRow.ID, text: String, detail: String?) -> some View {
        let checked = checking.contains(id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { toggle(id) } label: { CheckCircle(checked: checked) }
                .buttonStyle(.plain)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                Text(text).lineLimit(2).foregroundStyle(checked ? .secondary : .primary)
                if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .opacity(checked ? 0.6 : 1)
        .animation(.easeOut(duration: 0.15), value: checked)
        .transition(.opacity)
    }

    private var listPicker: some View {
        Menu {
            Button { model.select(TodoLogic.allLists) } label: {
                if model.list == TodoLogic.allLists { Label("All", systemImage: "checkmark") } else { Text("All") }
            }
            let groups = TodoLogic.grouped(model.lists)
            ForEach(groups, id: \.source) { group in
                Section(groups.count > 1 ? group.source : "") {
                    ForEach(group.lists) { list in
                        Button { model.select(list.id) } label: {
                            if list.id == model.list { Label(list.title, systemImage: "checkmark") } else { Text(list.title) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.title).font(.title3.bold())
                Image(systemName: "chevron.down").font(.caption.bold())
            }
            .foregroundStyle(Color.accentColor)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.access != .granted)
    }

    private var deniedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.circle").font(.system(size: 18)).foregroundStyle(.secondary)
            Text("Allow Reminders access in System Settings").foregroundStyle(.secondary)
            Spacer()
            Button("Open") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
            }
            .buttonStyle(NotchChipStyle(selected: false))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private var newReminder: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(adding ? Color.secondary : Color.accentColor)
            if adding {
                TextField("New Reminder", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { end(keep: false) }
                    .onChange(of: draft) { _, text in onType(text) }
            } else {
                Text("New Reminder").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: begin)
    }

    private func toggle(_ id: TodoRow.ID) {
        if checking.remove(id) != nil { return }
        checking.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionDelay) {
            guard checking.remove(id) != nil else { return }
            model.complete(id)
        }
    }

    private func begin() {
        guard !adding else { return }
        adding = true
        onHold(true)
        DispatchQueue.main.async { focused = true }
    }

    private func submit() {
        model.add(draft)
        draft = ""
        DispatchQueue.main.async { focused = true }
    }

    private func end(keep: Bool) {
        guard adding else { return }
        if keep { model.add(draft) }
        draft = ""
        adding = false
        focused = false
        onHold(false)
    }
}

private struct CheckCircle: View {
    let checked: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(checked ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1.5)
            if checked {
                Circle().fill(Color.accentColor).padding(3)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: checked)
    }
}
