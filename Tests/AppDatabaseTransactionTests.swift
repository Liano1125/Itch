import XCTest
import SwiftData
@testable import itchPocket

final class AppDatabaseTransactionTests: XCTestCase {
    private enum TestError: Error {
        case simulatedFailure
    }

    @MainActor
    func testFailedTransactionRollsBackOnlyItsOwnCleanContextChanges() throws {
        let database = try AppDatabase(inMemory: true)

        XCTAssertThrowsError(try database.performTransaction {
            database.context.insert(DBAppState(key: "transaction.partial", stringValue: "discard"))
            throw TestError.simulatedFailure
        })

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBAppState>()).isEmpty)
    }

    @MainActor
    func testFailedDirectSaveRollsBackContextAndAllowsLaterTransactions() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBAppState(key: "save.failure", stringValue: "discard"))
        database.simulatedSaveError = { TestError.simulatedFailure }

        XCTAssertThrowsError(try database.save())
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBAppState>()).isEmpty)

        database.simulatedSaveError = nil
        try database.performTransaction {
            database.context.insert(DBAppState(key: "save.recovered", stringValue: "persist"))
        }
        XCTAssertEqual(
            try database.context.fetch(FetchDescriptor<DBAppState>()).map(\.key),
            ["save.recovered"]
        )
    }

    @MainActor
    func testTransactionRefusesToRollbackPreexistingPendingChanges() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBAppState(key: "unrelated.pending", stringValue: "preserve"))

        XCTAssertThrowsError(try database.performTransaction {
            database.context.insert(DBAppState(key: "transaction.partial", stringValue: "discard"))
        }) { error in
            XCTAssertTrue(error is AppDatabase.TransactionError)
        }

        XCTAssertTrue(database.context.hasChanges)
        let pending = try database.context.fetch(FetchDescriptor<DBAppState>())
        XCTAssertEqual(Set(pending.map(\.key)), ["unrelated.pending"])
        try database.save()
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBAppState>()).map(\.key), ["unrelated.pending"])
    }

    @MainActor
    func testSuccessfulTransactionSavesAllChangesTogether() throws {
        let database = try AppDatabase(inMemory: true)

        try database.performTransaction {
            database.context.insert(DBAppState(key: "transaction.first", stringValue: "one"))
            database.context.insert(DBAppState(key: "transaction.second", stringValue: "two"))
        }

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(
            Set(try database.context.fetch(FetchDescriptor<DBAppState>()).map(\.key)),
            ["transaction.first", "transaction.second"]
        )
    }
    @MainActor
    func testFailedTransactionRestoresUpdatedRowsAndDiscardsNewRows() throws {
        let database = try AppDatabase(inMemory: true)
        let developer = DBDeveloper(id: "developer-a", name: "Original")
        database.context.insert(developer)
        try database.save()

        XCTAssertThrowsError(try database.performTransaction {
            developer.name = "Partially updated"
            database.context.insert(DBLibraryEntry(gameID: "game-a", status: "在玩"))
            throw TestError.simulatedFailure
        })

        let storedDeveloper = try XCTUnwrap(database.context.fetch(
            FetchDescriptor<DBDeveloper>(predicate: #Predicate { $0.id == "developer-a" })
        ).first)
        XCTAssertEqual(storedDeveloper.name, "Original")
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBLibraryEntry>()).isEmpty)
        XCTAssertFalse(database.context.hasChanges)
    }

    @MainActor
    func testRemoveAllAppDataDeletesPersistedRowsAcrossRepositories() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBDeveloper(id: "cleanup-developer", name: "Developer"))
        database.context.insert(DBGame(id: "cleanup-game", title: "Game"))
        database.context.insert(DBAppState(key: "cleanup.state", stringValue: "value"))
        try database.save()

        try database.removeAllAppData()

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBDeveloper>()), 0)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGame>()), 0)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBAppState>()), 0)
    }

    @MainActor
    func testRemoveAllAppDataRefusesPreexistingPendingChanges() throws {
        let database = try AppDatabase(inMemory: true)
        let durableGame = DBGame(id: "cleanup-durable-game", title: "Durable")
        database.context.insert(durableGame)
        try database.save()
        database.context.insert(DBAppState(key: "cleanup.pending", stringValue: "preserve"))

        XCTAssertThrowsError(try database.removeAllAppData()) { error in
            XCTAssertTrue(error is AppDatabase.TransactionError)
        }

        XCTAssertTrue(database.context.hasChanges)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGame>()), 1)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBAppState>()), 1)
        try database.save()
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGame>()), 1)
    }

    @MainActor
    func testFailedCleanupTransactionRestoresDeletedRows() throws {
        let database = try AppDatabase(inMemory: true)
        let game = DBGame(id: "cleanup-rollback-game", title: "Keep")
        let state = DBAppState(key: "cleanup.rollback", stringValue: "keep")
        database.context.insert(game)
        database.context.insert(state)
        try database.save()

        XCTAssertThrowsError(try database.performTransaction {
            try AppStateRepository(database: database).removeAll(save: false)
            database.context.delete(game)
            throw TestError.simulatedFailure
        })

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGame>()), 1)
        let restored = try XCTUnwrap(AppStateRepository(database: database).state(for: "cleanup.rollback"))
        XCTAssertEqual(restored.stringValue, "keep")
    }

    @MainActor
    func testRepositoryContextProvidesScopedPersistenceOperations() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.repositoryContext
        let row = DBAppState(key: "repository.context", stringValue: "scoped")

        context.insert(row)
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAppState>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBAppState>()).first?.stringValue, "scoped")

        context.delete(row)
        try database.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAppState>()), 0)
        XCTAssertFalse(context.hasChanges)
    }


    @MainActor
    func testFailedFullDatabaseClearRestoresEveryModelTable() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "game-a", title: "Game A"))
        context.insert(DBDeveloper(id: "developer-a", name: "Developer"))
        context.insert(DBGameDetail(gameID: "game-a"))
        context.insert(DBLibraryEntry(gameID: "game-a", status: "在玩"))
        context.insert(DBLibraryCollection(id: "collection-a", title: "Collection"))
        context.insert(DBLibraryCollectionItem(
            id: "membership-a",
            collectionID: "collection-a",
            gameID: "game-a",
            sortOrder: 0
        ))
        context.insert(DBLibraryStatusEvent(
            id: "status-a",
            gameID: "game-a",
            fromStatus: nil,
            toStatus: "在玩"
        ))
        context.insert(DBUpdateWatch(gameID: "game-a"))
        context.insert(DBDiscoverySnapshot(
            key: "discovery-a",
            payload: Data("payload".utf8),
            expiresAt: .now.addingTimeInterval(3600)
        ))
        context.insert(DBTranslation(
            cacheKey: "translation-a",
            scope: "description",
            sourceHash: "hash",
            sourceText: "source",
            targetLanguage: "zh-CN",
            translatedText: "translated"
        ))
        context.insert(DBSparkMetadata(gameID: "game-a", runtimeSeconds: 10))
        context.insert(DBCalendarEvent(id: "calendar-a", gameID: "game-a", kind: "custom"))
        context.insert(DBGameUpdate(id: "update-a", gameID: "game-a", summary: "Update", detectedAt: .now))
        context.insert(DBAppState(key: "state-a", stringValue: "keep"))
        try database.save()

        database.simulatedSaveError = { TestError.simulatedFailure }
        XCTAssertThrowsError(try database.removeAllAppData())
        database.simulatedSaveError = nil

        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGame>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBDeveloper>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGameDetail>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryCollection>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryCollectionItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryStatusEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBUpdateWatch>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBDiscoverySnapshot>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBTranslation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBSparkMetadata>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGameUpdate>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAppState>()), 1)
    }
}
