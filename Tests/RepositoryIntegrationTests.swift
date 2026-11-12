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
        database.context.insert(DBGame(id: "game-1", title: "Game One"))
        try database.save()
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


    @MainActor
    func testUpdateMonitorBlocksMutationsUntilWatchSnapshotLoads() async throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-1", title: "Game One"))
        try database.save()
        var shouldFail = false
        let store = GameUpdateMonitorStore(
            database: database,
            shouldSimulateLoadFailure: { shouldFail }
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = LibraryRecord(
            id: "game-1",
            title: "Game One",
            status: .playing,
            isFavorite: false,
            notes: "",
            addedAt: now,
            updatedAt: now
        )

        store.setEnabled(true, for: record)
        XCTAssertNotNil(store.watch(for: record.id))
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBUpdateWatch>()), 1)

        shouldFail = true
        store.reload()
        store.setEnabled(false, for: record)
        XCTAssertNotNil(store.watch(for: record.id))
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBUpdateWatch>()), 1)

        let calendarStore = GameCalendarStore(repository: GameCalendarRepository(database: database))
        let libraryStore = PersonalLibraryStore(database: database)
        await store.checkAll(calendarStore: calendarStore, libraryStore: libraryStore)
        XCTAssertTrue(store.statusMessage?.contains("尚未成功加载") == true)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBUpdateWatch>()), 1)

        shouldFail = false
        store.reload()
        store.setEnabled(false, for: record)
        XCTAssertNil(store.watch(for: record.id))
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBUpdateWatch>()), 0)
    }


    @MainActor
    func testCalendarStorePublishesChangesOnlyAfterSuccessfulWrites() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-write-guard", title: "Write Guard Game"))
        try database.save()
        let repository = GameCalendarRepository(database: database)
        var shouldFailWrites = false
        let store = GameCalendarStore(
            repository: repository,
            shouldSimulateWriteFailure: { shouldFailWrites }
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let original = GameCalendarEvent(
            id: "write-guard-event",
            gameID: "game-write-guard",
            gameTitle: "Write Guard Game",
            gameURL: nil,
            title: "Original title",
            date: date,
            kind: .custom,
            reminderEnabled: false
        )
        store.add(original)
        XCTAssertEqual(store.events.map(\.title), ["Original title"])
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 1)

        shouldFailWrites = true
        let added = GameCalendarEvent(
            id: "write-guard-added",
            gameID: "game-write-guard",
            gameTitle: "Write Guard Game",
            gameURL: nil,
            title: "Must not appear",
            date: date,
            kind: .custom
        )
        store.add(added)
        var edited = original
        edited.title = "Uncommitted edit"
        store.update(edited)
        store.delete(original.id)

        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events.first?.title, "Original title")
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 1)
        let persisted = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(persisted.title, "Original title")

        shouldFailWrites = false
        edited.title = "Committed edit"
        store.update(edited)
        XCTAssertEqual(store.events.first?.title, "Committed edit")
        XCTAssertEqual(try repository.events().first?.title, "Committed edit")
        store.delete(original.id)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 0)
    }



    @MainActor
    func testCrossStoreDetectedUpdateTransactionRollsBackEveryStoreOnCalendarFailure() throws {
        let database = try AppDatabase(inMemory: true)
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)
        database.context.insert(DBGame(
            id: "cross-store-game",
            title: "Cross Store Game",
            gameURL: "https://example.com/cross-store"
        ))
        database.context.insert(DBLibraryEntry(
            gameID: "cross-store-game",
            status: LibraryStatus.playing.rawValue,
            addedAt: baseline,
            updatedAt: baseline
        ))
        try database.save()

        let libraryStore = PersonalLibraryStore(database: database)
        var shouldFailCalendarStage = true
        let calendarStore = GameCalendarStore(
            repository: GameCalendarRepository(database: database),
            shouldSimulateWriteFailure: { shouldFailCalendarStage }
        )
        let update = DetectedGameUpdate(
            gameID: "cross-store-game",
            gameTitle: "Cross Store Game",
            gameURL: "https://example.com/cross-store",
            summary: "A detected update",
            fingerprint: "cross-store-fingerprint",
            detectedAt: baseline.addingTimeInterval(60)
        )

        XCTAssertNotNil(libraryStore.record(for: "cross-store-game"))
        XCTAssertTrue(calendarStore.events.isEmpty)

        XCTAssertThrowsError(try database.performTransaction {
            _ = try libraryStore.stageDetectedUpdates([update])
            _ = try calendarStore.stageDetectedUpdates([update])
        })

        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGameUpdate>()), 0)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 0)
        let persistedEntry = try XCTUnwrap(
            database.context.fetch(FetchDescriptor<DBLibraryEntry>()).first
        )
        XCTAssertEqual(persistedEntry.updatedAt, baseline)
        XCTAssertTrue(libraryStore.updates(for: "cross-store-game").isEmpty)
        XCTAssertTrue(calendarStore.events.isEmpty)

        shouldFailCalendarStage = false
        try database.performTransaction {
            _ = try libraryStore.stageDetectedUpdates([update])
            _ = try calendarStore.stageDetectedUpdates([update])
        }
        libraryStore.reload()
        calendarStore.reload()

        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBGameUpdate>()), 1)
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 1)
        XCTAssertEqual(libraryStore.updates(for: "cross-store-game").count, 1)
        XCTAssertEqual(calendarStore.events.count, 1)
    }


    @MainActor
    func testPersonalLibraryRemovalRetainsStatusTimelineInMemoryAndAfterReload() throws {
        let database = try AppDatabase(inMemory: true)
        let changedAt = Date(timeIntervalSince1970: 1_800_000_000)
        database.context.insert(DBGame(id: "history-game", title: "History Game"))
        database.context.insert(DBLibraryEntry(
            gameID: "history-game",
            status: LibraryStatus.playing.rawValue,
            addedAt: changedAt,
            updatedAt: changedAt
        ))
        database.context.insert(DBLibraryStatusEvent(
            id: "history-event",
            gameID: "history-game",
            fromStatus: nil,
            toStatus: LibraryStatus.playing.rawValue,
            changedAt: changedAt
        ))
        try database.save()

        let store = PersonalLibraryStore(database: database)
        XCTAssertEqual(store.history(for: "history-game").map(\.id), ["history-event"])

        store.remove("history-game")

        XCTAssertNil(store.record(for: "history-game"))
        XCTAssertEqual(store.history(for: "history-game").map(\.id), ["history-event"])
        XCTAssertEqual(
            try database.context.fetch(FetchDescriptor<DBLibraryStatusEvent>()).map(\.id),
            ["history-event"]
        )

        store.reload()
        XCTAssertEqual(store.history(for: "history-game").map(\.id), ["history-event"])
    }

}
