import XCTest
import SwiftData
@testable import itchPocket

final class GameUpdateRepositoryTests: XCTestCase {
    @MainActor
    func testLoadUpdatesGroupsByGameAndPreservesValues() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(60)
        database.context.insert(DBGameUpdate(
            id: "update-a",
            gameID: "game-a",
            title: "First",
            summary: "Summary A",
            detectedAt: firstDate,
            publishedAt: secondDate,
            url: "https://example.com/a",
            sourceID: "source-a",
            isHistorical: true
        ))
        database.context.insert(DBGameUpdate(
            id: "update-b",
            gameID: "game-b",
            summary: "Summary B",
            detectedAt: firstDate
        ))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        let loaded = try repository.loadUpdatesByGame()

        XCTAssertEqual(Set(loaded.keys), ["game-a", "game-b"])
        XCTAssertEqual(loaded["game-a"]?.first?.id, "update-a")
        XCTAssertEqual(loaded["game-a"]?.first?.title, "First")
        XCTAssertEqual(loaded["game-a"]?.first?.sourceID, "source-a")
        XCTAssertEqual(loaded["game-b"]?.first?.summary, "Summary B")
    }

    @MainActor
    func testPartialSynchronizationNeverDeletesOmittedUpdates() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBGameUpdate(id: "keep-a", gameID: "game-a", summary: "A"))
        database.context.insert(DBGameUpdate(id: "keep-b", gameID: "game-a", summary: "B"))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        try repository.synchronize([
            GameLibraryUpdate(id: "keep-a", summary: "A refreshed")
        ], for: "game-a")

        let rows = try database.context.fetch(FetchDescriptor<DBGameUpdate>())
        XCTAssertEqual(Set(rows.map(\.id)), ["keep-a", "keep-b"])
        XCTAssertEqual(rows.first(where: { $0.id == "keep-a" })?.summary, "A refreshed")
    }

    @MainActor
    func testCompleteSnapshotDeletesOnlyOmittedUpdatesForThatGame() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBGameUpdate(id: "keep-a", gameID: "game-a", summary: "A"))
        database.context.insert(DBGameUpdate(id: "remove-a", gameID: "game-a", summary: "Old"))
        database.context.insert(DBGameUpdate(id: "keep-b", gameID: "game-b", summary: "Other game"))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        try repository.synchronize([
            GameLibraryUpdate(id: "keep-a", summary: "A")
        ], for: "game-a", completeSnapshot: true)

        let rows = try database.context.fetch(FetchDescriptor<DBGameUpdate>())
        XCTAssertEqual(Set(rows.map(\.id)), ["keep-a", "keep-b"])
    }

    @MainActor
    func testUpdateIDConflictFailsBeforeMutatingExistingRow() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBGameUpdate(id: "shared", gameID: "game-a", summary: "Original"))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        XCTAssertThrowsError(try repository.synchronize([
            GameLibraryUpdate(id: "new", summary: "Would be inserted"),
            GameLibraryUpdate(id: "shared", summary: "Must not overwrite")
        ], for: "game-b", save: false))

        let rows = try database.context.fetch(FetchDescriptor<DBGameUpdate>())
        XCTAssertEqual(Set(rows.map(\.id)), ["shared"])
        XCTAssertEqual(rows.first?.gameID, "game-a")
        XCTAssertEqual(rows.first?.summary, "Original")
        XCTAssertFalse(database.context.hasChanges)
    }

    @MainActor
    func testHistoricalUpsertPreservesStableIDAndRefreshesMetadata() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        database.context.insert(DBGameUpdate(
            id: "stable-id",
            gameID: "game-a",
            title: "Old title",
            summary: "Old summary",
            detectedAt: detectedAt,
            publishedAt: detectedAt,
            sourceID: "devlog-1",
            isHistorical: true
        ))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        let refreshed = try repository.upsertHistorical(GameLibraryUpdate(
            id: "new-random-id",
            title: "New title",
            summary: "New summary",
            detectedAt: detectedAt.addingTimeInterval(500),
            publishedAt: detectedAt.addingTimeInterval(100),
            url: "https://example.com/post",
            sourceID: "devlog-1",
            isHistorical: true
        ), for: "game-a")

        XCTAssertEqual(refreshed.id, "stable-id")
        let row = try XCTUnwrap(database.context.fetch(FetchDescriptor<DBGameUpdate>()).first)
        XCTAssertEqual(row.id, "stable-id")
        XCTAssertEqual(row.title, "New title")
        XCTAssertEqual(row.summary, "New summary")
        XCTAssertEqual(row.detectedAt, detectedAt)
        XCTAssertEqual(row.url, "https://example.com/post")
    }

    @MainActor
    func testHistoricalAppendDeduplicatesAgainstDatabaseAndWithinBatch() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBGameUpdate(
            id: "existing",
            gameID: "game-a",
            summary: "Existing",
            url: "https://example.com/existing",
            sourceID: "source-existing",
            isHistorical: true
        ))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        let inserted = try repository.appendHistoricalUpdates([
            GameLibraryUpdate(id: "duplicate-source", summary: "Duplicate", sourceID: "source-existing"),
            GameLibraryUpdate(id: "new-one", summary: "New", url: "https://example.com/new", sourceID: "source-new", isHistorical: true),
            GameLibraryUpdate(id: "duplicate-url", summary: "Duplicate URL", url: "https://example.com/new", isHistorical: true)
        ], for: "game-a")

        XCTAssertEqual(inserted.map { $0.id }, ["new-one"])
        let rows = try database.context.fetch(FetchDescriptor<DBGameUpdate>())
        XCTAssertEqual(Set(rows.map(\.id)), ["existing", "new-one"])
    }

    @MainActor
    func testHistoricalAppendRejectsSameGameIDCollisionWithoutOverwriting() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBGameUpdate(
            id: "collision",
            gameID: "game-a",
            title: "Original",
            summary: "Must remain unchanged",
            url: "https://example.com/original",
            sourceID: "original-source",
            isHistorical: true
        ))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        XCTAssertThrowsError(try repository.appendHistoricalUpdates([
            GameLibraryUpdate(
                id: "collision",
                title: "Replacement",
                summary: "Must not overwrite",
                url: "https://example.com/different",
                sourceID: "different-source",
                isHistorical: true
            )
        ], for: "game-a", save: false))

        let rows = try database.context.fetch(FetchDescriptor<DBGameUpdate>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "collision")
        XCTAssertEqual(rows.first?.title, "Original")
        XCTAssertEqual(rows.first?.summary, "Must remain unchanged")
        XCTAssertEqual(rows.first?.sourceID, "original-source")
        XCTAssertFalse(database.context.hasChanges)
    }

    @MainActor
    func testDetectedUpdateLookupIsScopedToGameAndTimestamp() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        database.context.insert(DBGameUpdate(id: "detected", gameID: "game-a", summary: "Changed", detectedAt: date))
        database.context.insert(DBGameUpdate(id: "other-game", gameID: "game-b", summary: "Changed", detectedAt: date))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        XCTAssertEqual(try repository.detectedUpdateID(gameID: "game-a", detectedAt: date), "detected")
        XCTAssertNil(try repository.detectedUpdateID(gameID: "game-c", detectedAt: date))
    }

    @MainActor
    func testSynchronizeCanDeferSave() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        let repository = GameUpdateRepository(database: database)

        try repository.synchronize([
            GameLibraryUpdate(id: "pending", summary: "Pending")
        ], for: "game-a", save: false)

        XCTAssertTrue(database.context.hasChanges)
        try database.save()
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBGameUpdate>()).map(\.id), ["pending"])
    }

    @MainActor
    func testSynchronizeRejectsMissingGameBeforeInsertingUpdates() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "A"))
        try database.save()

        let repository = GameUpdateRepository(database: database)
        XCTAssertThrowsError(try repository.synchronize([
            GameLibraryUpdate(id: "orphan-update", summary: "Must not persist")
        ], for: "missing-game", save: false)) { error in
            XCTAssertEqual(
                error as? DatabaseReferenceValidator.ValidationError,
                .missingGame("missing-game")
            )
        }

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBGameUpdate>()).isEmpty)
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBGame>()).first?.title, "A")
    }


    @MainActor
    func testHistoricalAppendSaveFailureRollsBackEntireBatch() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()
        let repository = GameUpdateRepository(database: database)
        let updates = [
            GameLibraryUpdate(id: "historical-a", title: "A", sourceID: "source-a", isHistorical: true),
            GameLibraryUpdate(id: "historical-b", title: "B", sourceID: "source-b", isHistorical: true)
        ]
        database.simulatedSaveError = { NSError(domain: "test", code: 1) }

        XCTAssertThrowsError(try repository.appendHistoricalUpdates(updates, for: "game-a"))
        database.simulatedSaveError = nil

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBGameUpdate>()).isEmpty)
    }
}
