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

        let legacy = try XCTUnwrap(context.fetch(
            FetchDescriptor<DBLibraryCollection>(predicate: #Predicate { $0.id == collection.id })
        ).first)
        XCTAssertEqual(legacy.gameIDs, ["game-b", "game-a"])

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
    func testLegacyCollectionArrayCanBeReadWhenJoinRowsAreAbsent() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBLibraryCollection(
            id: "legacy",
            title: "Legacy",
            gameIDs: ["game-a", "game-a"]
        ))
        try database.save()

        let repository = LibraryRepository(database: database)
        XCTAssertEqual(try repository.collections().first?.gameIDs, ["game-a"])
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
            gameIDs: ["game-a"]
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

        XCTAssertNotNil(try database.game(id: "game-a"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBGameUpdate>()).map(\.id), ["update-a"])
        let calendar = try XCTUnwrap(context.fetch(FetchDescriptor<DBCalendarEvent>()).first)
        XCTAssertEqual(calendar.sourceUpdateID, "update-a")
        XCTAssertEqual(calendar.gameTitleSnapshot, "Game A")
        XCTAssertTrue(try context.fetch(FetchDescriptor<DBLibraryEntry>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DBSparkMetadata>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DBLibraryStatusEvent>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DBLibraryCollectionItem>()).isEmpty)
        XCTAssertEqual(collection.gameIDs, [])
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
        XCTAssertNotNil(try database.game(id: "game-a"))
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBLibraryCollectionItem>()).isEmpty)
    }
}
