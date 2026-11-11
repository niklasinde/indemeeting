import AppKit
import SwiftUI

/// The workspaces, kept in a file the MCP server reads too, with the moves the user made.
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var file: WorkspaceFile
    let instructions: WorkspaceInstructionFiles
    private let url: URL?

    /// `url` nil keeps the workspaces in memory only, for previews.
    init(url: URL? = AppPaths.workspaceFile, file: WorkspaceFile? = nil, instructions: WorkspaceInstructionFiles = WorkspaceInstructionFiles()) {
        self.url = url
        self.instructions = instructions
        self.file = file ?? Workspaces.decode(url.flatMap { try? Data(contentsOf: $0) })
        if url != nil, file == nil { save() }
    }

    var workspaces: [Workspace] { file.workspaces }

    func workspace(_ id: String?) -> Workspace? { Workspaces.workspace(id, in: workspaces) }

    func assigned(_ state: AgentState) -> String { Workspaces.assigned(state, in: file) }

    func update(_ workspace: Workspace) {
        guard let index = file.workspaces.firstIndex(where: { $0.id == workspace.id }), file.workspaces[index] != workspace else { return }
        file.workspaces[index] = workspace
        save()
    }

    /// Moves an agent to a workspace, or back to the one the rules give it when `id` is nil.
    func move(_ key: String, to id: String?) {
        file.overrides[key] = id
        save()
    }

    func mainPrompt(for id: String) -> String {
        guard let workspace = workspace(id) else { return AgentLogic.mainBasePrompt }
        return instructions.prompt(for: workspace, others: workspaces.filter { $0.id != workspace.id })
    }

    private func save() {
        AgentStateWriter.shared.changed()
        guard let url else { return }
        let data = Workspaces.encode(file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Each Main's saved session and folder, and the move of the old single Main under the default workspace.
@MainActor
enum WorkspaceDefaults {
    private static var defaults: UserDefaults { AgentModel.defaults }

    static func session(_ id: String) -> String? { (defaults.dictionary(forKey: Workspaces.mainSessionsKey) as? [String: String])?[id] }

    static func setSession(_ session: String?, for id: String) { set(session, for: id, key: Workspaces.mainSessionsKey) }

    static func folder(_ id: String) -> String? { (defaults.dictionary(forKey: Workspaces.mainFoldersKey) as? [String: String])?[id] }

    static func setFolder(_ folder: String, for id: String) { set(folder, for: id, key: Workspaces.mainFoldersKey) }

    private static func set(_ value: String?, for id: String, key: String) {
        var saved = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        saved[id] = value
        defaults.set(saved, forKey: key)
    }

    /// Moves what the single Main saved (its session, folder, history, permission and Chrome choices) to the default
    /// workspace's Main; safe to run on every launch.
    static func migrate() {
        let moved = Workspaces.migratedMain(sessions: defaults.dictionary(forKey: Workspaces.mainSessionsKey) as? [String: String] ?? [:],
                                            folders: defaults.dictionary(forKey: Workspaces.mainFoldersKey) as? [String: String] ?? [:],
                                            session: defaults.string(forKey: AgentLogic.legacyMainSessionKey),
                                            folder: defaults.string(forKey: AgentLogic.legacyMainFolderKey))
        if !moved.sessions.isEmpty { defaults.set(moved.sessions, forKey: Workspaces.mainSessionsKey) }
        if !moved.folders.isEmpty { defaults.set(moved.folders, forKey: Workspaces.mainFoldersKey) }
        defaults.removeObject(forKey: AgentLogic.legacyMainSessionKey)
        defaults.removeObject(forKey: AgentLogic.legacyMainFolderKey)
        let history = AgentSessions.decode(defaults.data(forKey: AgentSessions.historyKey))
        if history[Workspaces.legacyMainKey] != nil {
            defaults.set(AgentSessions.encode(Workspaces.renamedMain(history)), forKey: AgentSessions.historyKey)
        }
        for key in [AgentPermissionMode.storageKey, AgentLogic.chromeKey] {
            if let saved = defaults.dictionary(forKey: key), saved[Workspaces.legacyMainKey] != nil {
                defaults.set(Workspaces.renamedMain(saved), forKey: key)
            }
        }
    }
}
