import Foundation
import SQLite3

/// Copies a SQLite database through SQLite's online backup API so committed
/// WAL content is included in one consistent database snapshot.
enum SQLiteStoreSnapshotCopier {
    enum CopyError: LocalizedError {
        case sourceOpenFailed(String)
        case destinationOpenFailed(String)
        case backupInitializationFailed(String)
        case backupFailed(String)
        case backupFinalizeFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceOpenFailed(let detail):
                return "SQLite snapshot source could not be opened: \(detail)"
            case .destinationOpenFailed(let detail):
                return "SQLite snapshot destination could not be opened: \(detail)"
            case .backupInitializationFailed(let detail):
                return "SQLite snapshot could not be initialized: \(detail)"
            case .backupFailed(let detail):
                return "SQLite snapshot failed: \(detail)"
            case .backupFinalizeFailed(let detail):
                return "SQLite snapshot could not be finalized: \(detail)"
            }
        }
    }

    static func copy(from sourceURL: URL, to destinationURL: URL) throws {
        var source: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceResult == SQLITE_OK, let source else {
            let detail = source.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite connection"
            if let source { sqlite3_close_v2(source) }
            throw CopyError.sourceOpenFailed(detail)
        }
        defer { sqlite3_close_v2(source) }
        sqlite3_extended_result_codes(source, 1)
        sqlite3_busy_timeout(source, 5_000)

        var destination: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destination else {
            let detail = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite connection"
            if let destination { sqlite3_close_v2(destination) }
            throw CopyError.destinationOpenFailed(detail)
        }
        defer { sqlite3_close_v2(destination) }
        sqlite3_extended_result_codes(destination, 1)
        sqlite3_busy_timeout(destination, 5_000)

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw CopyError.backupInitializationFailed(String(cString: sqlite3_errmsg(destination)))
        }

        let deadline = Date().addingTimeInterval(5)
        var stepResult = sqlite3_backup_step(backup, -1)
        while stepResult == SQLITE_OK || stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
            guard Date() < deadline else { break }
            if stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
                Thread.sleep(forTimeInterval: 0.01)
            }
            stepResult = sqlite3_backup_step(backup, -1)
        }

        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE else {
            throw CopyError.backupFailed(
                "SQLite error \(stepResult): \(String(cString: sqlite3_errmsg(destination)))"
            )
        }
        guard finishResult == SQLITE_OK else {
            throw CopyError.backupFinalizeFailed(
                "SQLite error \(finishResult): \(String(cString: sqlite3_errmsg(destination)))"
            )
        }
    }
}
