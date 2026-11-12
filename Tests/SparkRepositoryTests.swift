import XCTest
import SwiftData
@testable import itchPocket

final class SparkRepositoryTests: XCTestCase {
    @MainActor
    func testUpsertAndLoadPreserveAllSparkMetadata() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "existing", title: "Existing"))
        let repository = SparkRepository(database: database)
        let lastSaveAt = Date(timeIntervalSince1970: 1_800_000_000)
        let scannedAt = Date(timeIntervalSince1970: 1_800_000_100)

        try repository.upsert([
            StoredSparkMetadata(
                gameID: "game-a",
                runtimeSeconds: 12_345,
                lastSaveAt: lastSaveAt,
                renpyVersion: "8.3.7",
                saveCount: 14,
                scannedAt: scannedAt
            )
        ])

        let stored = try XCTUnwrap(repository.loadByGameID()["game-a"])
        XCTAssertEqual(stored.gameID, "game-a")
        XCTAssertEqual(stored.runtimeSeconds, 12_345)
        XCTAssertEqual(stored.lastSaveAt, lastSaveAt)
        XCTAssertEqual(stored.renpyVersion, "8.3.7")
        XCTAssertEqual(stored.saveCount, 14)
        XCTAssertEqual(stored.scannedAt, scannedAt)
    }

    @MainActor
    func testUpsertUpdatesExistingGameWithoutCreatingAnotherRow() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "existing", title: "Existing"))
        let repository = SparkRepository(database: database)
        try repository.upsert([
            StoredSparkMetadata(gameID: "game-a", runtimeSeconds: 100, renpyVersion: "8.2")
        ])
        try repository.upsert([
            StoredSparkMetadata(gameID: "game-a", runtimeSeconds: 250, renpyVersion: "8.3")
        ])

        let stored = try repository.loadByGameID()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored["game-a"]?.runtimeSeconds, 250)
        XCTAssertEqual(stored["game-a"]?.renpyVersion, "8.3")
    }

    @MainActor
    func testDuplicateGameIDsAreRejectedBeforeAnyMutation() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "existing", title: "Existing"))
        let repository = SparkRepository(database: database)
        try repository.upsert([
            StoredSparkMetadata(gameID: "existing", runtimeSeconds: 10)
        ])

        XCTAssertThrowsError(try repository.upsert([
            StoredSparkMetadata(gameID: "new", runtimeSeconds: 20),
            StoredSparkMetadata(gameID: "new", runtimeSeconds: 30)
        ])) { error in
            XCTAssertEqual(error as? SparkRepositoryError, .duplicateGameID("new"))
        }

        let stored = try repository.loadByGameID()
        XCTAssertEqual(stored.count, 1)
        XCTAssertNil(stored["new"])
        XCTAssertEqual(stored["existing"]?.runtimeSeconds, 10)
    }

    @MainActor
    func testBatchUpsertCanDeferSaveForCallerBatching() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "existing", title: "Existing"))
        let repository = SparkRepository(database: database)

        try repository.upsert([
            StoredSparkMetadata(gameID: "game-a", runtimeSeconds: 42)
        ], save: false)

        XCTAssertTrue(database.context.hasChanges)
        try database.save()
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(try repository.loadByGameID()["game-a"]?.runtimeSeconds, 42)
    }

    @MainActor
    func testBatchUpsertOnlyChangesIncludedGames() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "existing", title: "Existing"))
        let repository = SparkRepository(database: database)
        try repository.upsert([
            StoredSparkMetadata(gameID: "game-a", runtimeSeconds: 10),
            StoredSparkMetadata(gameID: "game-b", runtimeSeconds: 20)
        ])
        try repository.upsert([
            StoredSparkMetadata(gameID: "game-a", runtimeSeconds: 99)
        ])

        let stored = try repository.loadByGameID()
        XCTAssertEqual(stored["game-a"]?.runtimeSeconds, 99)
        XCTAssertEqual(stored["game-b"]?.runtimeSeconds, 20)
    }
}
