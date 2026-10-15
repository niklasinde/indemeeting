import Foundation
import SQLite3

struct SQLiteError: LocalizedError {
    let message: String

    var errorDescription: String? { "Database error: \(message)" }
}

protocol SQLValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32
}

extension String: SQLValue {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_text(statement, index, self, -1, Self.transient)
    }
}

extension Int64: SQLValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, self) }
}

extension Int: SQLValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, Int64(self)) }
}

extension Double: SQLValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_double(statement, index, self) }
}

extension Bool: SQLValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int(statement, index, self ? 1 : 0) }
}

struct SQLRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func bool(_ column: Int32) -> Bool { sqlite3_column_int(statement, column) != 0 }
    func string(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    func optionalString(_ column: Int32) -> String? { isNull(column) ? nil : string(column) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
}

/// One SQLite connection with cached prepared statements. Not thread-safe: use it from one serial queue.
final class SQLiteDatabase {
    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(result))
            sqlite3_close_v2(db)
            throw SQLiteError(message: "\(path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON")
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements without parameters.
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func run(_ sql: String, _ values: [SQLValue?] = []) throws {
        try withStatement(sql, values) { statement in
            while try step(statement) {}
        }
    }

    func query<T>(_ sql: String, _ values: [SQLValue?] = [], _ read: (SQLRow) throws -> T) throws -> [T] {
        try withStatement(sql, values) { statement in
            var rows: [T] = []
            while try step(statement) { rows.append(try read(SQLRow(statement: statement))) }
            return rows
        }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ values: [SQLValue?], _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            try check(value?.bind(to: statement, at: index) ?? sqlite3_bind_null(statement, index))
        }
        return try body(statement)
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil))
        guard let statement else { throw SQLiteError(message: "empty statement: \(sql)") }
        statements[sql] = statement
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        try check(result == SQLITE_DONE ? SQLITE_OK : result)
        return false
    }

    private func check(_ result: Int32) throws {
        guard result != SQLITE_OK else { return }
        throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
    }
}
