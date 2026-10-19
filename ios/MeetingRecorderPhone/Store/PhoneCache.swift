import Foundation

/// The last answers from the Mac in a small SQLite file, so the app opens with data before the Mac has answered and
/// still shows something when it is asleep. Audio is never stored.
final class PhoneCache: @unchecked Sendable {
    private let database: SQLiteDatabase
    private let lock = NSLock()

    static func defaultURL() -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("cache.sqlite")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.execute("CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, value BLOB NOT NULL, fetched REAL NOT NULL)")
    }

    static func inMemory() throws -> PhoneCache { try PhoneCache(path: ":memory:") }

    func put(_ value: some Encodable, for key: String, at date: Date = Date()) {
        guard let data = try? PhoneAPI.encoder.encode(value) else { return }
        lock.withLock {
            try? database.run("INSERT OR REPLACE INTO cache (key, value, fetched) VALUES (?, ?, ?)", [key, data, date.timeIntervalSince1970])
        }
    }

    func get<T: Decodable>(_ type: T.Type, for key: String) -> (value: T, fetched: Date)? {
        let row = lock.withLock {
            try? database.query("SELECT value, fetched FROM cache WHERE key = ?", [key]) { ($0.optionalData(0), $0.double(1)) }.first
        }
        guard let row, let data = row.0, let value = try? PhoneAPI.decoder.decode(T.self, from: data) else { return nil }
        return (value, Date(timeIntervalSince1970: row.1))
    }

    func clear() {
        lock.withLock { try? database.run("DELETE FROM cache") }
    }

    /// Keeps the newest `limit` entries whose key starts with `prefix`, so opened meetings do not pile up.
    func trim(prefix: String, keeping limit: Int) {
        lock.withLock {
            try? database.run("""
                DELETE FROM cache WHERE key LIKE ? AND key NOT IN
                (SELECT key FROM cache WHERE key LIKE ? ORDER BY fetched DESC LIMIT ?)
                """, [prefix + "%", prefix + "%", limit])
        }
    }
}
