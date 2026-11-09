import XCTest
import SwiftData
@testable import itchPocket

final class PersistencePoliciesTests: XCTestCase {
    func testFailedLibraryHistoryLoadPreservesPersistedHistory() {
        var persisted = ["old-playing", "old-completed"]
        let replaced = SnapshotPersistencePolicy.replacePersistedSnapshot(
            &persisted,
            with: ["new-playing"],
            didLoadSuccessfully: false
        )
        XCTAssertFalse(replaced)
        XCTAssertEqual(persisted, ["old-playing", "old-completed"])
    }

    func testFailedCollectionLoadPreservesPersistedCollections() {
        var persisted = ["Favorites", "Completed"]
        let replaced = SnapshotPersistencePolicy.replacePersistedSnapshot(
            &persisted,
            with: ["New collection"],
            didLoadSuccessfully: false
        )
        XCTAssertFalse(replaced)
        XCTAssertEqual(persisted, ["Favorites", "Completed"])
    }

    func testFailedUpdateWatchLoadPreservesPersistedWatches() {
        var persisted = ["game-a", "game-b"]
        let replaced = SnapshotPersistencePolicy.replacePersistedSnapshot(
            &persisted,
            with: ["game-c"],
            didLoadSuccessfully: false
        )
        XCTAssertFalse(replaced)
        XCTAssertEqual(persisted, ["game-a", "game-b"])
    }

    func testSuccessfulSnapshotLoadAllowsIntentionalReplacement() {
        var persisted = ["old-a", "old-b"]
        let replaced = SnapshotPersistencePolicy.replacePersistedSnapshot(
            &persisted,
            with: ["new-a"],
            didLoadSuccessfully: true
        )
        XCTAssertTrue(replaced)
        XCTAssertEqual(persisted, ["new-a"])
    }

    func testFailedLoadCanRecoverAndAllowReplacementAfterSuccessfulRetry() {
        var persisted = ["existing-a", "existing-b"]
        XCTAssertFalse(SnapshotPersistencePolicy.replacePersistedSnapshot(
            &persisted,
            with: [String](),
            didLoadSuccessfully: false
        ))
        XCTAssertEqual(persisted, ["existing-a", "existing-b"])
        XCTAssertTrue(SnapshotPersistencePolicy.replacePersistedSnapshot(
            &persisted,
            with: ["recovered-a"],
            didLoadSuccessfully: true
        ))
        XCTAssertEqual(persisted, ["recovered-a"])
    }

    func testPartialGameDetailUpdatePreservesFieldsThatWereNotProvided() {
        XCTAssertEqual(
            GameDetailPersistencePolicy.resolvedValue(existing: "saved description", incoming: nil, mode: .partial),
            "saved description"
        )
        XCTAssertEqual(
            GameDetailPersistencePolicy.resolvedValue(existing: ["old.jpg"], incoming: nil, mode: .partial),
            ["old.jpg"]
        )
    }

    func testPartialGameDetailUpdateAllowsExplicitEmptyArraysToClearFields() {
        XCTAssertEqual(
            GameDetailPersistencePolicy.resolvedValue(existing: ["old.jpg"], incoming: [], mode: .partial),
            []
        )
    }

    func testCompleteGameDetailSnapshotTreatsNilAndEmptyValuesAsAuthoritative() {
        XCTAssertNil(
            GameDetailPersistencePolicy.resolvedValue(existing: "saved description", incoming: nil, mode: .complete)
        )
        XCTAssertEqual(
            GameDetailPersistencePolicy.resolvedValue(existing: ["old.jpg"], incoming: [], mode: .complete),
            []
        )
    }

    func testUnresolvedDescriptionPreservesCachedValue() {
        XCTAssertEqual(
            GameDetailSnapshotPolicy.resolvedValue(
                existing: "cached description",
                incoming: nil,
                isResolved: false
            ),
            "cached description"
        )
    }

    func testResolvedNilDescriptionCanExplicitlyClearCachedValue() {
        XCTAssertNil(
            GameDetailSnapshotPolicy.resolvedValue(
                existing: Optional("cached description"),
                incoming: Optional<String>.none,
                isResolved: true
            )
        )
    }

    func testUnresolvedGalleryPreservesCachedImages() {
        XCTAssertEqual(
            GameDetailSnapshotPolicy.resolvedValue(
                existing: ["old-1.jpg", "old-2.jpg"],
                incoming: [String](),
                isResolved: false
            ),
            ["old-1.jpg", "old-2.jpg"]
        )
    }

    func testResolvedEmptyGalleryCanExplicitlyClearCachedImages() {
        XCTAssertEqual(
            GameDetailSnapshotPolicy.resolvedValue(
                existing: ["old.jpg"],
                incoming: [String](),
                isResolved: true
            ),
            []
        )
    }

    func testPageIsNotCompleteUntilEveryDetailSectionWasResolved() {
        XCTAssertFalse(GameDetailSnapshotPolicy.shouldMarkComplete(
            descriptionResolved: true,
            galleryResolved: false,
            tagsResolved: true
        ))
        XCTAssertFalse(GameDetailSnapshotPolicy.shouldMarkComplete(
            descriptionResolved: false,
            galleryResolved: true,
            tagsResolved: true
        ))
        XCTAssertTrue(GameDetailSnapshotPolicy.shouldMarkComplete(
            descriptionResolved: true,
            galleryResolved: true,
            tagsResolved: true
        ))
    }

    func testDeveloperNameResolutionPreservesExistingNameWhenPageOmitsIt() {
        XCTAssertEqual(
            GameDetailRepository.resolvedDeveloperName(
                incoming: nil,
                existing: "Saved developer",
                library: nil
            ),
            "Saved developer"
        )
    }

    func testDeveloperNameResolutionRejectsPlaceholderAndUsesLibraryFallback() {
        XCTAssertEqual(
            GameDetailRepository.resolvedDeveloperName(
                incoming: "itch.io 开发者",
                existing: nil,
                library: "Library developer"
            ),
            "Library developer"
        )
    }

    func testDeveloperNameResolutionPrefersFreshRealName() {
        XCTAssertEqual(
            GameDetailRepository.resolvedDeveloperName(
                incoming: "New developer",
                existing: "Saved developer",
                library: nil
            ),
            "New developer"
        )
    }

    func testPartialLibrarySnapshotDoesNotDeleteOmittedHistory() {
        let shouldDelete = LibraryUpdatePersistencePolicy.shouldDeleteStoredUpdate(
            storedID: "older-update",
            incomingIDs: ["newer-update"],
            isCompleteSnapshot: false
        )

        XCTAssertFalse(shouldDelete)
    }

    func testCompleteLibrarySnapshotCanDeleteOmittedHistory() {
        let shouldDelete = LibraryUpdatePersistencePolicy.shouldDeleteStoredUpdate(
            storedID: "older-update",
            incomingIDs: ["newer-update"],
            isCompleteSnapshot: true
        )

        XCTAssertTrue(shouldDelete)
    }

    func testCompleteLibrarySnapshotKeepsIncludedHistory() {
        let shouldDelete = LibraryUpdatePersistencePolicy.shouldDeleteStoredUpdate(
            storedID: "older-update",
            incomingIDs: ["older-update", "newer-update"],
            isCompleteSnapshot: true
        )

        XCTAssertFalse(shouldDelete)
    }

    func testCalendarEditPreservesExistingSourceUpdateLinkWhenNoReplacementIsProvided() {
        let resolved = CalendarSourceUpdateLinkPolicy.resolvedValue(
            existing: "update-123",
            incoming: nil,
            clear: false
        )

        XCTAssertEqual(resolved, "update-123")
    }

    func testCalendarEditCanReplaceSourceUpdateLink() {
        let resolved = CalendarSourceUpdateLinkPolicy.resolvedValue(
            existing: "update-123",
            incoming: "update-456",
            clear: false
        )

        XCTAssertEqual(resolved, "update-456")
    }

    func testCalendarEditClearsSourceUpdateLinkOnlyWhenExplicitlyRequested() {
        let resolved = CalendarSourceUpdateLinkPolicy.resolvedValue(
            existing: "update-123",
            incoming: nil,
            clear: true
        )

        XCTAssertNil(resolved)
    }
}


private enum GameDetailTestError: Error {
    case simulatedSaveFailure
}

final class GameDetailRepositoryTests: XCTestCase {
    @MainActor
    func testUnresolvedPageSectionsPreserveStoredDetailsAndDoNotRefreshTimestamp() throws {
        let database = AppDatabase(inMemory: true)
        let game = DBGame(
            id: "test-game",
            title: "Test Game",
            descriptionText: "Previously saved description",
            galleryURLs: ["https://example.com/old.jpg"]
        )
        database.context.insert(game)
        try database.save()

        let repository = GameDetailRepository(database: database)
        let status = try repository.applyPageSnapshot(
            GameDetailPageSnapshot(
                description: nil,
                descriptionResolved: false,
                galleryURLs: [],
                galleryResolved: false,
                discoveryTags: [],
                tagsResolved: false
            ),
            for: "test-game"
        )

        let stored = try repository.detail(for: "test-game")
        XCTAssertEqual(status, .partial)
        XCTAssertEqual(stored?.description, "Previously saved description")
        XCTAssertEqual(stored?.galleryURLs, ["https://example.com/old.jpg"])
        XCTAssertEqual(stored?.fetchStatus, .partial)
        XCTAssertNil(stored?.fetchedAt)
    }

    @MainActor
    func testResolvedEmptySectionsCanClearStoredDetailsAndMarkComplete() throws {
        let database = AppDatabase(inMemory: true)
        let game = DBGame(
            id: "test-game",
            title: "Test Game",
            descriptionText: "Previously saved description",
            galleryURLs: ["https://example.com/old.jpg"]
        )
        database.context.insert(game)
        try database.save()

        let repository = GameDetailRepository(database: database)
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let status = try repository.applyPageSnapshot(
            GameDetailPageSnapshot(
                description: nil,
                descriptionResolved: true,
                galleryURLs: [],
                galleryResolved: true,
                discoveryTags: [],
                tagsResolved: true
            ),
            for: "test-game",
            fetchedAt: fetchedAt
        )

        let stored = try repository.detail(for: "test-game")
        XCTAssertEqual(status, .complete)
        XCTAssertNil(stored?.description)
        XCTAssertEqual(stored?.galleryURLs, [])
        XCTAssertEqual(stored?.fetchStatus, .complete)
        XCTAssertEqual(stored?.fetchedAt, fetchedAt)
    }

    @MainActor
    func testFailedSnapshotSaveRestoresOnlyDetailChangesAndPreservesUnrelatedPendingChanges() throws {
        let database = AppDatabase(inMemory: true)
        let game = DBGame(
            id: "test-game",
            title: "Test Game",
            descriptionText: "Previously saved description",
            galleryURLs: ["https://example.com/old.jpg"]
        )
        database.context.insert(game)
        try database.save()

        // This unrelated edit shares the main context but is not part of this repository write.
        let unrelatedState = DBAppState(key: "unrelated.pending.change", stringValue: "keep me")
        database.context.insert(unrelatedState)

        let repository = GameDetailRepository(
            database: database,
            saveChanges: { throw GameDetailTestError.simulatedSaveFailure }
        )
        XCTAssertThrowsError(
            try repository.applyPageSnapshot(
                GameDetailPageSnapshot(
                    description: nil,
                    descriptionResolved: true,
                    galleryURLs: [],
                    galleryResolved: true,
                    discoveryTags: [],
                    tagsResolved: true
                ),
                for: "test-game",
                fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )

        let stored = try XCTUnwrap(repository.detail(for: "test-game"))
        XCTAssertEqual(stored.description, "Previously saved description")
        XCTAssertEqual(stored.galleryURLs, ["https://example.com/old.jpg"])
        XCTAssertNotEqual(stored.fetchStatus, .complete)
        XCTAssertNil(stored.fetchedAt)

        let preservedState = try XCTUnwrap(database.state(for: "unrelated.pending.change"))
        XCTAssertEqual(preservedState.stringValue, "keep me")
        XCTAssertNotNil(preservedState.modelContext)
    }
}


extension PersistencePoliciesTests {
    @MainActor
    func testPersonalLibraryStorePreservesSwiftDataSnapshotsAfterInjectedLoadFailureAndRecovers() throws {
        let database = AppDatabase(inMemory: true)
        let originalCollection = DBLibraryCollection(id: "saved-collection", title: "Saved", gameIDs: ["game-1"])
        let originalEvent = DBLibraryStatusEvent(
            id: "saved-event",
            gameID: "game-1",
            fromStatus: nil,
            toStatus: LibraryStatus.playing.rawValue
        )
        database.context.insert(originalCollection)
        database.context.insert(originalEvent)
        try database.save()

        var shouldFailLoad = true
        let store = PersonalLibraryStore(
            database: database,
            shouldSimulateSnapshotLoadFailure: { shouldFailLoad }
        )
        XCTAssertTrue(store.collections.isEmpty)

        store.createCollection(title: "Attempted while unavailable")
        let collectionsAfterBlockedWrite = try database.context.fetch(FetchDescriptor<DBLibraryCollection>())
        let eventsAfterBlockedWrite = try database.context.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        XCTAssertEqual(collectionsAfterBlockedWrite.map(\.id), ["saved-collection"])
        XCTAssertEqual(eventsAfterBlockedWrite.map(\.id), ["saved-event"])

        shouldFailLoad = false
        store.reload()
        XCTAssertEqual(store.collections.map(\.id), ["saved-collection"])
        store.createCollection(title: "Created after recovery")

        let recoveredCollections = try database.context.fetch(FetchDescriptor<DBLibraryCollection>())
        XCTAssertEqual(Set(recoveredCollections.map(\.title)), Set(["Saved", "Created after recovery"]))
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBLibraryStatusEvent>()).map(\.id), ["saved-event"])
    }

    @MainActor
    func testUpdateMonitorPreservesSwiftDataWatchesAfterInjectedLoadFailureAndRecovers() throws {
        let database = AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "watched-game", title: "Watched Game", gameURL: "https://example.com/game"))
        database.context.insert(DBUpdateWatch(gameID: "watched-game", entityTag: "etag-v1", hasBaseline: true))
        try database.save()

        var shouldFailLoad = true
        let store = GameUpdateMonitorStore(
            database: database,
            shouldSimulateSnapshotLoadFailure: { shouldFailLoad }
        )
        XCTAssertNil(store.watch(for: "watched-game"))

        let record = LibraryRecord(
            id: "watched-game",
            title: "Watched Game",
            gameURL: "https://example.com/game",
            coverURL: nil,
            developer: nil,
            status: .playing,
            isFavorite: false,
            notes: "",
            addedAt: .now,
            updatedAt: .now
        )
        store.setEnabled(false, for: record)

        let watchesAfterBlockedWrite = try database.context.fetch(FetchDescriptor<DBUpdateWatch>())
        XCTAssertEqual(watchesAfterBlockedWrite.map(\.gameID), ["watched-game"])
        XCTAssertEqual(watchesAfterBlockedWrite.first?.entityTag, "etag-v1")

        shouldFailLoad = false
        store.reload()
        XCTAssertNotNil(store.watch(for: "watched-game"))
        store.setEnabled(false, for: record)

        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBUpdateWatch>()).isEmpty)
    }
}


extension PersistencePoliciesTests {
    @MainActor
    func testDiscoveryCacheRepositoryStoresExpiresAndRemovesSnapshots() throws {
        let database = AppDatabase(inMemory: true)
        let repository = DiscoveryCacheRepository(database: database)
        let key = "discovery.repository.test"
        let payload = Data("{\"items\":[1,2,3]}".utf8)
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

        try repository.save(
            payload: payload,
            for: key,
            timeToLive: 60,
            fetchedAt: fetchedAt
        )
        XCTAssertEqual(try repository.payload(for: key, now: fetchedAt.addingTimeInterval(30)), payload)

        XCTAssertNil(try repository.payload(for: key, now: fetchedAt.addingTimeInterval(61)))
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBDiscoverySnapshot>()).isEmpty)

        try repository.save(
            payload: payload,
            for: key,
            timeToLive: 60,
            fetchedAt: fetchedAt
        )
        try repository.remove(key: key)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBDiscoverySnapshot>()).isEmpty)
    }
}
