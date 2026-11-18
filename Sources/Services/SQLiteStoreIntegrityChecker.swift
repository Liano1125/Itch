import Foundation
import SQLite3

/// Performs read-only SQLite integrity and foreign-key validation.
/// The caller must release all writable SwiftData/SQLite handles first.
enum SQLiteStoreIntegrityChecker {
    enum CheckError: LocalizedError {
        case openFailed(String)
        case queryFailed(String)
        case integrityFailed(String)
        case foreignKeyFailed(String)
        case readOnlyReopenFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let detail):
                return "SQLite database could not be opened read-only: \(detail)"
            case .queryFailed(let detail):
                return "SQLite integrity validation query failed: \(detail)"
            case .integrityFailed(let detail):
                return "SQLite integrity_check reported corruption: \(detail)"
            case .foreignKeyFailed(let detail):
                return "SQLite foreign_key_check found violations: \(detail)"
            case .readOnlyReopenFailed(let detail):
                return "SQLite staging store could not be reopened read-only: \(detail)"
            }
        }
    }

    /// Compatibility check retained for existing callers.
    static func quickCheck(at storeURL: URL) throws {
        try runIntegrityPragma("PRAGMA quick_check;", at: storeURL, label: "quick_check")
    }

    /// Full validation for a staging database before it can advance.
    /// integrity_check checks b-tree/page consistency; foreign_key_check checks
    /// relational constraints even when the writer had foreign_keys disabled.
    static func fullCheck(at storeURL: URL) throws {
        try runIntegrityPragma("PRAGMA integrity_check;", at: storeURL, label: "integrity_check")
        try runForeignKeyCheck(at: storeURL)
        try reopenReadOnly(at: storeURL)
    }

    /// Closes all validation connections, then proves the completed staging file
    /// can be independently reopened without write access and has a readable schema.
    static func reopenReadOnly(at storeURL: URL) throws {
        let database = try openReadOnly(storeURL)
        defer { sqlite3_close_v2(database) }

        guard sqlite3_db_readonly(database, "main") == 1 else {
            throw CheckError.readOnlyReopenFailed("main database is not read-only")
        }

        var statement: OpaquePointer?
        let sql = "SELECT schema_version, (SELECT COUNT(*) FROM sqlite_schema) FROM pragma_schema_version;"
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw CheckError.readOnlyReopenFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CheckError.readOnlyReopenFailed("schema metadata could not be read")
        }
        let schemaVersion = sqlite3_column_int64(statement, 0)
        let schemaObjectCount = sqlite3_column_int64(statement, 1)
        guard schemaVersion >= 0, schemaObjectCount > 0 else {
            throw CheckError.readOnlyReopenFailed("schema metadata is empty or invalid")
        }
    }

    private static func runIntegrityPragma(_ sql: String, at storeURL: URL, label: String) throws {
        let database = try openReadOnly(storeURL)
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw CheckError.queryFailed("SQLite error \(sqlite3_extended_errcode(database)): \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw CheckError.queryFailed("SQLite error \(sqlite3_extended_errcode(database)): \(String(cString: sqlite3_errmsg(database)))")
            }
            if let value = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: value))
            }
        }

        guard rows == ["ok"] else {
            let detail = rows.joined(separator: "; ").isEmpty ? "No result returned" : rows.joined(separator: "; ")
            throw CheckError.integrityFailed("\(label): \(detail)")
        }
    }

    private static func runForeignKeyCheck(at storeURL: URL) throws {
        let database = try openReadOnly(storeURL)
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA foreign_key_check;", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw CheckError.queryFailed("SQLite error \(sqlite3_extended_errcode(database)): \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }

        var violations: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw CheckError.queryFailed("SQLite error \(sqlite3_extended_errcode(database)): \(String(cString: sqlite3_errmsg(database)))")
            }
            let table = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
            let rowID = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? "WITHOUT ROWID"
                : String(sqlite3_column_int64(statement, 1))
            let parent = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "unknown"
            let constraint = sqlite3_column_int(statement, 3)
            violations.append("table=\(table), row=\(rowID), parent=\(parent), constraint=\(constraint)")
        }

        guard violations.isEmpty else {
            throw CheckError.foreignKeyFailed(violations.prefix(10).joined(separator: "; "))
        }
    }

    private static func openReadOnly(_ storeURL: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            storeURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite returned no connection"
            if let database { sqlite3_close_v2(database) }
            throw CheckError.openFailed(message)
        }
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 5_000)
        return database
    }
}
