import AppKit
import SwiftUI

extension Workspace {
    var tint: Color {
        switch color {
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red": return .red
        case "pink": return .pink
        case "teal": return .teal
        case "gray": return .gray
        default: return .blue
        }
    }
}

/// A Main's header: its workspace, and a note when it has instructions of its own, which open MAIN.md.
struct MainWorkspaceBadge: View {
    let workspace: String?
    @ObservedObject private var store = WorkspaceStore.shared

    var body: some View {
        if let workspace = store.workspace(workspace) {
            Label(workspace.name, systemImage: workspace.symbol).font(.callout).foregroundStyle(workspace.tint).lineLimit(1)
                .help("The \(workspace.name) workspace: Main sees only its pull requests, agents and messages")
            if store.instructions.isCustom(workspace) {
                Button { NSWorkspace.shared.open(store.instructions.ensure(workspace)) } label: {
                    Label("Instructions", systemImage: "doc.text").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Main follows custom instructions for \(workspace.name) (MAIN.md). Click to open the file.")
            }
        }
    }
}

/// Settings → Agent: each workspace's name, roots and filter, and the instructions its Main follows.
struct WorkspacesSettings: View {
    @ObservedObject private var store = WorkspaceStore.shared

    var body: some View {
        ForEach(store.workspaces) { WorkspaceEditor(workspace: $0, store: store) }
    }
}

private struct WorkspaceEditor: View {
    let workspace: Workspace
    @ObservedObject var store: WorkspaceStore
    @State private var roots: String
    @State private var owners: String
    @State private var jira: String
    @State private var instructions = ""
    @State private var loaded = false
    @State private var saving: Task<Void, Never>?

    init(workspace: Workspace, store: WorkspaceStore) {
        self.workspace = workspace
        self.store = store
        _roots = State(initialValue: workspace.roots.joined(separator: ", "))
        _owners = State(initialValue: workspace.githubOwners.joined(separator: ", "))
        _jira = State(initialValue: workspace.jiraProjects.joined(separator: ", "))
    }

    var body: some View {
        SettingsSection("Workspace: \(workspace.name)", footer: "An agent belongs to the workspace whose folder holds it, else the one with its "
                        + "GitHub owner or Jira project, else Work. Move one by hand from its context menu in the agents list.") {
            field("Name", text: Binding { workspace.name } set: { value in change { $0.name = value } })
            Divider().padding(.leading, 14)
            field("Folders", text: $roots, prompt: "~/git/work, ~/git/more") { $0.roots = list($1) }
            Divider().padding(.leading, 14)
            field("GitHub owners", text: $owners, prompt: "an organisation or user") { $0.githubOwners = list($1) }
            Divider().padding(.leading, 14)
            field("Jira projects", text: $jira, prompt: "none") { $0.jiraProjects = list($1).map { $0.uppercased() } }
            Divider().padding(.leading, 14)
            SettingsRow("Slack", detail: workspace.slack.map { "Reads the \($0) workspace" } ?? "Main leaves Slack out") {
                Toggle("", isOn: Binding { workspace.slack != nil } set: { on in change { $0.slack = on ? $0.name : nil } }).labelsHidden()
            }
            Divider().padding(.leading, 14)
            instructionsRow
            Divider().padding(.leading, 14)
            extraFiles
        }
        .onAppear(perform: load)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String = "", apply: ((inout Workspace, String) -> Void)? = nil) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            TextField(title, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.roundedBorder)
                .onChange(of: text.wrappedValue) { _, value in
                    if let apply { change { apply(&$0, value) } }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func change(_ edit: (inout Workspace) -> Void) {
        var updated = store.workspace(workspace.id) ?? workspace
        edit(&updated)
        store.update(updated)
    }

    private var instructionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Instructions")
                Text("MAIN.md, read at every prompt").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open in Editor") { NSWorkspace.shared.open(store.instructions.ensure(workspace)) }
                Button("Reset to Default") {
                    saving?.cancel()
                    store.instructions.reset(workspace)
                    instructions = store.instructions.read(workspace) ?? ""
                }
            }
            TextEditor(text: $instructions)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                .onChange(of: instructions) { _, text in autosave(text) }
            Text("Added to Main\u{2019}s prompt after what it knows about this workspace, up to \(WorkspaceInstructions.limit) characters.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var extraFiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Also include")
                Text("files added after MAIN.md, skipped when missing").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Add File\u{2026}", action: addFile)
            }
            ForEach(workspace.extraFiles, id: \.self) { path in
                HStack {
                    Text(path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Remove") { change { $0.extraFiles.removeAll { $0 == path } } }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        change { if !$0.extraFiles.contains(path) { $0.extraFiles.append(path) } }
    }

    private func load() {
        guard !loaded else { return }
        instructions = store.instructions.read(workspace) ?? ""
        DispatchQueue.main.async { loaded = true }
    }

    private func autosave(_ text: String) {
        guard loaded else { return }
        saving?.cancel()
        let workspace = workspace, files = store.instructions
        saving = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            files.write(text, for: workspace)
        }
    }
}
