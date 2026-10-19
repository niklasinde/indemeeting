import AppKit
import SwiftUI

/// A small menu on a row of the breakdown that maps what the row stands for to a project with a rule.
struct AssignProjectButton: View {
    @ObservedObject var model: ActivityModel
    let candidates: [RuleCandidate]
    @State private var creating = false

    var body: some View {
        Menu {
            ForEach(model.projects) { project in
                if candidates.count == 1 {
                    item(candidates[0], project)
                } else {
                    Menu(project.name) { ForEach(candidates, id: \.self) { item($0, project) } }
                }
            }
            if !model.projects.isEmpty { Divider() }
            Button("New project\u{2026}") { creating = true }
        } label: {
            Image(systemName: "folder.badge.plus")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .opacity(0.5)
        .help("Assign project\u{2026}")
        .popover(isPresented: $creating) { NewProjectForm(model: model, candidates: candidates) { creating = false } }
    }

    private func item(_ candidate: RuleCandidate, _ project: Project) -> some View {
        Button("Always map \(candidate.text) to \(project.name)") { model.assign(candidate, to: project) }
            .disabled(model.rules.contains { $0.projectID == project.id && $0.field == candidate.field
                && $0.pattern.caseInsensitiveCompare(candidate.pattern) == .orderedSame })
    }
}

private struct NewProjectForm: View {
    @ObservedObject var model: ActivityModel
    let candidates: [RuleCandidate]
    let done: () -> Void
    @State private var name = ""
    @State private var candidate: RuleCandidate?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New project").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            if candidates.count > 1 {
                Picker("Always map", selection: Binding(get: { candidate ?? candidates[0] }, set: { candidate = $0 })) {
                    ForEach(candidates, id: \.self) { Text($0.text).tag($0) }
                }
            } else if let only = candidates.first {
                Text("Always map \(only.text) to this project").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, let rule = candidate ?? candidates.first else { return }
        model.assign(rule, toNew: name)
        done()
    }
}

/// A one-line hint in the Activity view when much of the tracked time has no project.
struct ProjectSetupHint: View {
    @ObservedObject var model: ActivityModel
    @State private var showing = false

    static let threshold = 0.3

    var body: some View {
        let share = ActivityLogic.unassignedShare(model.blocks, in: model.range, rules: model.rules)
        if share > Self.threshold {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark").foregroundStyle(.secondary)
                Text("\(Int((share * 100).rounded()))% of the tracked time has no project.").foregroundStyle(.secondary)
                Button("Set up projects from your activity\u{2026}") { showing = true }.buttonStyle(.link)
                Spacer()
            }
            .font(.callout)
            .sheet(isPresented: $showing) { ProjectSetupView(store: model.store) { showing = false } }
        }
    }
}

/// Lists the organisations, repositories, ticket prefixes and websites of the last month's unassigned activity, each
/// with a project name, and creates the chosen projects and rules.
struct ProjectSetupView: View {
    let store: MeetingStore
    let done: () -> Void
    @State private var groups: [SetupGroup] = []
    @State private var names: [String: String] = [:]
    @State private var selected: Set<String> = []

    private static let sections: [(RuleField, String)] = [(.owner, "Organisations"), (.repo, "Repositories"), (.ticket, "Ticket prefixes"), (.host, "Websites")]

    init(store: MeetingStore, done: @escaping () -> Void) {
        self.store = store
        self.done = done
        let end = Date()
        let blocks = (try? store.blocks(in: end.addingTimeInterval(-30 * 86_400)..<end)) ?? []
        let groups = ProjectSetup.groups(blocks, rules: (try? store.rules()) ?? [])
        _groups = State(initialValue: groups)
        _names = State(initialValue: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.suggestedName) }))
        _selected = State(initialValue: Set(groups.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up projects from your activity").font(.title3.weight(.medium))
            Text("What the last 30 days of unassigned activity were about. Items with the same project name become one project; "
                 + "each checked item gets a rule.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if groups.isEmpty {
                Text("Nothing left to assign.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.sections, id: \.0) { field, title in
                            let items = groups.filter { $0.field == field }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    ForEach(items) { row($0) }
                                }
                            }
                        }
                    }
                    .padding(3)
                }
                .frame(maxHeight: 380)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Create projects & rules", action: create).keyboardShortcut(.defaultAction).disabled(choices.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func row(_ group: SetupGroup) -> some View {
        HStack(spacing: 8) {
            Toggle(group.pattern, isOn: Binding(get: { selected.contains(group.id) },
                                                set: { if $0 { selected.insert(group.id) } else { selected.remove(group.id) } }))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(ActivityLogic.hoursText(group.seconds)).foregroundStyle(.secondary).monospacedDigit()
            TextField("Project", text: Binding(get: { names[group.id] ?? "" }, set: { names[group.id] = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 150)
        }
        .font(.callout)
    }

    private var choices: [SetupChoice] {
        groups.filter { selected.contains($0.id) }.map { SetupChoice(field: $0.field, pattern: $0.pattern, name: names[$0.id] ?? "") }
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func create() {
        do { try store.createProjects(choices) } catch { NSAlert(error: error).runModal() }
        done()
    }
}
