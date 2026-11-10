import Foundation
import SQLite3

/// Performs a read-only SQLite quick_check after all SwiftData containers have
/// released the store. A failed or unavailable check is treated as a hard error.
enum SQLiteStoreIntegrityChecker {
    enum CheckError: LocalizedError {
        case openFailed(String)
        case queryFailed(String)
        case integrityFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let detail): return "SQLite database could not be opened read-only: \(detail)"
            case .queryFailed(let detail): return "SQLite quick_check could not run: \(detail)"
            case .integrityFailed(let detail): return "SQLite quick_check reported corruption: \(detail)"
            }
        }
    }

    static func quickCheck(at storeURL: URL) throws {
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
        defer { sqlite3_close_v2(database) }

        // SwiftData may be finishing a short-lived store transaction while
        // the independent read-only integrity connection starts. Let SQLite
        // resolve transient BUSY contention natively instead of failing
        // immediately; this is a bounded busy handler, not an application retry.
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 5_000)

        var statement: OpaquePointer?
        let sql = "PRAGMA quick_check;"
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
            throw CheckError.integrityFailed(rows.joined(separator: "; ").isEmpty ? "No result returned" : rows.joined(separator: "; "))
        }
    }
}
