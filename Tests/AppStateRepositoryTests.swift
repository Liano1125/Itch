import XCTest
import SwiftData
@testable import itchPocket

final class AppStateRepositoryTests: XCTestCase {
    @MainActor
    func testTypedValuesCanBeStoredAndLoadedWithoutLosingOtherColumns() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = AppStateRepository(database: database)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data("sync-results".utf8)

        try repository.setString("complete", for: "state.string")
        try repository.setDate(date, for: "state.date")
        try repository.setData(data, for: "state.data")

        XCTAssertEqual(try repository.state(for: "state.string")?.stringValue, "complete")
        XCTAssertEqual(try repository.state(for: "state.date")?.dateValue, date)
        XCTAssertEqual(try repository.state(for: "state.data")?.dataValue, data)
    }

    @MainActor
    func testUpdatingOneTypedValuePreservesOtherStoredColumns() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = AppStateRepository(database: database)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data([1, 2, 3])

        try repository.setString("old", for: "mixed")
        try repository.setDate(date, for: "mixed")
        try repository.setData(data, for: "mixed")
        try repository.setString("new", for: "mixed")

        let stored = try XCTUnwrap(repository.state(for: "mixed"))
        XCTAssertEqual(stored.stringValue, "new")
        XCTAssertEqual(stored.dateValue, date)
        XCTAssertEqual(stored.dataValue, data)
    }

    @MainActor
    func testPrefixRemovalOnlyDeletesMatchingKeys() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = AppStateRepository(database: database)
        try repository.setDate(.now, for: "avatarFailure.one")
        try repository.setDate(.now, for: "avatarFailure.two")
        try repository.setString("keep", for: "devlogSync.lastMessage")

        try repository.removeAll(matchingKeyPrefix: "avatarFailure.")

        XCTAssertNil(try repository.state(for: "avatarFailure.one"))
        XCTAssertNil(try repository.state(for: "avatarFailure.two"))
        XCTAssertEqual(try repository.state(for: "devlogSync.lastMessage")?.stringValue, "keep")
    }

    @MainActor
    func testSetCanDeferSaveForCallerBatching() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = AppStateRepository(database: database)

        try repository.setString("pending", for: "batch.test", save: false)

        XCTAssertTrue(database.context.hasChanges)
        try database.save()
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(try repository.state(for: "batch.test")?.stringValue, "pending")
    }

    @MainActor
    func testRemoveAllCanDeferSaveAndDoesNotTouchOtherModels() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = AppStateRepository(database: database)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try repository.setString("one", for: "one")
        try repository.setString("two", for: "two")
        try database.save()

        try repository.removeAll(save: false)

        XCTAssertTrue(database.context.hasChanges)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBAppState>()), 0)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGame>()), 1)
    }
}
