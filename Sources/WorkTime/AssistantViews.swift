import AppKit
import SwiftUI

/// The role's SF Symbol, or a spark when the name is not one.
struct AssistantIcon: View {
    let name: String
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? Assistants.defaultIcon : name)
            .font(.system(size: size)).foregroundStyle(.secondary).frame(width: size * 1.5)
    }
}

/// An assistant's agent on the Main page, loaded the first time it is picked.
struct AgentAssistantPage: View {
    let key: String
    @Binding var listHidden: Bool
    @ObservedObject private var store = AssistantStore.shared

    var body: some View {
        if let model = store.models[key] {
            AgentView(model: model, listHidden: $listHidden)
        } else if store.entry(key) == nil {
            Text("This assistant\u{2019}s file is gone.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: key) { if let entry = store.entry(key) { store.load(entry) } }
        }
    }
}

/// The assistant's name in its header, with Edit instructions beside it.
struct AgentAssistantHeader: View {
    let entry: AssistantEntry
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @State private var editing = false

    var body: some View {
        Label { Text(entry.role.name).lineLimit(1) } icon: { AssistantIcon(name: entry.role.icon, size: 14) }
            .font(.system(size: 15, weight: .medium))
        if let workspace = workspaces.workspace(entry.workspace) {
            Label(workspace.name, systemImage: workspace.symbol).font(.callout).foregroundStyle(workspace.tint).lineLimit(1)
                .help("An assistant of the \(workspace.name) workspace\u{2019}s Main")
        }
        if let problem = entry.role.problems.first {
            Label("Needs fixing", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).lineLimit(1)
                .help(problem.text)
        }
        Button { editing = true } label: { Label("Edit instructions", systemImage: "doc.text") }
            .help("Edit the Markdown file this assistant follows; changes apply at its next prompt")
            .sheet(isPresented: $editing) { AssistantEditorSheet(entry: entry) { editing = false } }
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AssistantStore.shared.folder(entry))]) } label: { Image(systemName: "folder") }
            .buttonStyle(.borderless)
            .help("The assistant\u{2019}s folder: \((AssistantStore.shared.folder(entry) as NSString).abbreviatingWithTildeInPath)")
    }
}

// MARK: Actions

enum AssistantAction: Identifiable {
    case edit(AssistantEntry)
    case rename(AssistantEntry)
    case blank(String)

    var id: String {
        switch self {
        case .edit(let entry): return "edit:" + entry.key
        case .rename(let entry): return "rename:" + entry.key
        case .blank(let workspace): return "blank:" + workspace
        }
    }
}

/// The sheets and the confirmation behind the assistant menus, wherever they are shown.
struct AssistantSheets: ViewModifier {
    @Binding var action: AssistantAction?
    @Binding var deleting: AssistantEntry?
    var select: (String) -> Void = { _ in }
    @ObservedObject private var store = AssistantStore.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $action) { current in
                switch current {
                case .edit(let entry):
                    AssistantEditorSheet(entry: entry) { action = nil }
                case .rename(let entry):
                    AssistantNameSheet(title: "Rename Assistant", initial: entry.role.name, confirm: "Rename") { name in
                        if let name { store.rename(entry, to: name) }
                        action = nil
                    }
                case .blank(let workspace):
                    AssistantNameSheet(title: "New Assistant", initial: "", confirm: "Create") { name in
                        if let name { select(store.create(workspace: workspace, name: name)) }
                        action = nil
                    }
                }
            }
            .confirmationDialog("Delete \u{201C}\(deleting?.role.name ?? "")\u{201D}?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
                Button("Delete Assistant", role: .destructive) {
                    if let deleting { store.delete(deleting) }
                }
            } message: {
                Text("Removes its instructions file. Its sessions and its folder are kept.")
            }
    }
}

extension View {
    func assistantSheets(action: Binding<AssistantAction?>, deleting: Binding<AssistantEntry?>, select: @escaping (String) -> Void = { _ in }) -> some View {
        modifier(AssistantSheets(action: action, deleting: deleting, select: select))
    }
}

/// Edit, rename, duplicate and delete for one assistant.
struct AssistantMenuItems: View {
    let entry: AssistantEntry
    @Binding var action: AssistantAction?
    @Binding var deleting: AssistantEntry?
    var select: (String) -> Void = { _ in }

    var body: some View {
        Button("Edit Instructions\u{2026}") { action = .edit(entry) }
        Button("Reveal in Finder") { AssistantStore.shared.reveal(entry) }
        Divider()
        Button("Rename\u{2026}") { action = .rename(entry) }
        Button("Duplicate") { AssistantStore.shared.duplicate(entry).map(select) }
        Divider()
        Button("Delete\u{2026}", role: .destructive) { deleting = entry }
    }
}

/// New Assistant: from one of the built-in templates, or blank.
struct NewAssistantMenuItems: View {
    let workspace: String
    @Binding var action: AssistantAction?
    var select: (String) -> Void = { _ in }

    var body: some View {
        Section("From a template") {
            ForEach(Assistants.templates, id: \.slug) { template in
                Button(template.role.name) { select(AssistantStore.shared.create(workspace: workspace, template: template)) }
            }
        }
        Divider()
        Button("Blank Assistant\u{2026}") { action = .blank(workspace) }
    }
}

struct AssistantNameSheet: View {
    let title: String
    @State var name: String
    let confirm: String
    let done: (String?) -> Void

    init(title: String, initial: String, confirm: String, done: @escaping (String?) -> Void) {
        self.title = title
        _name = State(initialValue: initial)
        self.confirm = confirm
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name, prompt: Text("Release manager")).textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(confirm, action: submit).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func submit() {
        if !trimmed.isEmpty { done(trimmed) }
    }
}

// MARK: Editor

/// The Markdown file of an assistant: edited as text, saved as you type, with its front matter checked and the instructions previewed.
struct AssistantEditorSheet: View {
    let entry: AssistantEntry
    let done: () -> Void
    @ObservedObject private var store = AssistantStore.shared
    @State private var text = ""
    @State private var written = ""
    @State private var loaded = false
    @State private var previewing = false
    @State private var resetting = false
    @State private var saving: Task<Void, Never>?

    var body: some View {
        let role = Assistants.parse(slug: entry.role.slug, text: text)
        VStack(spacing: 0) {
            header(role)
            Divider()
            if previewing { preview(role) } else { editor }
            if !role.problems.isEmpty { problems(role) }
            Divider()
            footer
        }
        .frame(width: 760, height: 620)
        .onAppear(perform: load)
        .onReceive(store.$roles) { _ in reload() }
        .confirmationDialog("Reset \u{201C}\(entry.role.name)\u{201D} to the template?", isPresented: $resetting) {
            Button("Reset to Template", role: .destructive) {
                saving?.cancel()
                store.reset(entry)
                reload(force: true)
            }
        } message: {
            Text("Replaces everything in the file with the built-in version.")
        }
    }

    private func header(_ role: AssistantRole) -> some View {
        HStack(spacing: 10) {
            AssistantIcon(name: role.icon, size: 15)
            Text(role.name).font(.headline).lineLimit(1)
            Text("\(entry.role.slug).md").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Picker("View", selection: $previewing) {
                Text("Edit").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Button { store.reveal(entry) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            if Assistants.template(entry.role.slug) != nil {
                Button { resetting = true } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset to the built-in template")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: text) { _, value in autosave(value) }
    }

    private func preview(_ role: AssistantRole) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(role.summary).foregroundStyle(.secondary)
                Text(facts(role)).font(.caption).foregroundStyle(.tertiary)
                Divider()
                AnswerText(text: role.body.isEmpty ? "No instructions yet." : role.body)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func facts(_ role: AssistantRole) -> String {
        let model = AgentLogic.models.first { $0.id == Assistants.modelID(role.model) }?.name ?? role.model
        return ["Model \(model)", "Permissions \(Assistants.permissionMode(role.permissionMode).title)",
                "Tools " + (role.tools.isEmpty ? "default" : role.tools.joined(separator: ", ")),
                "Folder " + (role.folder ?? "workspace")].joined(separator: " \u{00B7} ")
    }

    private func problems(_ role: AssistantRole) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(role.problems.enumerated()), id: \.offset) { _, problem in
                Label(problem.text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.06))
    }

    private var footer: some View {
        HStack {
            let words = Assistants.wordCount(text)
            Text("\(words) word\(words == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            Text(text == written ? "Saved" : "Saving\u{2026}").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Text("Read at every prompt").font(.caption).foregroundStyle(.tertiary)
            Button("Done") { flush(); done() }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func load() {
        guard !loaded else { return }
        text = store.files.text(entry.workspace, slug: entry.role.slug) ?? ""
        written = text
        DispatchQueue.main.async { loaded = true }
    }

    /// Takes in an edit made outside the app, unless there is typing that is not saved yet.
    private func reload(force: Bool = false) {
        guard loaded, let disk = store.files.text(entry.workspace, slug: entry.role.slug), disk != text, force || text == written else { return }
        text = disk
        written = disk
    }

    private func autosave(_ value: String) {
        guard loaded, value != written else { return }
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        guard loaded, text != written else { return }
        written = text
        store.save(text, for: entry)
    }
}

// MARK: Settings

/// Settings → Agent: a workspace's assistants, each opening the editor.
struct AssistantsSettings: View {
    let workspace: Workspace
    @ObservedObject private var store = AssistantStore.shared
    @State private var action: AssistantAction?
    @State private var deleting: AssistantEntry?

    var body: some View {
        let path = (store.files.folder(workspace.id).path as NSString).abbreviatingWithTildeInPath
        SettingsSection("Assistants: \(workspace.name)", footer: "Role agents under this workspace\u{2019}s Main, each a Markdown file in \(path). Edit them here or "
                        + "in any editor; a change applies at the assistant\u{2019}s next prompt, and Main sees the list at its next one.") {
            let entries = store.entries(workspace.id)
            ForEach(entries) { entry in
                row(entry)
                Divider().padding(.leading, 14)
            }
            HStack {
                Menu {
                    NewAssistantMenuItems(workspace: workspace.id, action: $action) { _ in }
                } label: { Label("New Assistant", systemImage: "plus") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.open(store.files.folder(workspace.id)) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .assistantSheets(action: $action, deleting: $deleting)
    }

    private func row(_ entry: AssistantEntry) -> some View {
        HStack(spacing: 10) {
            AssistantIcon(name: entry.role.icon, size: 14).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.role.name)
                Text(entry.role.problems.first?.text ?? entry.role.summary).font(.caption).lineLimit(2)
                    .foregroundStyle(entry.role.isUsable ? Color.secondary : Color.red)
            }
            Spacer()
            if !entry.role.isUsable {
                Label("Error", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).labelStyle(.titleAndIcon)
            }
            Button("Edit\u{2026}") { action = .edit(entry) }
            Menu { AssistantMenuItems(entry: entry, action: $action, deleting: $deleting) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
