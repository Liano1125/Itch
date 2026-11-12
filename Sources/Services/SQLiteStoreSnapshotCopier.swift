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
        case journalModeNormalizationFailed(String)
        case destinationCloseFailed(String)

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
            case .journalModeNormalizationFailed(let detail):
                return "SQLite snapshot journal mode could not be normalized: \(detail)"
            case .destinationCloseFailed(let detail):
                return "SQLite snapshot destination could not be closed cleanly: \(detail)"
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

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CopyError.destinationOpenFailed("Destination already exists: \(destinationURL.lastPathComponent)")
        }

        var destination: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destinationHandle = destination else {
            let detail = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite connection"
            if let destination { sqlite3_close_v2(destination) }
            throw CopyError.destinationOpenFailed(detail)
        }
        var destinationCompleted = false
        defer {
            // Finalize any outstanding SQLite statements before this defer,
            // then close the connection before removing an incomplete store.
            if let destination { sqlite3_close_v2(destination) }
            if !destinationCompleted {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try? FileManager.default.removeItem(atPath: destinationURL.path + suffix)
                }
            }
        }
        sqlite3_extended_result_codes(destinationHandle, 1)
        sqlite3_busy_timeout(destinationHandle, 5_000)

        guard let backup = sqlite3_backup_init(destinationHandle, "main", source, "main") else {
            throw CopyError.backupInitializationFailed(String(cString: sqlite3_errmsg(destinationHandle)))
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
                "SQLite error \(stepResult): \(String(cString: sqlite3_errmsg(destinationHandle)))"
            )
        }
        guard finishResult == SQLITE_OK else {
            throw CopyError.backupFinalizeFailed(
                "SQLite error \(finishResult): \(String(cString: sqlite3_errmsg(destinationHandle)))"
            )
        }

        // The online backup copies the source database header, including its
        // WAL read/write mode bits. A standalone snapshot must not depend on
        // the source's -wal/-shm sidecars, so normalize the destination to
        // rollback-journal mode before handing it to SwiftData.
        var journalModeStatement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            destinationHandle,
            "PRAGMA journal_mode=DELETE;",
            -1,
            &journalModeStatement,
            nil
        )
        guard prepareResult == SQLITE_OK, let journalModeHandle = journalModeStatement else {
            throw CopyError.journalModeNormalizationFailed(
                "SQLite error \(prepareResult): \(String(cString: sqlite3_errmsg(destinationHandle)))"
            )
        }
        defer {
            if let journalModeStatement { sqlite3_finalize(journalModeStatement) }
        }

        let modeStepResult = sqlite3_step(journalModeHandle)
        let journalMode = modeStepResult == SQLITE_ROW
            ? sqlite3_column_text(journalModeHandle, 0).map { String(cString: $0) }
            : nil
        guard modeStepResult == SQLITE_ROW, journalMode?.lowercased() == "delete" else {
            throw CopyError.journalModeNormalizationFailed(
                "SQLite error \(modeStepResult), returned mode: \(journalMode ?? "nil")"
            )
        }
        // Finalize the PRAGMA statement and close the destination before
        // inspecting sidecars. SQLite may keep the WAL shared-memory mapping
        // alive until the final connection is closed, even after switching
        // the database back to DELETE journal mode.
        let finalizeResult = sqlite3_finalize(journalModeHandle)
        journalModeStatement = nil
        guard finalizeResult == SQLITE_OK else {
            throw CopyError.journalModeNormalizationFailed(
                "SQLite statement finalize error \(finalizeResult)"
            )
        }

        let closeResult = sqlite3_close(destinationHandle)
        guard closeResult == SQLITE_OK else {
            throw CopyError.destinationCloseFailed(
                "SQLite error \(closeResult)"
            )
        }
        destination = nil

        // Only after the destination connection is fully closed and DELETE
        // mode has been confirmed may any stale sidecars be removed.
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecarPath = destinationURL.path + suffix
            if FileManager.default.fileExists(atPath: sidecarPath) {
                do {
                    try FileManager.default.removeItem(atPath: sidecarPath)
                } catch {
                    throw CopyError.journalModeNormalizationFailed(
                        "Could not remove stale \(suffix) sidecar: \(error.localizedDescription)"
                    )
                }
            }
        }

        destinationCompleted = true
    }
}
