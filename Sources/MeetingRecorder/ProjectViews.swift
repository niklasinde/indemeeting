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

/// The last month's unassigned activity grouped by organisation, each group with the project it goes to: an existing one
/// when it matches, else a new one. Search, mail and social media are offered unchecked.
struct ProjectSetupView: View {
    let store: MeetingStore
    let done: () -> Void
    @State private var suggestions: [SetupSuggestion] = []
    @State private var projects: [Project] = []
    @State private var rules: [ProjectRule] = []
    @State private var names: [String: String] = [:]
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []

    init(store: MeetingStore, done: @escaping () -> Void) {
        self.store = store
        self.done = done
        let end = Date()
        let blocks = (try? store.blocks(in: end.addingTimeInterval(-30 * 86_400)..<end)) ?? []
        let projects = (try? store.projects()) ?? []
        let rules = (try? store.rules()) ?? []
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("git")
        let suggestions = ProjectSuggestionLogic.suggestions(blocks, rules: rules, projects: projects,
                                                             owners: ProjectSuggestionLogic.cloneOwners(under: root))
        _suggestions = State(initialValue: suggestions)
        _projects = State(initialValue: projects)
        _rules = State(initialValue: rules)
        _names = State(initialValue: Dictionary(uniqueKeysWithValues: suggestions.map { ($0.id, $0.name) }))
        _selected = State(initialValue: Set(suggestions.filter { !$0.generic }.flatMap { group in group.members.map { Self.key(group, $0) } }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up projects from your activity").font(.title3.weight(.medium))
            Text("What the last 30 days of unassigned activity were about, grouped by organisation. Each checked item becomes a rule "
                 + "for the project on its row.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if suggestions.isEmpty {
                Text("Nothing left to assign.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section("Projects", detail: nil, suggestions.filter { !$0.generic })
                        section("Not projects", detail: "Search, mail, social media and the like. Left unchecked; check one to track it as a project.",
                                suggestions.filter(\.generic))
                    }
                    .padding(3)
                }
                .frame(maxHeight: 420)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                let summary = ProjectSuggestionLogic.summary(choices, projects: projects, rules: rules)
                Button(ProjectSuggestionLogic.buttonTitle(projects: summary.projects, rules: summary.rules), action: create)
                    .keyboardShortcut(.defaultAction).disabled(summary.rules == 0)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    @ViewBuilder
    private func section(_ title: String, detail: String?, _ items: [SetupSuggestion]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ group: SetupSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: groupBinding(group)) { Text(title(group)).lineLimit(1).truncationMode(.middle) }
                Button { toggle(expanded: group.id) } label: {
                    Image(systemName: expanded.contains(group.id) ? "chevron.down" : "chevron.right").font(.caption2)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Show what is in this group")
                Spacer(minLength: 6)
                Text(ActivityLogic.hoursText(group.seconds)).foregroundStyle(.secondary).monospacedDigit()
                nameField(group)
            }
            if !group.samples.isEmpty {
                Text(group.samples.joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 22)
            }
            if expanded.contains(group.id) {
                ForEach(group.members) { member in
                    HStack {
                        Toggle(isOn: memberBinding(group, member)) {
                            Text("\(member.pattern)  \(Text(member.field.label.lowercased()).foregroundStyle(.tertiary))")
                        }
                        Spacer()
                        Text(ActivityLogic.hoursText(member.seconds)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption).padding(.leading, 22)
                }
            }
        }
        .font(.callout)
    }

    private func nameField(_ group: SetupSuggestion) -> some View {
        let name = names[group.id] ?? ""
        let existing = projects.contains { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        return HStack(spacing: 2) {
            Text(existing ? "Add to" : "New").font(.caption).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            TextField("Project", text: Binding(get: { names[group.id] ?? "" }, set: { names[group.id] = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 140)
            Menu {
                ForEach(projects) { project in Button(project.name) { names[group.id] = project.name } }
            } label: { Image(systemName: "chevron.up.chevron.down") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(projects.isEmpty).help("Pick an existing project")
        }
    }

    private func title(_ group: SetupSuggestion) -> String {
        let shown = group.members.prefix(2).map(\.pattern).joined(separator: ", ")
        return group.members.count > 2 ? "\(shown) +\(group.members.count - 2)" : shown
    }

    private static func key(_ group: SetupSuggestion, _ member: SetupMember) -> String { "\(group.id)|\(member.id)" }

    private func groupBinding(_ group: SetupSuggestion) -> Binding<Bool> {
        Binding(get: { group.members.contains { selected.contains(Self.key(group, $0)) } },
                set: { on in for member in group.members { if on { selected.insert(Self.key(group, member)) } else { selected.remove(Self.key(group, member)) } } })
    }

    private func memberBinding(_ group: SetupSuggestion, _ member: SetupMember) -> Binding<Bool> {
        Binding(get: { selected.contains(Self.key(group, member)) },
                set: { if $0 { selected.insert(Self.key(group, member)) } else { selected.remove(Self.key(group, member)) } })
    }

    private func toggle(expanded id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private var choices: [SetupChoice] {
        suggestions.flatMap { group in
            group.members.filter { selected.contains(Self.key(group, $0)) }
                .map { SetupChoice(field: $0.field, pattern: $0.pattern, name: names[group.id] ?? "") }
        }
    }

    private func create() {
        do { try store.createProjects(choices) } catch { NSAlert(error: error).runModal() }
        done()
    }
}
