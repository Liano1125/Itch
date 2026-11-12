import XCTest
import SwiftData
@testable import itchPocket

final class UpdateMonitorRepositoryTests: XCTestCase {
    @MainActor
    func testLoadWatchesUsesGameRepositoryMetadataAndLeavesOrphansUntouched() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "game-a", title: "Current title", gameURL: "https://example.com/game"))
        context.insert(DBUpdateWatch(
            gameID: "game-a",
            entityTag: "\"v2\"",
            lastModified: "yesterday",
            contentHash: "abc",
            lastCheckedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasBaseline: true,
            isEnabled: true
        ))
        context.insert(DBUpdateWatch(gameID: "orphan", isEnabled: false))
        try database.save()

        let repository = UpdateMonitorRepository(database: database)
        let watches = try repository.loadWatches()

        let watch = try XCTUnwrap(watches["game-a"])
        XCTAssertEqual(watch.gameTitle, "Current title")
        XCTAssertEqual(watch.gameURL, "https://example.com/game")
        XCTAssertEqual(watch.entityTag, "\"v2\"")
        XCTAssertEqual(watch.lastModified, "yesterday")
        XCTAssertEqual(watch.contentHash, "abc")
        XCTAssertTrue(watch.hasBaseline)
        XCTAssertTrue(watch.isEnabled)
        XCTAssertNil(watches["orphan"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBUpdateWatch>()).count, 2)
    }

    @MainActor
    func testSaveWatchesInsertsUpdatesAndRemovesRowsFromCompleteSnapshot() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "game-a", title: "A"))
        context.insert(DBGame(id: "game-b", title: "B"))
        context.insert(DBUpdateWatch(gameID: "game-a", entityTag: "old"))
        context.insert(DBUpdateWatch(gameID: "game-b"))
        try database.save()

        let repository = UpdateMonitorRepository(database: database)
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try repository.saveWatches([
            GameUpdateWatch(
                gameID: "game-a",
                gameTitle: "A",
                gameURL: "https://example.com/a",
                entityTag: "new",
                lastModified: "today",
                contentHash: "hash",
                lastCheckedAt: checkedAt,
                hasBaseline: true,
                isEnabled: true
            )
        ])

        let rows = try context.fetch(FetchDescriptor<DBUpdateWatch>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.gameID, "game-a")
        XCTAssertEqual(rows.first?.entityTag, "new")
        XCTAssertEqual(rows.first?.lastModified, "today")
        XCTAssertEqual(rows.first?.contentHash, "hash")
        XCTAssertEqual(rows.first?.lastCheckedAt, checkedAt)
        XCTAssertTrue(rows.first?.hasBaseline == true)
        XCTAssertTrue(rows.first?.isEnabled == true)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBGame>()).count, 2)
    }

    @MainActor
    func testSaveFalseLeavesChangesPendingForCallerBatchSave() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "A"))
        try database.save()

        let repository = UpdateMonitorRepository(database: database)
        try repository.saveWatches([
            GameUpdateWatch(
                gameID: "game-a",
                gameTitle: "A",
                gameURL: "",
                entityTag: nil,
                lastModified: nil,
                contentHash: nil,
                lastCheckedAt: nil,
                hasBaseline: false,
                isEnabled: true
            )
        ], save: false)

        XCTAssertTrue(database.context.hasChanges)
        try database.save()
        XCTAssertEqual(try repository.loadWatches()["game-a"]?.isEnabled, true)
    }

    @MainActor
    func testDuplicateWatchIDsFailBeforeMutatingContext() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "A"))
        try database.save()

        let repository = UpdateMonitorRepository(database: database)
        let watch = GameUpdateWatch(
            gameID: "game-a",
            gameTitle: "A",
            gameURL: "",
            entityTag: nil,
            lastModified: nil,
            contentHash: nil,
            lastCheckedAt: nil,
            hasBaseline: false,
            isEnabled: true
        )

        XCTAssertThrowsError(try repository.saveWatches([watch, watch])) { error in
            XCTAssertEqual(error as? UpdateMonitorRepository.RepositoryError, .duplicateWatchID("game-a"))
        }
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBUpdateWatch>()).isEmpty)
    }

    @MainActor
    func testEmptySnapshotRemovesWatchRowsButPreservesCanonicalGameRows() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "A"))
        database.context.insert(DBUpdateWatch(gameID: "game-a"))
        try database.save()

        let repository = UpdateMonitorRepository(database: database)
        try repository.saveWatches([])

        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBUpdateWatch>()).isEmpty)
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBGame>()).map(\.id), ["game-a"])
    }

    @MainActor
    func testSaveWatchesRejectsMissingGameBeforeDeletingOrUpdatingAnyRows() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "A"))
        database.context.insert(DBUpdateWatch(gameID: "game-a", entityTag: "keep"))
        try database.save()
        let repository = UpdateMonitorRepository(database: database)
        let invalid = GameUpdateWatch(gameID: "missing-game", gameTitle: "Missing", gameURL: "", entityTag: nil, lastModified: nil, contentHash: nil, lastCheckedAt: nil, hasBaseline: false, isEnabled: true)

        XCTAssertThrowsError(try repository.saveWatches([invalid])) { error in
            XCTAssertEqual(error as? DatabaseReferenceValidator.ValidationError, .missingGame("missing-game"))
        }
        XCTAssertFalse(database.context.hasChanges)
        let rows = try database.context.fetch(FetchDescriptor<DBUpdateWatch>())
        XCTAssertEqual(rows.map(\.gameID), ["game-a"])
        XCTAssertEqual(rows.first?.entityTag, "keep")
    }
}
