import Foundation

/// The calendar event a meeting was recorded in, as stored with it.
struct StoredMeetingEvent: Equatable {
    var event: CalendarEventInfo
    var agenda: String?
}

extension MeetingStore {
    static let mentionsDidChange = Notification.Name("MeetingMentionsDidChange")

    func saveMentions(_ audioFile: String, _ entities: [SpottedEntity]) throws {
        guard !entities.isEmpty else { return }
        try write(notify: Self.mentionsDidChange) {
            for entity in entities {
                try db.run("""
                    INSERT OR IGNORE INTO meeting_mentions (meeting_id, kind, key, line, at)
                    SELECT id, ?, ?, ?, ? FROM meetings WHERE audio_file = ?
                    """, [entity.kind.rawValue, entity.key, entity.line, entity.at, audioFile])
            }
        }
    }

    func mentions(of audioFile: String) throws -> [SpottedEntity] {
        try read {
            try db.query("""
                SELECT n.kind, n.key, n.line, n.at FROM meeting_mentions n JOIN meetings m ON m.id = n.meeting_id
                WHERE m.audio_file = ? ORDER BY n.at, n.rowid
                """, [audioFile]) { row in
                SpottedEntity.Kind(rawValue: row.string(0)).map { SpottedEntity(kind: $0, key: row.string(1), line: row.string(2), at: row.double(3)) }
            }.compactMap { $0 }
        }
    }

    func saveCalendarEvent(_ audioFile: String, _ stored: StoredMeetingEvent) throws {
        let event = stored.event
        let attendees = String(decoding: (try? JSONEncoder().encode(event.attendees)) ?? Data("[]".utf8), as: UTF8.self)
        try write(notify: Self.mentionsDidChange) {
            try db.run("""
                INSERT OR REPLACE INTO meeting_events (meeting_id, event_id, series_id, title, start, end, attendees, agenda)
                SELECT id, ?, ?, ?, ?, ?, ?, ? FROM meetings WHERE audio_file = ?
                """, [event.id, event.seriesID, event.title, event.start.timeIntervalSince1970, event.end.timeIntervalSince1970,
                      attendees, stored.agenda, audioFile])
        }
    }

    func calendarEvent(of audioFile: String) throws -> StoredMeetingEvent? {
        try read {
            try db.query("""
                SELECT \(Self.eventColumns) FROM meeting_events e JOIN meetings m ON m.id = e.meeting_id WHERE m.audio_file = ?
                """, [audioFile], Self.storedEvent).first
        }
    }

    /// Earlier meetings with a summary, with what retrieval compares: their event's series and people, and what was
    /// mentioned in them. Decisions are filled in by `pastMeetingDetails`.
    func pastMeetings(excluding audioFile: String?) throws -> [PastMeeting] {
        let meetings = try self.meetings().filter { $0.summarised && $0.audioFile != audioFile }
        return try read {
            let events = Dictionary(try db.query("SELECT e.meeting_id, \(Self.eventColumns) FROM meeting_events e") {
                ($0.int64(0), Self.storedEvent($0, from: 1))
            }) { first, _ in first }
            let mentions = Dictionary(grouping: try db.query("SELECT meeting_id, kind, key FROM meeting_mentions") {
                (id: $0.int64(0), key: "\($0.string(1)):\($0.string(2))")
            }, by: \.id).mapValues { Set($0.map(\.key)) }
            return meetings.map { meeting in
                let event = events[meeting.id]?.event
                return PastMeeting(id: meeting.id, title: meeting.title, date: meeting.created, sourceApp: meeting.source?.app,
                                   attendees: event?.attendees.map(\.identity) ?? [], seriesID: event?.seriesID,
                                   mentions: mentions[meeting.id] ?? [])
            }
        }
    }

    /// The meetings where `entity` was spotted, or failing that whose text holds it, newest first, with the line.
    func meetings(mentioning entity: SpottedEntity, excluding audioFile: String?, limit: Int = 3) throws -> [(id: Int64, line: String)] {
        let spotted = try read {
            try db.query("""
                SELECT n.meeting_id, n.line FROM meeting_mentions n JOIN meetings m ON m.id = n.meeting_id
                WHERE n.kind = ? AND n.key = ? AND m.audio_file IS NOT ? ORDER BY m.created DESC LIMIT ?
                """, [entity.kind.rawValue, entity.key, audioFile, limit]) { (id: $0.int64(0), line: $0.string(1)) }
        }
        guard spotted.count < limit, let query = Self.searchText(entity) else { return spotted }
        let found = try searchMeetings(query, limit: limit * 2)
            .filter { found in found.meeting.audioFile != audioFile && !spotted.contains { $0.id == found.meeting.id } }
            .sorted { $0.meeting.created > $1.meeting.created }
            .map { (id: $0.meeting.id, line: $0.snippet.replacingOccurrences(of: "**", with: "")) }
        return Array((spotted + found).prefix(limit))
    }

    /// The meeting's decisions and action items from its summary.
    func pastMeetingDetails(_ meeting: PastMeeting) throws -> PastMeeting {
        guard let file = try self.meeting(id: meeting.id)?.audioFile, let content = try content(of: file) else { return meeting }
        var filled = meeting
        filled.decisions = content.summary.sections.flatMap { section in section.lines.map(\.text) }
        func text(_ item: ChecklistItem) -> String { item.owner.map { "\($0): \(item.task)" } ?? item.task }
        filled.actionItems = content.summary.actionItems.map(text)
        filled.openItems = content.summary.actionItems.filter { !$0.done }.map(text)
        return filled
    }

    /// What the spotter knows from the database: Jira projects and sites, repositories from GitHub and the activity
    /// log, and project names.
    func inCallVocabulary() throws -> InCallVocabulary {
        let directory = try ticketDirectory()
        let prefixes = Set(directory.titles.keys.map(ActivityLogic.ticketPrefix))
        let repos = try read {
            try db.query("SELECT DISTINCT repo FROM github_prs") { $0.string(0) }
                + db.query("""
                    SELECT DISTINCT repo_owner || '/' || repo FROM activity_blocks WHERE repo IS NOT NULL AND repo_owner IS NOT NULL
                    """) { $0.string(0) }
        }
        return InCallVocabulary(ticketPrefixes: prefixes, sites: directory.sites, repos: Array(Set(repos)).sorted(),
                                names: try projects().map(\.name))
    }

    private static let eventColumns = "e.event_id, e.series_id, e.title, e.start, e.end, e.attendees, e.agenda"

    private static func storedEvent(_ row: SQLRow) -> StoredMeetingEvent { storedEvent(row, from: 0) }

    private static func storedEvent(_ row: SQLRow, from first: Int32) -> StoredMeetingEvent {
        let attendees = (try? JSONDecoder().decode([CalendarAttendee].self, from: Data(row.string(first + 5).utf8))) ?? []
        return StoredMeetingEvent(event: CalendarEventInfo(id: row.string(first), seriesID: row.optionalString(first + 1), title: row.string(first + 2),
                                                           start: Date(timeIntervalSince1970: row.double(first + 3)),
                                                           end: Date(timeIntervalSince1970: row.double(first + 4)), attendees: attendees),
                                  agenda: row.optionalString(first + 6))
    }

    /// The words a transcript would hold for an entity: `QDLY 9031` for a ticket, `PR 2688` for a pull request.
    private static func searchText(_ entity: SpottedEntity) -> String? {
        switch entity.kind {
        case .ticket: return entity.key.replacingOccurrences(of: "-", with: " ")
        case .pullRequest: return entity.pullRequest.map { "\($0.repo?.split(separator: "/").last.map { "\($0) " } ?? "")\($0.number)" }
        case .name: return entity.key
        }
    }
}
