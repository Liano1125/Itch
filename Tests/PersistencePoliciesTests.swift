import XCTest
import SwiftData
@testable import itchPocket

final class PersistencePoliciesTests: XCTestCase {
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

    func testOptionalGalleryAndTagsDoNotPreventAResolvedPageFromBeingComplete() {
        XCTAssertTrue(GameDetailSnapshotPolicy.shouldMarkComplete(
            descriptionResolved: true,
            galleryResolved: false,
            tagsResolved: false
        ))
    }

    func testPageRemainsPartialWhenRequiredDescriptionWasNotResolved() {
        XCTAssertFalse(GameDetailSnapshotPolicy.shouldMarkComplete(
            descriptionResolved: false,
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
        let database = try AppDatabase(inMemory: true)
        let game = DBGame(id: "test-game", title: "Test Game")
        database.context.insert(game)
        database.context.insert(DBGameDetail(
            gameID: "test-game",
            descriptionText: "Previously saved description",
            galleryURLs: ["https://example.com/old.jpg"]
        ))
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
        let database = try AppDatabase(inMemory: true)
        let game = DBGame(id: "test-game", title: "Test Game")
        database.context.insert(game)
        database.context.insert(DBGameDetail(
            gameID: "test-game",
            descriptionText: "Previously saved description",
            galleryURLs: ["https://example.com/old.jpg"]
        ))
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
    func testResolvedDescriptionMarksPageCompleteWhenOptionalSectionsAreAbsent() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "test-game", title: "Test Game"))
        database.context.insert(DBGameDetail(
            gameID: "test-game",
            descriptionText: "Old description",
            galleryURLs: ["https://example.com/old.jpg"]
        ))
        try database.save()

        let repository = GameDetailRepository(database: database)
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let status = try repository.applyPageSnapshot(
            GameDetailPageSnapshot(
                description: "Fresh description",
                descriptionResolved: true,
                galleryURLs: [],
                galleryResolved: false,
                discoveryTags: [],
                tagsResolved: false
            ),
            for: "test-game",
            fetchedAt: fetchedAt
        )

        let stored = try XCTUnwrap(repository.detail(for: "test-game"))
        XCTAssertEqual(status, .complete)
        XCTAssertEqual(stored.fetchStatus, .complete)
        XCTAssertEqual(stored.description, "Fresh description")
        XCTAssertEqual(stored.galleryURLs, ["https://example.com/old.jpg"])
        XCTAssertEqual(stored.fetchedAt, fetchedAt)
    }

    @MainActor
    func testFailedSnapshotSaveRestoresOnlyDetailChangesAndPreservesUnrelatedPendingChanges() throws {
        let database = try AppDatabase(inMemory: true)
        let game = DBGame(id: "test-game", title: "Test Game")
        database.context.insert(game)
        database.context.insert(DBGameDetail(
            gameID: "test-game",
            descriptionText: "Previously saved description",
            galleryURLs: ["https://example.com/old.jpg"]
        ))
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

        let preservedState = try XCTUnwrap(AppStateRepository(database: database).state(for: "unrelated.pending.change"))
        XCTAssertEqual(preservedState.stringValue, "keep me")
    }
}


final class PersonalLibraryStoreReloadTests: XCTestCase {
    @MainActor
    func testInitialRepositoryLoadFailureCanRecoverOnRetry() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-1", title: "Game One"))
        database.context.insert(DBLibraryEntry(gameID: "game-1", status: LibraryStatus.playing.rawValue))
        database.context.insert(DBLibraryStatusEvent(
            id: "status-1",
            gameID: "game-1",
            fromStatus: nil,
            toStatus: LibraryStatus.playing.rawValue
        ))
        database.context.insert(DBLibraryCollection(
            id: "collection-1",
            title: "Favorites"
        ))
        try database.save()

        var shouldFail = true
        let store = PersonalLibraryStore(
            database: database,
            shouldSimulateLibraryLoadFailure: { shouldFail }
        )
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.statusEvents.isEmpty)
        XCTAssertTrue(store.collections.isEmpty)

        shouldFail = false
        store.reload()

        XCTAssertEqual(store.records.map(\.id), ["game-1"])
        XCTAssertEqual(store.statusEvents["game-1"]?.map(\.id), ["status-1"])
        XCTAssertEqual(store.collections.map(\.id), ["collection-1"])
    }

    @MainActor
    func testFailedReloadRetainsLastKnownGoodLibraryHistoryAndCollections() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-1", title: "Game One"))
        database.context.insert(DBLibraryEntry(gameID: "game-1", status: LibraryStatus.playing.rawValue))
        database.context.insert(DBLibraryStatusEvent(
            id: "status-1",
            gameID: "game-1",
            fromStatus: nil,
            toStatus: LibraryStatus.playing.rawValue
        ))
        database.context.insert(DBLibraryCollection(
            id: "collection-1",
            title: "Favorites",
        ))
        try database.save()

        var shouldFail = false
        let store = PersonalLibraryStore(
            database: database,
            shouldSimulateLibraryLoadFailure: { shouldFail }
        )
        XCTAssertEqual(store.records.map(\.id), ["game-1"])

        database.context.insert(DBGame(id: "game-2", title: "Game Two"))
        database.context.insert(DBLibraryEntry(gameID: "game-2", status: LibraryStatus.wishlist.rawValue))
        try database.save()

        shouldFail = true
        store.reload()

        XCTAssertEqual(store.records.map(\.id), ["game-1"])
        XCTAssertEqual(store.statusEvents["game-1"]?.map(\.id), ["status-1"])
        XCTAssertEqual(store.collections.map(\.id), ["collection-1"])

        shouldFail = false
        store.reload()
        XCTAssertEqual(Set(store.records.map(\.id)), Set(["game-1", "game-2"]))
    }
}
