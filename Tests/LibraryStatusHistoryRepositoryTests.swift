import XCTest
import SwiftData
@testable import itchPocket

final class LibraryStatusHistoryRepositoryTests: XCTestCase {
    @MainActor
    func testLoadEventsGroupsRowsByGameAndPreservesEventValues() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        let context = database.context
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(60)
        context.insert(DBLibraryStatusEvent(
            id: "event-a",
            gameID: "game-a",
            fromStatus: nil,
            toStatus: "在玩",
            changedAt: firstDate
        ))
        context.insert(DBLibraryStatusEvent(
            id: "event-b",
            gameID: "game-a",
            fromStatus: "在玩",
            toStatus: "已完成",
            changedAt: secondDate
        ))
        context.insert(DBLibraryStatusEvent(
            id: "event-c",
            gameID: "game-b",
            fromStatus: nil,
            toStatus: "想玩",
            changedAt: firstDate
        ))
        try database.save()

        let repository = LibraryStatusHistoryRepository(database: database)
        let loaded = try repository.loadEvents()

        XCTAssertEqual(Set(loaded.keys), ["game-a", "game-b"])
        XCTAssertEqual(Set(loaded["game-a"]?.map(\.id) ?? []), ["event-a", "event-b"])
        XCTAssertEqual(loaded["game-a"]?.first(where: { $0.id == "event-b" })?.fromStatus, .playing)
        XCTAssertEqual(loaded["game-a"]?.first(where: { $0.id == "event-b" })?.toStatus, .completed)
        XCTAssertEqual(loaded["game-b"]?.first?.toStatus, .wishlist)
    }

    @MainActor
    func testAppendingOneEventNeverDeletesOtherGamesHistory() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBLibraryStatusEvent(
            id: "existing-event",
            gameID: "game-b",
            fromStatus: nil,
            toStatus: "在玩"
        ))
        try database.save()

        let repository = LibraryStatusHistoryRepository(database: database)
        try repository.append(
            LibraryStatusEvent(id: "new-event", fromStatus: .wishlist, toStatus: .playing),
            for: "game-a"
        )

        let rows = try database.context.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        XCTAssertEqual(Set(rows.map(\.id)), ["existing-event", "new-event"])
        XCTAssertEqual(rows.first(where: { $0.id == "existing-event" })?.gameID, "game-b")
    }

    @MainActor
    func testEventIDConflictFailsBeforeMutatingExistingHistory() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBLibraryStatusEvent(
            id: "shared-event",
            gameID: "game-a",
            fromStatus: nil,
            toStatus: "在玩"
        ))
        try database.save()

        let repository = LibraryStatusHistoryRepository(database: database)
        XCTAssertThrowsError(try repository.append(
            LibraryStatusEvent(id: "shared-event", fromStatus: .playing, toStatus: .completed),
            for: "game-b"
        ))

        let row = try XCTUnwrap(database.context.fetch(FetchDescriptor<DBLibraryStatusEvent>()).first)
        XCTAssertEqual(row.gameID, "game-a")
        XCTAssertEqual(row.toStatus, "在玩")
        XCTAssertFalse(database.context.hasChanges)
    }

    @MainActor
    func testAppendCanDeferSaveForCallerBatching() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        let repository = LibraryStatusHistoryRepository(database: database)

        try repository.append(
            LibraryStatusEvent(id: "pending-event", fromStatus: nil, toStatus: .wishlist),
            for: "game-a",
            save: false
        )

        XCTAssertTrue(database.context.hasChanges)
        try database.save()
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(
            try database.context.fetch(FetchDescriptor<DBLibraryStatusEvent>()).map(\.id),
            ["pending-event"]
        )
    }
}
