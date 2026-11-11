import AppKit
import SwiftUI

/// Each workspace's assistants: their role files, noticed when they change, and the agents made for them the first time they are
/// shown. Like the pull requests' and topics' agents, their models live for this run of the app.
@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()

    @Published private(set) var roles: [String: [AssistantRole]] = [:]
    @Published private(set) var models: [String: AgentModel] = [:]
    private(set) var files: AssistantFiles
    private let workspaces: @MainActor () -> [Workspace]
    private var signatures: [String: String] = [:]
    private var recent: [String] = []
    private var timer: Timer?

    init(files: AssistantFiles = AssistantFiles(), workspaces: @escaping @MainActor () -> [Workspace] = { WorkspaceStore.shared.workspaces }) {
        self.files = files
        self.workspaces = workspaces
    }

    /// Writes the templates for a workspace's first use, reads the roles and then watches the folders.
    func start() {
        refresh(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var all: [AssistantEntry] {
        workspaces().flatMap { entries($0.id) }
    }

    func entries(_ workspace: String) -> [AssistantEntry] {
        (roles[workspace] ?? []).map { AssistantEntry(workspace: workspace, role: $0) }
    }

    func entry(_ key: String) -> AssistantEntry? {
        Assistants.parse(key: key).flatMap { parsed in entries(parsed.workspace).first { $0.role.slug == parsed.slug } }
    }

    /// The role as its file says now.
    func role(of entry: AssistantEntry) -> AssistantRole? { files.role(entry.workspace, slug: entry.role.slug) }

    func folder(_ entry: AssistantEntry) -> String {
        files.workFolder(entry.role, workspace: WorkspaceStore.shared.workspace(entry.workspace) ?? Workspaces.defaults[0])
    }

    /// Rereads the folders whose files changed, or all of them.
    func refresh(force: Bool = false) {
        var changed = false
        for workspace in workspaces() {
            files.ensureDefaults(workspace.id)
            let signature = files.signature(workspace.id)
            guard force || signatures[workspace.id] != signature else { continue }
            signatures[workspace.id] = signature
            roles[workspace.id] = files.list(workspace.id)
            changed = true
        }
        guard changed else { return }
        for key in models.keys {
            if let entry = entry(key) { models[key]?.update(assistant: entry) } else { unload(key) }
        }
        AgentStateWriter.shared.changed()
    }

    // MARK: Agents

    /// The assistant's agent, made in its folder (continuing its saved session) when it is not loaded yet.
    @discardableResult
    func load(_ entry: AssistantEntry) -> AgentModel {
        let folder = folder(entry)
        let model = models[entry.key] ?? AgentModel(folder: folder)
        if models[entry.key] == nil {
            if entry.role.folder == Assistants.ownFolder { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            model.open(assistant: entry, folder: folder)
            models[entry.key] = model
        }
        recent.removeAll { $0 == entry.key }
        recent.insert(entry.key, at: 0)
        for old in recent.dropFirst(PRAgents.runningLimit) where models[old]?.busy == false { models[old]?.stopClient() }
        return model
    }

    func deliver(_ request: AgentInbox.Request) -> AgentInbox.Reply {
        guard let entry = entry(request.agent) else {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: "No assistant \(request.agent) in WorkTime.")
        }
        guard entry.role.isUsable else {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: AssistantError.broken(entry.role.name, entry.role.problems.first?.text ?? "").message)
        }
        return PRAgents.deliver(request, to: load(entry), title: entry.role.name)
    }

    func stopAll() { models.values.forEach { $0.stopClient() } }

    private func unload(_ key: String) {
        models[key]?.stopClient()
        models[key] = nil
        recent.removeAll { $0 == key }
        if AgentHub.shared.selected == key { AgentHub.shared.selected = AgentHub.shared.currentMainKey }
    }

    // MARK: Files

    @discardableResult
    func create(workspace: String, template: AssistantTemplate) -> String {
        let slug = files.create(workspace, name: template.role.name, text: template.text)
        refresh(force: true)
        return Assistants.key(workspace: workspace, slug: slug)
    }

    @discardableResult
    func create(workspace: String, name: String) -> String {
        let slug = files.blank(workspace, name: name)
        refresh(force: true)
        return Assistants.key(workspace: workspace, slug: slug)
    }

    func duplicate(_ entry: AssistantEntry) -> String? {
        let slug = files.duplicate(entry.workspace, slug: entry.role.slug)
        refresh(force: true)
        return slug.map { Assistants.key(workspace: entry.workspace, slug: $0) }
    }

    func rename(_ entry: AssistantEntry, to name: String) {
        files.rename(entry.workspace, slug: entry.role.slug, to: name)
        refresh(force: true)
    }

    /// Removes the role's file; its sessions and its own folder stay.
    func delete(_ entry: AssistantEntry) {
        unload(entry.key)
        files.remove(entry.workspace, slug: entry.role.slug)
        refresh(force: true)
    }

    func save(_ text: String, for entry: AssistantEntry) {
        files.write(text, workspace: entry.workspace, slug: entry.role.slug)
        refresh(force: true)
    }

    func reset(_ entry: AssistantEntry) {
        files.reset(entry.workspace, slug: entry.role.slug)
        refresh(force: true)
    }

    func reveal(_ entry: AssistantEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([files.url(entry.workspace, slug: entry.role.slug)])
    }

    /// The assistant's system prompt, made from its file and the workspace's MAIN.md as they are now.
    func systemPrompt(_ role: AssistantRole, workspace: String, folder: String) -> String {
        WorkspaceStore.shared.assistantPrompt(role, workspace: workspace, folder: folder)
    }

    #if DEBUG
    /// Points the store at a folder of its own, for the previews.
    func useSample(files: AssistantFiles) {
        models.values.forEach { $0.stopClient() }
        self.files = files
        models = [:]
        roles = [:]
        signatures = [:]
        refresh(force: true)
    }
    #endif
}
