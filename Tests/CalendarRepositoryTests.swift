import XCTest
import SwiftData
@testable import itchPocket

final class CalendarRepositoryTests: XCTestCase {
    @MainActor
    func testUpsertAndLoadPreserveCompleteCalendarSnapshot() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()
        let repository = CalendarRepository(database: database)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        try repository.upsert(StoredCalendarEvent(
            id: "event-a",
            gameID: "game-a",
            title: "Play",
            date: date,
            kind: "计划游玩",
            reminderEnabled: false,
            reminderMinutes: 15,
            notes: "Bring save file",
            sourceFingerprint: "manual-a",
            gameTitleSnapshot: "Example Game"
        ))

        let loaded = try XCTUnwrap(repository.loadEvents().first)
        XCTAssertEqual(loaded.id, "event-a")
        XCTAssertEqual(loaded.gameID, "game-a")
        XCTAssertEqual(loaded.title, "Play")
        XCTAssertEqual(loaded.date, date)
        XCTAssertEqual(loaded.kind, "计划游玩")
        XCTAssertFalse(loaded.reminderEnabled)
        XCTAssertEqual(loaded.reminderMinutes, 15)
        XCTAssertEqual(loaded.notes, "Bring save file")
        XCTAssertEqual(loaded.sourceFingerprint, "manual-a")
        XCTAssertEqual(loaded.gameTitleSnapshot, "Example Game")
    }

    @MainActor
    func testUpsertPreservesExistingSourceUpdateLinkWhenIncomingLinkIsOmitted() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()
        let repository = CalendarRepository(database: database)
        let event = StoredCalendarEvent(id: "event-a", gameID: "game-a", title: "Update", kind: "游戏更新")

        try repository.upsert(event, sourceUpdateID: "update-a")
        try repository.upsert(StoredCalendarEvent(
            id: "event-a",
            gameID: "game-a",
            title: "Edited title",
            kind: "游戏更新"
        ))

        XCTAssertEqual(try repository.loadEvents().first?.sourceUpdateID, "update-a")
        XCTAssertEqual(try repository.loadEvents().first?.title, "Edited title")
    }

    @MainActor
    func testSourceUpdateLinkCanBeReplacedOrExplicitlyCleared() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()
        let repository = CalendarRepository(database: database)
        let event = StoredCalendarEvent(id: "event-a", gameID: "game-a", kind: "游戏更新")

        try repository.upsert(event, sourceUpdateID: "update-a")
        try repository.upsert(event, sourceUpdateID: "update-b")
        XCTAssertEqual(try repository.loadEvents().first?.sourceUpdateID, "update-b")

        try repository.upsert(event, clearSourceUpdateLink: true)
        XCTAssertNil(try repository.loadEvents().first?.sourceUpdateID)
    }

    @MainActor
    func testUpsertCanDeferSaveForCallerBatching() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()
        let repository = CalendarRepository(database: database)

        try repository.upsert(StoredCalendarEvent(
            id: "pending",
            gameID: "game-a",
            title: "Pending",
            kind: "其他"
        ), save: false)

        XCTAssertTrue(database.context.hasChanges)
        try database.save()
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(try repository.loadEvents().map(\.id), ["pending"])
    }

    @MainActor
    func testDeleteRemovesOnlyRequestedCalendarEvent() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()
        let repository = CalendarRepository(database: database)
        try repository.upsert(StoredCalendarEvent(id: "keep", gameID: "game-a", kind: "其他"))
        try repository.upsert(StoredCalendarEvent(id: "remove", gameID: "game-a", kind: "其他"))

        try repository.delete(id: "remove")

        XCTAssertEqual(try repository.loadEvents().map(\.id), ["keep"])
    }

    @MainActor
    func testUpsertRejectsMissingGameBeforeMutatingContext() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = CalendarRepository(database: database)
        let event = StoredCalendarEvent(id: "orphan", gameID: "missing-game", kind: "其他")

        XCTAssertThrowsError(try repository.upsert(event)) { error in
            XCTAssertEqual(error as? DatabaseReferenceValidator.ValidationError, .missingGame("missing-game"))
        }
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBCalendarEvent>()).isEmpty)
    }

    @MainActor
    func testUpsertRejectsSourceUpdateOwnedByAnotherGameBeforeMutation() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        database.context.insert(DBGame(id: "game-b", title: "Game B"))
        database.context.insert(DBGameUpdate(id: "update-b", gameID: "game-b"))
        try database.save()
        let repository = CalendarRepository(database: database)
        let event = StoredCalendarEvent(id: "event-a", gameID: "game-a", kind: "游戏更新")

        XCTAssertThrowsError(try repository.upsert(event, sourceUpdateID: "update-b")) { error in
            XCTAssertEqual(error as? DatabaseReferenceValidator.ValidationError, .calendarUpdateGameMismatch(eventGameID: "game-a", updateID: "update-b", updateGameID: "game-b"))
        }
        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBCalendarEvent>()).isEmpty)
    }
}
