import XCTest
import SQLite3
@testable import itchPocket

final class SQLiteStoreSnapshotCopierTests: XCTestCase {
    func testSnapshotIncludesCommittedWALContentWhileSourceConnectionRemainsOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.store")
        let destinationURL = root.appendingPathComponent("snapshot.store")
        var writer: OpaquePointer?
        let openResult = sqlite3_open_v2(
            sourceURL.path,
            &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        XCTAssertEqual(openResult, SQLITE_OK)
        let source = try XCTUnwrap(writer)
        defer { sqlite3_close_v2(source) }

        try execute("PRAGMA journal_mode=WAL;", on: source)
        try execute("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL);", on: source)
        try execute("INSERT INTO records (id, value) VALUES (1, 'committed-in-wal');", on: source)
        try execute("BEGIN IMMEDIATE;", on: source)
        try execute("INSERT INTO records (id, value) VALUES (2, 'uncommitted-at-snapshot-time');", on: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path + "-wal"))
        try SQLiteStoreSnapshotCopier.copy(from: sourceURL, to: destinationURL)
        try execute("COMMIT;", on: source)

        var snapshot: OpaquePointer?
        let snapshotResult = sqlite3_open_v2(
            destinationURL.path,
            &snapshot,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        XCTAssertEqual(snapshotResult, SQLITE_OK)
        let snapshotDB = try XCTUnwrap(snapshot)
        defer { sqlite3_close_v2(snapshotDB) }

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(snapshotDB, "SELECT value FROM records WHERE id = 1;", -1, &statement, nil),
            SQLITE_OK
        )
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        let value = sqlite3_column_text(query, 0).map { String(cString: $0) }
        XCTAssertEqual(value, "committed-in-wal")
        XCTAssertEqual(sqlite3_step(query), SQLITE_DONE)

        var modeStatement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(snapshotDB, "PRAGMA journal_mode;", -1, &modeStatement, nil),
            SQLITE_OK
        )
        let modeQuery = try XCTUnwrap(modeStatement)
        defer { sqlite3_finalize(modeQuery) }
        XCTAssertEqual(sqlite3_step(modeQuery), SQLITE_ROW)
        let mode = sqlite3_column_text(modeQuery, 0).map { String(cString: $0) }
        XCTAssertEqual(mode?.lowercased(), "delete")

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path + "-journal"))
    }

    func testExistingDestinationIsPreservedWhenCopyIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-sqlite-snapshot-existing-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.store")
        let destinationURL = root.appendingPathComponent("snapshot.store")
        var source: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        XCTAssertEqual(sourceResult, SQLITE_OK)
        let sourceDB = try XCTUnwrap(source)
        try execute("CREATE TABLE records (id INTEGER PRIMARY KEY);", on: sourceDB)
        sqlite3_close_v2(sourceDB)

        let originalContents = Data("do-not-overwrite".utf8)
        try originalContents.write(to: destinationURL)

        XCTAssertThrowsError(try SQLiteStoreSnapshotCopier.copy(from: sourceURL, to: destinationURL))
        XCTAssertEqual(try Data(contentsOf: destinationURL), originalContents)
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw NSError(
                domain: "SQLiteStoreSnapshotCopierTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
