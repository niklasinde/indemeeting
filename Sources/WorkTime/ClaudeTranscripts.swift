import Foundation

/// Where Claude Code writes the transcript of a session, and which transcript a terminal started just now produced. Pure apart from
/// listing a folder, so it is tested against a temporary folder.
enum ClaudeTranscripts {
    /// Replaced by the debug preview, which keeps its transcripts in a scratch folder.
    static var projectsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)

    /// Claude Code's name for a working folder: every character that is not an ASCII letter or digit becomes "-". So
    /// `/Users/me/git/app` is `-Users-me-git-app`, `Application Support` is `Application-Support` and `.claude` is `-claude`.
    static func folderName(cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func folder(cwd: String, root: URL = projectsFolder) -> URL {
        root.appendingPathComponent(folderName(cwd: cwd), isDirectory: true)
    }

    static func isSessionID(_ text: String) -> Bool {
        text.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }

    /// The transcript file of a session; nil when the id is not a UUID, so nothing else in the folder can be named by a stored value.
    static func transcript(id: String, cwd: String, root: URL = projectsFolder) -> URL? {
        guard isSessionID(id) else { return nil }
        return folder(cwd: cwd, root: root).appendingPathComponent(id + ".jsonl")
    }

    static func exists(id: String, cwd: String, root: URL = projectsFolder, fileManager: FileManager = .default) -> Bool {
        transcript(id: id, cwd: cwd, root: root).map { fileManager.fileExists(atPath: $0.path) } ?? false
    }

    /// The session a terminal started at `started` produced in its folder: the newest transcript created since then whose text
    /// contains `marker`, the pull request's address that its prompt carries. Nil until such a transcript exists.
    static func newestSession(in folder: URL, since started: Date, containing marker: String, fileManager: FileManager = .default) -> String? {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { file -> (id: String, created: Date, file: URL)? in
            let id = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "jsonl", isSessionID(id), let values = try? file.resourceValues(forKeys: Set(keys)),
                  let created = values.creationDate ?? values.contentModificationDate, created >= started else { return nil }
            return (id, created, file)
        }
        .sorted { $0.created > $1.created }
        .first { (try? String(contentsOf: $0.file, encoding: .utf8))?.contains(marker) == true }?.id
    }

    /// The custom title the user set, else the first line they wrote, as the activity view shows them.
    static func title(in folder: URL, id: String) -> String? {
        let url = folder.appendingPathComponent(id + ".jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ActivityLogic.claudeSession(id: id, jsonl: text)?.title
    }
}
