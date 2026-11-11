import XCTest
import SwiftData
@testable import itchPocket

final class RepositoryIntegrationTests: XCTestCase {
    @MainActor
    func testDiscoveryCacheRepositoryStoresExpiresAndRemovesPayload() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DiscoveryCacheRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = Data("cached-discovery".utf8)

        try repository.save(payload: payload, for: "discovery", timeToLive: 60, fetchedAt: now)
        XCTAssertEqual(try repository.payload(for: "discovery", now: now), payload)
        XCTAssertNil(try repository.payload(for: "discovery", now: now.addingTimeInterval(61)))

        try repository.save(payload: payload, for: "discovery", timeToLive: 60, fetchedAt: now)
        try repository.remove(key: "discovery")
        XCTAssertNil(try repository.payload(for: "discovery", now: now))
    }

    @MainActor
    func testTranslationCacheRepositoryUpdatesAndRetainsNewestEntries() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = TranslationCacheRepository(
            database: database,
            maximumEntries: 3,
            retainedEntries: 2
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try repository.store("一", source: "one", scope: "description", target: "zh-CN", for: "one", updatedAt: start)
        try repository.store("二", source: "two", scope: "description", target: "zh-CN", for: "two", updatedAt: start.addingTimeInterval(1))
        try repository.store("三", source: "three", scope: "description", target: "zh-CN", for: "three", updatedAt: start.addingTimeInterval(2))
        try repository.store("四", source: "four", scope: "description", target: "zh-CN", for: "four", updatedAt: start.addingTimeInterval(3))

        XCTAssertNil(try repository.translation(for: "one"))
        XCTAssertEqual(try repository.translation(for: "four")?.translation, "四")
        XCTAssertEqual(try repository.latest(scope: "description", target: "zh-CN")?.translation, "四")
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBTranslation>()), 2)
    }

    @MainActor
    func testCalendarRepositoryPreservesLinkedUpdateWhenEditingEvent() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-1", title: "Game One", gameURL: "https://example.com/game"))
        database.context.insert(DBGameUpdate(
            id: "update-1",
            gameID: "game-1",
            title: "Chapter 2",
            summary: "New chapter",
            detectedAt: Date(timeIntervalSince1970: 1_800_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            url: "https://example.com/update"
        ))
        try database.save()

        let repository = GameCalendarRepository(database: database)
        let event = GameCalendarEvent(
            id: "event-1",
            gameID: "game-1",
            gameTitle: "Game One",
            gameURL: "https://example.com/game",
            title: "Original",
            date: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .update
        )
        try repository.saveEvent(event, sourceUpdateID: "update-1")
        var edited = event
        edited.title = "Edited title"
        edited.notes = "Edited notes"
        try repository.saveEvent(edited)

        let stored = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(stored.title, "更新：Chapter 2")
        XCTAssertEqual(stored.notes, "New chapter\nhttps://example.com/update")
    }

    @MainActor
    func testUpdateMonitorRepositoryUsesScopedContextForIncrementalPersistence() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-1", title: "Game One", gameURL: "https://example.com/game"))
        try database.save()

        let repository = GameUpdateMonitorRepository(database: database)
        let watch = GameUpdateWatch(
            gameID: "game-1",
            gameTitle: "Game One",
            gameURL: "https://example.com/game",
            entityTag: "etag-1",
            lastModified: nil,
            contentHash: "hash-1",
            lastCheckedAt: Date(timeIntervalSince1970: 1_800_000_000),
            hasBaseline: true,
            isEnabled: true
        )
        try repository.save(watch)
        XCTAssertEqual(try repository.watches().first?.entityTag, "etag-1")

        try repository.remove(gameID: "game-1")
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBUpdateWatch>()).isEmpty)
    }

    @MainActor
    func testPersonalLibraryBlocksWritesUntilAllSnapshotsReloadSuccessfully() throws {
        let database = try AppDatabase(inMemory: true)
        var shouldFail = true
        let store = PersonalLibraryStore(
            database: database,
            shouldSimulateLibraryLoadFailure: { shouldFail }
        )

        store.createCollection(title: "Blocked on first load")
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBLibraryCollection>()).isEmpty)

        shouldFail = false
        store.reload()
        store.createCollection(title: "Allowed after recovery")
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBLibraryCollection>()).map(\.title), ["Allowed after recovery"])

        shouldFail = true
        store.reload()
        store.createCollection(title: "Blocked after failed reload")
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBLibraryCollection>()).map(\.title), ["Allowed after recovery"])
    }


    @MainActor
    func testCalendarStoreBlocksWritesUntilReadSucceedsAndRetainsLastGoodSnapshot() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = GameCalendarRepository(database: database)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = GameCalendarEvent(
            id: "existing-event",
            gameID: "game-1",
            gameTitle: "Game One",
            gameURL: "https://example.com/game",
            title: "Existing event",
            date: date,
            kind: .custom,
            reminderEnabled: false,
            sourceFingerprint: "detected-1"
        )
        try repository.saveEvent(existing)

        var shouldFail = true
        let store = GameCalendarStore(
            repository: repository,
            shouldSimulateLoadFailure: { shouldFail }
        )

        let blockedManualEvent = GameCalendarEvent(
            id: "blocked-event",
            gameID: "game-1",
            gameTitle: "Game One",
            gameURL: nil,
            title: "Must not be written",
            date: date,
            kind: .custom
        )
        store.add(blockedManualEvent)

        let detected = DetectedGameUpdate(
            gameID: "game-1",
            gameTitle: "Game One",
            gameURL: "https://example.com/game",
            summary: "Detected change",
            fingerprint: "detected-1",
            detectedAt: date
        )
        XCTAssertEqual(store.addDetectedUpdates([detected]), 0)

        let historical = GameLibraryUpdate(
            title: "Chapter 1",
            summary: "Historical update",
            publishedAt: date,
            sourceID: "devlog-1",
            isHistorical: true
        )
        XCTAssertEqual(
            store.addHistoricalUpdates(
                gameID: "game-1",
                gameTitle: "Game One",
                gameURL: "https://example.com/game",
                updates: [historical]
            ),
            0
        )
        store.delete("existing-event")

        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 1)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGameUpdate>()), 0)

        shouldFail = false
        store.reload()
        XCTAssertEqual(store.events.map(\.id), ["existing-event"])
        XCTAssertEqual(store.addDetectedUpdates([detected]), 0)
        XCTAssertEqual(
            store.addHistoricalUpdates(
                gameID: "game-1",
                gameTitle: "Game One",
                gameURL: "https://example.com/game",
                updates: [historical]
            ),
            1
        )
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 2)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGameUpdate>()), 1)

        shouldFail = true
        store.reload()
        XCTAssertEqual(store.events.count, 2)
        XCTAssertTrue(store.events.contains { $0.id == "existing-event" })
        XCTAssertTrue(store.events.contains { $0.sourceFingerprint == "devlog:devlog-1" })
        XCTAssertEqual(
            store.addHistoricalUpdates(
                gameID: "game-1",
                gameTitle: "Game One",
                gameURL: "https://example.com/game",
                updates: [historical]
            ),
            0
        )
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 2)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGameUpdate>()), 1)
    }

}
