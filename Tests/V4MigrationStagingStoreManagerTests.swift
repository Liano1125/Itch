import XCTest
import SQLite3
@testable import itchPocket

final class V4MigrationStagingStoreManagerTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4StagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCreatesConsistentSnapshotAndDiscardIsIdempotent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                sourceURL.path,
                &writer,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let source = try XCTUnwrap(writer)
        defer { sqlite3_close_v2(source) }

        try execute("PRAGMA journal_mode=WAL;", on: source)
        try execute("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL);", on: source)
        try execute("INSERT INTO records (id, value) VALUES (1, 'committed-in-wal');", on: source)

        let manager = V4MigrationStagingStoreManager(
            rootURL: root.appendingPathComponent("control", isDirectory: true)
        )
        let staging = try manager.createSnapshot(
            from: sourceURL,
            runID: "run-001",
            stagingStoreID: "stage-001"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.storeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.storeURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.storeURL.path + "-shm"))
        try SQLiteStoreIntegrityChecker.quickCheck(at: staging.storeURL)
        XCTAssertEqual(try readValue(from: staging.storeURL), "committed-in-wal")

        XCTAssertTrue(try manager.discard(runID: "run-001", stagingStoreID: "stage-001"))
        XCTAssertFalse(try manager.discard(runID: "run-001", stagingStoreID: "stage-001"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try readValue(from: sourceURL), "committed-in-wal")
    }

    func testDuplicateAttemptDoesNotReuseOrOverwriteExistingStaging() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeSourceDatabase(in: root)
        let manager = V4MigrationStagingStoreManager(rootURL: root.appendingPathComponent("control"))

        let first = try manager.createSnapshot(
            from: sourceURL,
            runID: "run-002",
            stagingStoreID: "stage-002"
        )
        let originalBytes = try Data(contentsOf: first.storeURL)

        XCTAssertThrowsError(try manager.createSnapshot(
            from: sourceURL,
            runID: "run-002",
            stagingStoreID: "stage-002"
        )) { error in
            XCTAssertEqual(error as? V4MigrationStagingStoreManager.StagingError, .stagingAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: first.storeURL), originalBytes)
    }

    func testRejectsUnsafeIdentifiersBeforeCreatingAnyDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeSourceDatabase(in: root)
        let stagingRoot = root.appendingPathComponent("control")
        let manager = V4MigrationStagingStoreManager(rootURL: stagingRoot)

        XCTAssertThrowsError(try manager.createSnapshot(
            from: sourceURL,
            runID: "../outside",
            stagingStoreID: "stage-003"
        )) { error in
            XCTAssertEqual(error as? V4MigrationStagingStoreManager.StagingError, .invalidIdentifier)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testFailedSnapshotRemovesOnlyItsPartialStagingDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let invalidSource = root.appendingPathComponent("invalid.sqlite")
        try Data("not a sqlite database".utf8).write(to: invalidSource)
        let manager = V4MigrationStagingStoreManager(
            rootURL: root.appendingPathComponent("control", isDirectory: true)
        )

        XCTAssertThrowsError(try manager.createSnapshot(
            from: invalidSource,
            runID: "run-004",
            stagingStoreID: "stage-004"
        ))
        let expectedDirectory = root
            .appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent("run-run-004-staging-stage-004", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidSource.path))
    }

    private func makeSourceDatabase(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).sqlite")
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        XCTAssertEqual(result, SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close_v2(handle) }
        try execute("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL);", on: handle)
        try execute("INSERT INTO records (id, value) VALUES (1, 'stable');", on: handle)
        return url
    }

    private func readValue(from url: URL) throws -> String? {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        XCTAssertEqual(result, SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close_v2(handle) }

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "SELECT value FROM records WHERE id = 1;", -1, &statement, nil),
            SQLITE_OK
        )
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(query, 0).map { String(cString: $0) }
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw NSError(
                domain: "V4MigrationStagingStoreManagerTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
