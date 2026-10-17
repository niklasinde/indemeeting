import Foundation

/// Activity blocks, projects and rules, in the meeting database.
extension MeetingStore {
    private static let detailColumns = """
        app_bundle, app_name, window_title, url, repo, branch, ticket, claude_session, claude_title, idle, project_id,
        typed_excerpt, category, ai_description, ai_project_id, claude_focus, claude_prompt, redaction, ai_work, repo_owner
        """
    private static let blockColumns = "id, start, end, " + detailColumns
    /// What a private block loses: everything but the app, the times and the category.
    private static let privateFields = """
        window_title = NULL, url = NULL, repo = NULL, branch = NULL, ticket = NULL, claude_session = NULL, claude_title = NULL,
        typed_excerpt = NULL, ai_description = NULL, claude_focus = NULL, claude_prompt = NULL, repo_owner = NULL
        """

    func blocks(in range: Range<Date>) throws -> [ActivityBlock] {
        try read {
            try db.query("SELECT \(Self.blockColumns) FROM activity_blocks WHERE end > ? AND start < ? ORDER BY start",
                         [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970], Self.block)
        }
    }

    /// Inserts a new block or updates the one with its id; returns the id.
    @discardableResult
    func saveBlock(_ block: ActivityBlock) throws -> Int64 {
        try write(notify: Self.activityDidChange) {
            let key = block.key
            let values: [SQLValue?] = [block.start.timeIntervalSince1970, block.end.timeIntervalSince1970, key.appBundle, key.appName,
                                       key.windowTitle, key.url, key.repo, key.branch, key.ticket,
                                       key.claude.isEmpty ? nil : key.claude.map(\.id).joined(separator: "\n"),
                                       key.claude.isEmpty ? nil : key.claude.map { "\($0.folder)\t\($0.title)" }.joined(separator: "\n"),
                                       key.idle, block.projectID, block.typedExcerpt, block.category?.rawValue, block.aiDescription,
                                       block.aiProjectID, key.claudeFocus, block.claudePrompt, key.redaction?.rawValue, block.aiWork, key.owner]
            if block.id > 0 {
                try db.run("""
                    UPDATE activity_blocks SET start = ?, end = ?, app_bundle = ?, app_name = ?, window_title = ?, url = ?, repo = ?,
                        branch = ?, ticket = ?, claude_session = ?, claude_title = ?, idle = ?, project_id = ?, typed_excerpt = ?,
                        category = ?, ai_description = ?, ai_project_id = ?, claude_focus = ?, claude_prompt = ?, redaction = ?, ai_work = ?, repo_owner = ? WHERE id = ?
                    """, values + [block.id])
                return block.id
            }
            try db.run("""
                INSERT INTO activity_blocks (start, end, app_bundle, app_name, window_title, url, repo, branch, ticket, claude_session,
                                             claude_title, idle, project_id, typed_excerpt, category, ai_description, ai_project_id,
                                             claude_focus, claude_prompt, redaction, ai_work, repo_owner)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values)
            return try db.lastInsertID
        }
    }

    func setProject(ofBlock id: Int64, _ projectID: Int64?) throws {
        try write(notify: Self.activityDidChange) { try db.run("UPDATE activity_blocks SET project_id = ? WHERE id = ?", [projectID, id]) }
    }

    /// Finished, non-idle blocks that have no category yet, oldest first.
    func unclassifiedBlocks(endedBefore date: Date, limit: Int) throws -> [ActivityBlock] {
        try read {
            try db.query("""
                SELECT \(Self.blockColumns) FROM activity_blocks
                WHERE category IS NULL AND idle = 0 AND app_name IS NOT NULL AND end < ? ORDER BY end DESC LIMIT ?
                """, [date.timeIntervalSince1970, limit], Self.block)
        }
    }

    func setClassification(ofBlock id: Int64, _ classification: ActivityAI.Classification) throws {
        try write(notify: Self.activityDidChange) {
            try db.run("UPDATE activity_blocks SET category = ?, ai_description = ?, ai_project_id = ?, ai_work = ? WHERE id = ?",
                       [classification.category.rawValue, classification.description, classification.projectID, classification.work, id])
        }
    }

    /// Applies the rules to the blocks already stored (see `ActivitySettings.review`): blocks outside them are made
    /// private, other or other site, or removed. What a block has already lost is not brought back. Returns how many changed.
    @discardableResult
    func applyRules(_ settings: ActivitySettings, to ids: [Int64]? = nil) throws -> Int {
        if ids?.isEmpty == true { return 0 }
        let only = ids.map { " AND id IN (\(Self.placeholders($0.count)))" } ?? ""
        let blocks = try read {
            try db.query("SELECT \(Self.blockColumns) FROM activity_blocks WHERE idle = 0 AND (redaction IS NULL OR redaction <> ?)\(only)",
                         [ActivityRedaction.other.rawValue as SQLValue] + (ids ?? []).map { $0 as SQLValue }, Self.block)
        }
        var removed: [Int64] = []
        var redacted: [ActivityRedaction: [Int64]] = [:]
        for block in blocks {
            switch settings.review(block) {
            case .keep: break
            case .remove: removed.append(block.id)
            case .redact(let redaction): redacted[redaction, default: []].append(block.id)
            }
        }
        try delete(blockIDs: removed)
        return try redacted.reduce(removed.count) { try $0 + redact(blockIDs: $1.value, as: $1.key) }
    }

    /// Strips the blocks to what `redaction` keeps, unless they already keep less; returns how many changed.
    @discardableResult
    func redact(blockIDs: [Int64], as redaction: ActivityRedaction) throws -> Int {
        guard !blockIDs.isEmpty else { return 0 }
        let other = redaction == .other ? ", app_bundle = NULL, app_name = NULL, category = NULL, ai_project_id = NULL, project_id = NULL" : ""
        let unless = redaction == .other ? "(redaction IS NULL OR redaction <> 'other')" : "redaction IS NULL"
        return try write(notify: Self.activityDidChange) {
            try db.run("UPDATE activity_blocks SET \(Self.privateFields)\(other), redaction = ? WHERE \(unless) AND id IN (\(Self.placeholders(blockIDs.count)))",
                       [redaction.rawValue as SQLValue] + blockIDs.map { $0 as SQLValue })
            return try changes()
        }
    }

    /// The cached answer for a cache key, with the project name as the model gave it.
    func cachedClassification(_ key: String) throws -> ActivityAI.Answer? {
        try read {
            try db.query("SELECT category, description, project, work FROM activity_ai_cache WHERE key = ?", [key]) {
                ($0.string(0), $0.optionalString(1), $0.optionalString(2), $0.isNull(3) ? nil : $0.bool(3))
            }.first
        }
    }

    func cacheClassification(_ key: String, category: String, description: String?, project: String?, work: Bool? = nil) throws {
        try write(notify: Self.activityDidChange) {
            try db.run("""
                INSERT INTO activity_ai_cache (key, category, description, project, work, updated) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (key) DO UPDATE SET category = excluded.category, description = excluded.description,
                    project = excluded.project, work = excluded.work, updated = excluded.updated
                """, [key, category, description, project, work, Date().timeIntervalSince1970])
        }
    }

    /// Removes blocks that ended before `date`; returns how many.
    @discardableResult
    func deleteBlocks(before date: Date) throws -> Int {
        try write(notify: Self.activityDidChange) {
            try db.run("DELETE FROM activity_blocks WHERE end < ?", [date.timeIntervalSince1970])
            return try changes()
        }
    }

    func delete(blockIDs: [Int64]) throws {
        guard !blockIDs.isEmpty else { return }
        try write(notify: Self.activityDidChange) {
            try db.run("DELETE FROM activity_blocks WHERE id IN (\(Self.placeholders(blockIDs.count)))", blockIDs)
        }
    }

    /// Removes the activity between `from` and `to`: blocks inside go, blocks reaching into it are cut at its edges
    /// (and lose their typed excerpt), and a block spanning it is split in two.
    func delete(from: Date, to: Date) throws {
        let from = from.timeIntervalSince1970, to = to.timeIntervalSince1970
        try write(notify: Self.activityDidChange) {
            try db.run("""
                INSERT INTO activity_blocks (start, end, \(Self.detailColumns))
                SELECT ?, end, \(Self.detailColumns.replacingOccurrences(of: "typed_excerpt", with: "NULL").replacingOccurrences(of: "claude_prompt", with: "NULL")) FROM activity_blocks
                WHERE start < ? AND end > ?
                """, [to, from, to])
            try db.run("UPDATE activity_blocks SET end = ?, typed_excerpt = NULL WHERE start < ? AND end > ?", [from, from, from])
            try db.run("UPDATE activity_blocks SET start = ?, typed_excerpt = NULL WHERE start >= ? AND start < ? AND end > ?", [to, from, to, to])
            try db.run("DELETE FROM activity_blocks WHERE start >= ? AND end <= ?", [from, to])
        }
    }

    /// Removes the blocks on the day containing `day` whose address is on `host`.
    func deleteMatching(host: String, on day: Date) throws {
        let range = ActivityLogic.day(containing: day)
        try write(notify: Self.activityDidChange) {
            try db.run("DELETE FROM activity_blocks WHERE end > ? AND start < ? AND (url = ? OR substr(url, 1, ?) = ?)",
                       [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970, host, host.count + 1, host + "/"])
        }
    }

    /// Removes every block and the classification cache.
    func deleteAll() throws {
        try write(notify: Self.activityDidChange) {
            try db.run("DELETE FROM activity_blocks")
            try db.run("DELETE FROM activity_ai_cache")
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func changes() throws -> Int {
        try db.query("SELECT changes()") { Int($0.int64(0)) }.first ?? 0
    }

    func projects() throws -> [Project] {
        try read {
            try db.query("SELECT id, name, color FROM projects ORDER BY name COLLATE NOCASE") {
                Project(id: $0.int64(0), name: $0.string(1), color: $0.string(2))
            }
        }
    }

    @discardableResult
    func addProject(_ name: String, color: String? = nil) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SQLiteError(message: "a project needs a name") }
        return try write(notify: Self.activityDidChange) {
            let count = try db.query("SELECT count(*) FROM projects") { Int($0.int64(0)) }.first ?? 0
            let color = color ?? Project.colors[count % Project.colors.count]
            try db.run("INSERT INTO projects (name, color) VALUES (?, ?)", [trimmed, color])
            return Project(id: try db.lastInsertID, name: trimmed, color: color)
        }
    }

    func updateProject(_ project: Project) throws {
        try write(notify: Self.activityDidChange) { try db.run("UPDATE projects SET name = ?, color = ? WHERE id = ?", [project.name, project.color, project.id]) }
    }

    func deleteProject(_ id: Int64) throws {
        try write(notify: Self.activityDidChange) { try db.run("DELETE FROM projects WHERE id = ?", [id]) }
    }

    func rules() throws -> [ProjectRule] {
        try read {
            try db.query("SELECT id, project_id, field, pattern FROM project_rules ORDER BY id") {
                ProjectRule(id: $0.int64(0), projectID: $0.int64(1), field: RuleField(rawValue: $0.string(2)) ?? .repo, pattern: $0.string(3))
            }
        }
    }

    @discardableResult
    func addRule(project: Int64, field: RuleField, pattern: String) throws -> ProjectRule {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SQLiteError(message: "a rule needs a pattern") }
        return try write(notify: Self.activityDidChange) {
            try db.run("INSERT INTO project_rules (project_id, field, pattern) VALUES (?, ?, ?)", [project, field.rawValue, trimmed])
            return ProjectRule(id: try db.lastInsertID, projectID: project, field: field, pattern: trimmed)
        }
    }

    func deleteRule(_ id: Int64) throws {
        try write(notify: Self.activityDidChange) { try db.run("DELETE FROM project_rules WHERE id = ?", [id]) }
    }

    /// Remembers the Jira site of the page's project and the ticket title the page shows; writes only what is new.
    func learnTickets(from key: ActivityKey) throws {
        let jira = JiraLink.parse(key.url)
        let titled = ActivityLogic.ticketTitle(windowTitle: key.windowTitle, url: key.url)
        guard jira != nil || titled != nil else { return }
        let known = try ticketDirectory()
        let newSite = jira.map { known.sites[$0.prefix] != $0.site } ?? false
        let newTitle = titled.map { known.titles[$0.ticket] != $0.title } ?? false
        guard newSite || newTitle else { return }
        let now = Date().timeIntervalSince1970
        try write(notify: Self.activityDidChange) {
            if let jira, newSite {
                try db.run("""
                    INSERT INTO jira_sites (prefix, site, updated) VALUES (?, ?, ?)
                    ON CONFLICT (prefix) DO UPDATE SET site = excluded.site, updated = excluded.updated
                    """, [jira.prefix, jira.site, now])
            }
            if let titled, newTitle {
                try db.run("""
                    INSERT INTO tickets (key, title, site, updated) VALUES (?, ?, ?, ?)
                    ON CONFLICT (key) DO UPDATE SET title = excluded.title, site = coalesce(excluded.site, tickets.site), updated = excluded.updated
                    """, [titled.ticket, titled.title, jira?.site, now])
            }
        }
    }

    func ticketDirectory() throws -> TicketDirectory {
        try read {
            var directory = TicketDirectory()
            for (prefix, site) in try db.query("SELECT prefix, site FROM jira_sites", [], { ($0.string(0), $0.string(1)) }) {
                directory.sites[prefix] = site
            }
            for (key, title) in try db.query("SELECT key, title FROM tickets WHERE title IS NOT NULL", [], { ($0.string(0), $0.string(1)) }) {
                directory.titles[key] = title
            }
            return directory
        }
    }

    /// Fills the repository, owner and branch that the addresses of stored blocks give (`ActivityLogic.linked`), and
    /// learns their ticket titles and Jira sites. Only empty fields are filled; returns how many blocks changed.
    @discardableResult
    func backfillLinks(branches: BranchIndex) throws -> Int {
        let blocks = try read {
            try db.query("SELECT \(Self.blockColumns) FROM activity_blocks WHERE idle = 0 AND url IS NOT NULL AND redaction IS NULL", [], Self.block)
        }
        var changed: [ActivityBlock] = []
        for block in blocks {
            try learnTickets(from: block.key)
            let key = ActivityLogic.linked(block.key, branches: branches)
            if key != block.key { changed.append(ActivityBlock(id: block.id, start: block.start, end: block.end, key: key, projectID: nil)) }
        }
        guard !changed.isEmpty else { return 0 }
        try write(notify: Self.activityDidChange) {
            for block in changed {
                try db.run("UPDATE activity_blocks SET repo = ?, repo_owner = ?, branch = ? WHERE id = ?",
                           [block.key.repo, block.key.owner, block.key.branch, block.id])
            }
        }
        return changed.count
    }

    /// The meetings that start in `range`, for the context summary.
    func meetingLines(in range: Range<Date>) throws -> [ActivityLogic.MeetingSummaryLine] {
        try meetings().filter { range.contains($0.created) }.sorted { $0.created < $1.created }
            .map { ActivityLogic.MeetingSummaryLine(date: $0.created, title: $0.title, duration: $0.duration) }
    }

    private static func block(_ row: SQLRow) -> ActivityBlock {
        let ids = row.optionalString(10)?.split(separator: "\n").map(String.init) ?? []
        let titles = row.optionalString(11)?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        let claude = ids.enumerated().map { index, id -> ClaudeSession in
            let parts = index < titles.count ? titles[index].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false) : []
            return ClaudeSession(id: id, folder: parts.first.map(String.init) ?? "", title: parts.count > 1 ? String(parts[1]) : "")
        }
        let key = ActivityKey(appBundle: row.optionalString(3), appName: row.optionalString(4), windowTitle: row.optionalString(5),
                              url: row.optionalString(6), repo: row.optionalString(7), branch: row.optionalString(8),
                              ticket: row.optionalString(9), claude: claude, idle: row.bool(12), claudeFocus: row.optionalString(18),
                              redaction: row.optionalString(20).flatMap(ActivityRedaction.init), owner: row.optionalString(22))
        return ActivityBlock(id: row.int64(0), start: Date(timeIntervalSince1970: row.double(1)), end: Date(timeIntervalSince1970: row.double(2)),
                             key: key, projectID: row.isNull(13) ? nil : row.int64(13), typedExcerpt: row.optionalString(14),
                             category: row.optionalString(15).flatMap(ActivityCategory.init), aiDescription: row.optionalString(16),
                             aiProjectID: row.isNull(17) ? nil : row.int64(17), claudePrompt: row.optionalString(19),
                             aiWork: row.isNull(21) ? nil : row.bool(21))
    }
}
