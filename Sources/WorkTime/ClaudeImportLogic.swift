import Foundation

/// A Claude Code session on disk, as the Import session sheet lists it.
struct ClaudeSessionSummary: Equatable, Identifiable, Sendable {
    let id: String
    var cwd: String
    var prompt: String?
    var lastActivity: Date
    var size: Int64

    var title: String { prompt ?? ClaudeImport.untitled }
}

/// What the first lines of a session's transcript say: where it ran, the first prompt the user typed and when it began.
struct ClaudeSessionHeader: Equatable {
    var cwd: String?
    var prompt: String?
    var started: Date?
}

/// A Claude Code session continued in WorkTime. The original transcript is never appended to: the first prompt forks it,
/// and `forked` is the session that fork made.
struct ClaudeImportRecord: Codable, Equatable {
    var original: String
    var date: Date
    var forked: String?
}

/// Continuing a Claude Code session in WorkTime: reading its transcript's header, listing sessions, choosing the agent it
/// goes to and keeping the original transcript untouched.
enum ClaudeImport {
    static let untitled = "Imported session"
    static let nameLimit = 60
    static let listLimit = 50
    static let headBytes = 256 * 1024
    static let recordsKey = "agentImportedSessions"

    struct Link: Equatable {
        let session: String
        let cwd: String?
    }

    /// `worktime://agent?session=<uuid>[&cwd=<absolute path>]`.
    static func parseLink(_ text: String) -> Link? {
        guard let link = URLComponents(string: text), AppURL.accepts(scheme: link.scheme), link.host?.lowercased() == "agent",
              link.user == nil, link.password == nil, link.port == nil, link.fragment == nil, link.percentEncodedPath.isEmpty,
              let query = link.queryItems, !query.isEmpty, Set(query.map(\.name)).count == query.count,
              query.allSatisfy({ ["session", "cwd"].contains($0.name) }),
              let session = query.first(where: { $0.name == "session" })?.value, ClaudeTranscripts.isSessionID(session) else { return nil }
        let cwd = query.first { $0.name == "cwd" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        if let cwd, !cwd.hasPrefix("/") { return nil }
        return Link(session: session.lowercased(), cwd: cwd)
    }

    static func link(session: String, cwd: String?) -> String {
        "\(AppURL.scheme)://agent?session=\(session)" + (cwd.map { "&cwd=" + GitHubClaude.encode($0) } ?? "")
    }

    /// The working folder, the first prompt the user typed (one line, without reminders and tags) and the first timestamp.
    static func header(jsonl: String) -> ClaudeSessionHeader {
        var header = ClaudeSessionHeader()
        for line in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if header.cwd == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty { header.cwd = cwd }
            if header.started == nil, let time = object["timestamp"] as? String {
                header.started = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time)
            }
            if header.prompt == nil, object["type"] as? String == "user", object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
               let message = object["message"] as? [String: Any],
               let text = ActivityLogic.userText(message["content"]).flatMap({ ActivityLogic.promptExcerpt($0, limit: nameLimit) }) {
                header.prompt = text
            }
            if header.cwd != nil, header.prompt != nil, header.started != nil { break }
        }
        return header
    }

    /// The text before the last line break, so a line cut off by reading only the start of a file is left out.
    static func completeLines(_ data: Data) -> String {
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return "" }
        return String(decoding: data[..<last], as: UTF8.self)
    }

    static func agentName(prompt: String?) -> String {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return untitled }
        return ActivityLogic.truncate(prompt, to: nameLimit)
    }

    /// Transcript files that no agent has, newest first.
    static func candidates(_ files: [(id: String, modified: Date)], excluding known: Set<String>, limit: Int = listLimit) -> [(id: String, modified: Date)] {
        AgentSessions.others(files, excluding: known, limit: limit)
    }

    /// The sessions whose folder or first prompt contains every word typed, ignoring case.
    static func filter(_ sessions: [ClaudeSessionSummary], query: String) -> [ClaudeSessionSummary] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return sessions }
        return sessions.filter { session in
            let text = (session.cwd + " " + (session.prompt ?? "")).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    enum Target: Equatable {
        case pullRequest(String)
        case topic(name: String)
    }

    /// The open pull request in one of the checkout's GitHub remotes whose head is its branch (when the head is cached), else
    /// the one titled with the branch's ticket; a topic named from the prompt when there is none.
    static func target(branch: String?, remotes: [String], prs: [GitHubPR], head: (String) -> String?, prompt: String?) -> Target {
        guard let branch, !remotes.isEmpty else { return .topic(name: agentName(prompt: prompt)) }
        let open = prs.filter { $0.state == .open && remotes.contains($0.repo.lowercased()) }.sorted { $0.updated > $1.updated }
        let ticket = ActivityLogic.ticket(in: branch)
        let pr = open.first { head($0.url) == branch } ?? ticket.flatMap { ticket in open.first { $0.ticket == ticket && head($0.url) == nil } }
        return pr.map { .pullRequest($0.url) } ?? .topic(name: agentName(prompt: prompt))
    }

    /// The checkout holding `folder` (it or a folder above it), its branch and its GitHub remotes. Nothing is run; files are read.
    static func repository(at folder: String, fileManager: FileManager = .default) -> (branch: String?, remotes: [String])? {
        var url = URL(fileURLWithPath: folder).standardizedFileURL
        while url.path != "/" {
            if let git = BranchIndex.gitFolder(of: url, fileManager: fileManager) {
                let config = try? String(contentsOf: BranchIndex.commonFolder(git, fileManager: fileManager).appendingPathComponent("config"), encoding: .utf8)
                return (ActivityLogic.branch(ofRepository: url, fileManager: fileManager), GitHubClaude.remotes(inGitConfig: config ?? ""))
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: Forking

    static func record(for id: String?, in records: [ClaudeImportRecord]) -> ClaudeImportRecord? {
        guard let id else { return nil }
        return records.first { $0.original == id || $0.forked == id }
    }

    /// Continuing an imported original always forks it, so its transcript is never written to.
    static func shouldFork(_ id: String?, records: [ClaudeImportRecord]) -> Bool {
        guard let id else { return false }
        return records.contains { $0.original == id }
    }

    static func adding(original: String, date: Date, to records: [ClaudeImportRecord]) -> [ClaudeImportRecord] {
        records.contains { $0.original == original } ? records : records + [ClaudeImportRecord(original: original, date: date)]
    }

    static func forked(_ original: String, into new: String, in records: [ClaudeImportRecord]) -> [ClaudeImportRecord] {
        records.map { record in
            var record = record
            if record.original == original, original != new { record.forked = new }
            return record
        }
    }

    static func note(_ record: ClaudeImportRecord) -> String {
        "Continued from a Claude Code session \u{00B7} " + record.date.formatted(date: .abbreviated, time: .shortened)
    }

    static func decode(_ data: Data?) -> [ClaudeImportRecord] {
        data.flatMap { AgentInbox.decode([ClaudeImportRecord].self, from: $0) } ?? []
    }

    static func encode(_ records: [ClaudeImportRecord]) -> Data { AgentInbox.encode(records) }

    /// Every session an agent has: its history, the ones saved as current and the imported originals with their forks.
    static func knownIDs(history: [String: [AgentSessionEntry]], saved: [String: String], records: [ClaudeImportRecord]) -> Set<String> {
        Set(history.values.joined().map(\.id)).union(saved.values).union(records.flatMap { [$0.original, $0.forked].compactMap { $0 } })
    }

    /// The agent that already has the session, or its fork.
    static func owner(of id: String, history: [String: [AgentSessionEntry]], saved: [String: String], records: [ClaudeImportRecord]) -> String? {
        let ids = Set([id, records.first { $0.original == id }?.forked].compactMap { $0 })
        if let key = saved.sorted(by: { $0.key < $1.key }).first(where: { ids.contains($0.value) })?.key { return key }
        return history.keys.sorted().first { key in history[key]?.contains { ids.contains($0.id) } == true }
    }

    // MARK: Claude Code

    /// The flags that continue the session in the Claude Code CLI.
    static func resumeFlags(session: String) -> [String] { ["--resume", session] }
}

/// Reading Claude Code's transcripts for the import: only reads, never writes.
enum ClaudeSessionFiles {
    static func summary(_ url: URL, fileManager: FileManager = .default) -> ClaudeSessionSummary? {
        let id = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "jsonl", ClaudeTranscripts.isSessionID(id),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: ClaudeImport.headBytes)) ?? Data()
        let header = ClaudeImport.header(jsonl: data.count < ClaudeImport.headBytes ? String(decoding: data, as: UTF8.self) : ClaudeImport.completeLines(data))
        guard let cwd = header.cwd else { return nil }
        return ClaudeSessionSummary(id: id.lowercased(), cwd: cwd, prompt: header.prompt, lastActivity: values.contentModificationDate ?? .distantPast,
                                    size: Int64(values.fileSize ?? 0))
    }

    /// The newest sessions across every project folder that no agent has, those without a prompt or folder left out.
    static func recent(root: URL = ClaudeTranscripts.projectsFolder, excluding known: Set<String>, limit: Int = ClaudeImport.listLimit,
                       fileManager: FileManager = .default) -> [ClaudeSessionSummary] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var urls: [String: URL] = [:]
        let files = folders.flatMap { folder in
            ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []).filter { $0.pathExtension == "jsonl" }
        }.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            urls[id] = url
            return (id: id, modified: (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        var found: [ClaudeSessionSummary] = []
        for file in ClaudeImport.candidates(files, excluding: known, limit: files.count) where found.count < limit {
            if let url = urls[file.id], let summary = summary(url, fileManager: fileManager), summary.prompt != nil { found.append(summary) }
        }
        return found
    }

    static func locate(_ id: String, cwd: String?, root: URL = ClaudeTranscripts.projectsFolder) -> ClaudeSessionSummary? {
        guard let url = AgentTranscript.url(sessionID: id, cwd: cwd, root: root), var found = summary(url) else { return nil }
        found.cwd = folder(recorded: found.cwd, hint: cwd, project: url.deletingLastPathComponent().lastPathComponent)
        return found
    }

    /// The folder to resume in: Claude Code finds a session by its folder, so a session that moved folders resumes from the one
    /// whose project folder holds its transcript.
    static func folder(recorded: String, hint: String?, project: String) -> String {
        [hint, recorded].compactMap { $0 }.first { ClaudeTranscripts.folderName(cwd: $0) == project } ?? hint ?? recorded
    }
}
