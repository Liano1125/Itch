import XCTest
import SwiftData
@testable import itchPocket

final class LibraryRepositoryTests: XCTestCase {
    @MainActor
    func testCollectionMembershipUsesStableJoinRowsAndPreservesOrder() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "game-a", title: "Game A"))
        context.insert(DBGame(id: "game-b", title: "Game B"))
        try database.save()

        let repository = LibraryRepository(database: database)
        let collection = try repository.createCollection(title: "  Favorites  ")
        var edited = collection
        edited.gameIDs = ["game-b", "game-a", "game-b"]
        let saved = try repository.updateCollection(edited)

        XCTAssertEqual(saved.title, "Favorites")
        XCTAssertEqual(saved.gameIDs, ["game-b", "game-a"])

        let items = try context.fetch(
            FetchDescriptor<DBLibraryCollectionItem>(predicate: #Predicate { $0.collectionID == collection.id })
        ).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(items.map(\.gameID), ["game-b", "game-a"])
        XCTAssertEqual(items.map(\.sortOrder), [0, 1])
        XCTAssertEqual(items.map(\.id), [
            DBLibraryCollectionItem.stableID(collectionID: collection.id, gameID: "game-b"),
            DBLibraryCollectionItem.stableID(collectionID: collection.id, gameID: "game-a")
        ])
    }

    @MainActor
    func testUpdatingCollectionPreservesExistingMembershipAddedAt() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        try database.save()

        let repository = LibraryRepository(database: database)
        let collection = try repository.createCollection(title: "Favorites")
        let firstAddedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var edited = collection
        edited.gameIDs = ["game-a", "game-b"]
        _ = try repository.updateCollection(edited, now: firstAddedAt)

        var reordered = edited
        reordered.gameIDs = ["game-b", "game-a"]
        _ = try repository.updateCollection(reordered, now: firstAddedAt.addingTimeInterval(500))

        let items = try database.context.fetch(
            FetchDescriptor<DBLibraryCollectionItem>(predicate: #Predicate { $0.collectionID == collection.id })
        )
        XCTAssertTrue(items.allSatisfy { $0.addedAt == firstAddedAt })
        XCTAssertEqual(items.sorted { $0.sortOrder < $1.sortOrder }.map(\.gameID), ["game-b", "game-a"])
    }

    @MainActor
    func testCollectionReadUsesNormalizedMembershipRowsOnly() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBLibraryCollection(id: "collection", title: "Collection"))
        database.context.insert(DBLibraryCollectionItem(
            id: DBLibraryCollectionItem.stableID(collectionID: "collection", gameID: "game-b"),
            collectionID: "collection",
            gameID: "game-b",
            sortOrder: 0
        ))
        try database.save()

        let repository = LibraryRepository(database: database)
        XCTAssertEqual(try repository.collections().first?.gameIDs, ["game-b"])
    }

    @MainActor
    func testToggleCollectionMembershipAddsAndRemovesWithoutLosingOrder() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        try database.save()

        let repository = LibraryRepository(database: database)
        let collection = try repository.createCollection(title: "Queue")
        _ = try repository.toggleGame("game-a", in: collection.id)
        _ = try repository.toggleGame("game-b", in: collection.id)
        let removed = try repository.toggleGame("game-a", in: collection.id)

        XCTAssertEqual(removed.gameIDs, ["game-b"])
        XCTAssertEqual(try repository.collections().first?.gameIDs, ["game-b"])
    }

    @MainActor
    func testCollectionWithoutMembershipRowsLoadsAsEmpty() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBLibraryCollection(id: "empty", title: "Empty"))
        try database.save()

        XCTAssertEqual(try LibraryRepository(database: database).collections().first?.gameIDs, [])
    }

    @MainActor
    func testRemovingGameFromLibraryPreservesGameUpdatesAndCalendarLinks() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "game-a", title: "Game A"))
        context.insert(DBLibraryEntry(gameID: "game-a", status: "在玩"))
        context.insert(DBSparkMetadata(gameID: "game-a", runtimeSeconds: 120))
        context.insert(DBLibraryStatusEvent(
            id: "status-a",
            gameID: "game-a",
            fromStatus: nil,
            toStatus: "在玩"
        ))
        context.insert(DBGameUpdate(
            id: "update-a",
            gameID: "game-a",
            summary: "A published update"
        ))
        context.insert(DBCalendarEvent(
            id: "calendar-a",
            gameID: "game-a",
            title: "Update",
            kind: "update",
            sourceUpdateID: "update-a",
            gameTitleSnapshot: "Game A"
        ))
        let collection = DBLibraryCollection(
            id: "collection-a",
            title: "Collection",
        )
        context.insert(collection)
        context.insert(DBLibraryCollectionItem(
            id: DBLibraryCollectionItem.stableID(collectionID: "collection-a", gameID: "game-a"),
            collectionID: "collection-a",
            gameID: "game-a",
            sortOrder: 0
        ))
        try database.save()

        let repository = LibraryRepository(database: database)
        try repository.removeGameFromLibrary(gameID: "game-a")

        XCTAssertNotNil(try GameRepository(database: database).game(id: "game-a"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBGameUpdate>()).map(\.id), ["update-a"])
        let calendar = try XCTUnwrap(context.fetch(FetchDescriptor<DBCalendarEvent>()).first)
        XCTAssertEqual(calendar.sourceUpdateID, "update-a")
        XCTAssertEqual(calendar.gameTitleSnapshot, "Game A")
        XCTAssertTrue(try context.fetch(FetchDescriptor<DBLibraryEntry>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DBSparkMetadata>()).isEmpty)
        let preservedStatusEvents = try context.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        XCTAssertEqual(preservedStatusEvents.map(\.id), ["status-a"])
        XCTAssertEqual(preservedStatusEvents.first?.toStatus, "在玩")
        XCTAssertTrue(try context.fetch(FetchDescriptor<DBLibraryCollectionItem>()).isEmpty)
    }

    @MainActor
    func testFailedLibraryRemovalDoesNotLeavePartialPendingDeletions() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "game-a", title: "Game A"))
        context.insert(DBLibraryEntry(gameID: "game-a", status: "在玩"))
        context.insert(DBSparkMetadata(gameID: "game-a", runtimeSeconds: 60))
        context.insert(DBLibraryStatusEvent(
            id: "status-a",
            gameID: "game-a",
            fromStatus: nil,
            toStatus: "在玩"
        ))
        context.insert(DBLibraryCollection(
            id: "collection-a",
            title: "Collection",
        ))
        context.insert(DBLibraryCollectionItem(
            id: DBLibraryCollectionItem.stableID(collectionID: "collection-a", gameID: "game-b"),
            collectionID: "collection-a",
            gameID: "game-b",
            sortOrder: 0
        ))
        try database.save()

        let repository = LibraryRepository(database: database)
        XCTAssertThrowsError(try repository.removeGameFromLibrary(gameID: "game-a"))

        XCTAssertNotNil(try context.fetch(FetchDescriptor<DBLibraryEntry>()).first)
        XCTAssertNotNil(try context.fetch(FetchDescriptor<DBSparkMetadata>()).first)
        XCTAssertNotNil(try context.fetch(FetchDescriptor<DBLibraryStatusEvent>()).first)
        let collection = try XCTUnwrap(context.fetch(FetchDescriptor<DBLibraryCollection>()).first)
    }

    @MainActor
    func testDeletingCollectionDoesNotDeleteItsGames() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()

        let repository = LibraryRepository(database: database)
        let collection = try repository.createCollection(title: "Temporary")
        var edited = collection
        edited.gameIDs = ["game-a"]
        _ = try repository.updateCollection(edited)

        try repository.deleteCollection(id: collection.id)

        XCTAssertTrue(try repository.collections().isEmpty)
        XCTAssertNotNil(try GameRepository(database: database).game(id: "game-a"))
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBLibraryCollectionItem>()).isEmpty)
    }

    @MainActor
    func testLibraryEntryLoadReturnsImmutableSnapshots() throws {
        let database = try AppDatabase(inMemory: true)
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = addedAt.addingTimeInterval(300)
        database.context.insert(DBLibraryEntry(
            gameID: "game-a", status: "在玩", isFavorite: true,
            notes: "keep", addedAt: addedAt, updatedAt: updatedAt
        ))
        try database.save()

        let entries = try LibraryRepository(database: database).loadEntries()
        XCTAssertEqual(entries, [
            StoredLibraryEntry(gameID: "game-a", status: "在玩", isFavorite: true,
                               notes: "keep", addedAt: addedAt, updatedAt: updatedAt)
        ])
    }

    @MainActor
    func testLibraryEntryUpsertInsertsAndUpdatesOnlyRequestedGame() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "game-a", title: "Game A"))
        context.insert(DBGame(id: "game-b", title: "Game B"))
        context.insert(DBGame(id: "game-c", title: "Game C"))
        context.insert(DBLibraryEntry(gameID: "game-a", status: "在玩", notes: "old"))
        context.insert(DBLibraryEntry(gameID: "game-b", status: "已完成", notes: "untouched"))
        try database.save()

        let repository = LibraryRepository(database: database)
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try repository.upsertEntry(StoredLibraryEntry(
            gameID: "game-a", status: "已完成", isFavorite: true,
            notes: "updated", addedAt: addedAt, updatedAt: addedAt
        ), save: false)
        try repository.upsertEntry(StoredLibraryEntry(
            gameID: "game-c", status: "想玩", isFavorite: false,
            notes: "", addedAt: addedAt, updatedAt: addedAt
        ), save: false)
        try database.save()

        let entries = Dictionary(uniqueKeysWithValues: try repository.loadEntries().map { ($0.gameID, $0) })
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries["game-a"]?.status, "已完成")
        XCTAssertEqual(entries["game-a"]?.notes, "updated")
        XCTAssertEqual(entries["game-b"]?.notes, "untouched")
        XCTAssertEqual(entries["game-c"]?.status, "想玩")
    }

    @MainActor
    func testLibraryEntryUpsertCanDeferSave() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()
        let repository = LibraryRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try repository.upsertEntry(StoredLibraryEntry(
            gameID: "game-a", status: "在玩", isFavorite: false,
            notes: "", addedAt: now, updatedAt: now
        ), save: false)

        XCTAssertTrue(database.context.hasChanges)
        try database.save()
        XCTAssertEqual(try repository.loadEntries().map(\.gameID), ["game-a"])
    }



    @MainActor
    func testLibraryEntryReadValidationRejectsDuplicateGameIDs() throws {
        XCTAssertNoThrow(try LibraryRepository.validateUniqueGameIDs(["game-a", "game-b"]))

        XCTAssertThrowsError(
            try LibraryRepository.validateUniqueGameIDs(["game-a", "game-b", "game-a"])
        ) { error in
            guard let repositoryError = error as? LibraryRepository.RepositoryError else {
                return XCTFail("Expected RepositoryError, got \\(error)")
            }
            guard case .duplicateLibraryEntry("game-a") = repositoryError else {
                return XCTFail("Expected duplicateLibraryEntry, got \\(repositoryError)")
            }
        }
    }


    @MainActor
    func testLibraryEntryUpsertRejectsMissingGameBeforeMutation() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = LibraryRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertThrowsError(try repository.upsertEntry(StoredLibraryEntry(gameID: "missing-game", status: "在玩", isFavorite: false, notes: "", addedAt: now, updatedAt: now))) { error in
            XCTAssertEqual(error as? DatabaseReferenceValidator.ValidationError, .missingGame("missing-game"))
        }
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBLibraryEntry>()).isEmpty)
    }
}
