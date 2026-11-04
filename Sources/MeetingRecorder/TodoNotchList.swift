import SwiftUI

@MainActor
final class TodoModel: ObservableObject {
    static let shared = TodoModel()
    @Published private(set) var todos: [TodoItem] = []
    @Published private(set) var meeting: [MeetingTodo] = []
    private var store: (any TodoStore)?
    private var observers: [NSObjectProtocol] = []

    func start(store: any TodoStore) {
        self.store = store
        observers = [MeetingStore.todosDidChange, MeetingStore.didChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TodoModel.shared.reload() }
            }
        }
        reload()
    }

    func reload() {
        let now = Date()
        todos = TodoLogic.open((try? store?.todos()) ?? [])
        meeting = (try? store?.meetingTodos(since: TodoLogic.meetingCutoff(now: now))) ?? []
    }

    var openCount: Int { todos.count + meeting.count }

    func add(_ input: String) {
        guard let text = TodoLogic.text(input), let item = try? store?.addTodo(text, link: nil, now: Date()) else { return }
        withAnimation(.easeOut(duration: 0.15)) { todos.append(item) }
    }

    func complete(_ id: TodoRow.ID) {
        withAnimation(.easeOut(duration: 0.25)) {
            switch id {
            case .todo(let id): todos.removeAll { $0.id == id }
            case .meeting(let id): meeting.removeAll { $0.id == id }
            }
        }
        switch id {
        case .todo(let id): try? store?.setTodo(id, done: true, now: Date())
        case .meeting(let id): try? store?.setChecked(actionItem: id, true)
        }
    }

    func delete(_ id: Int64) {
        withAnimation(.easeOut(duration: 0.2)) { todos.removeAll { $0.id == id } }
        try? store?.deleteTodo(id)
    }
}

enum TodoRow {
    enum ID: Hashable {
        case todo(Int64)
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
                Text("Todo").font(.title3.bold()).foregroundStyle(Color.accentColor)
                Spacer()
                Text("\(model.openCount)").font(.title3.bold()).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            ForEach(model.todos.prefix(TodoLogic.todoLimit)) { todo in
                row(.todo(todo.id), text: todo.text, detail: nil)
                    .contextMenu { Button("Delete", role: .destructive) { model.delete(todo.id) } }
                separator
            }
            newReminder
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
