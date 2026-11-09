import XCTest
import SwiftData
import CryptoKit
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
    func testTranslationCacheRepositoryStoresUpdatesAndLooksUpEntries() throws {
        let database = AppDatabase(inMemory: true)
        let repository = TranslationCacheRepository(database: database)
        let key = TranslationCacheKey.make(scope: "game:123", source: "Hello", target: "zh-Hans")
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        try repository.store(
            "你好",
            source: "Hello",
            scope: "game:123",
            target: "zh-Hans",
            for: key,
            updatedAt: timestamp
        )

        let entry = try XCTUnwrap(repository.translation(for: key))
        XCTAssertEqual(entry.translation, "你好")
        XCTAssertEqual(entry.sourceText, "Hello")
        XCTAssertEqual(entry.sourceHash, SHA256.hash(data: Data("Hello".utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(entry.scope, "game:123")
        XCTAssertEqual(entry.target, "zh-Hans")
        XCTAssertEqual(entry.updatedAt, timestamp)
        XCTAssertEqual(try repository.latest(scope: "game:123", target: "zh-Hans")?.translation, "你好")

        try repository.store(
            "您好",
            source: "Hello",
            scope: "game:123",
            target: "zh-Hans",
            for: key,
            updatedAt: timestamp.addingTimeInterval(60)
        )
        XCTAssertEqual(try repository.translation(for: key)?.translation, "您好")
        XCTAssertEqual(try database.context.fetchCount(FetchDescriptor<DBTranslation>()), 1)
    }

    @MainActor
    func testTranslationCacheRepositoryRetainsNewestEntriesAfterLimitIsExceeded() throws {
        let database = AppDatabase(inMemory: true)
        let repository = TranslationCacheRepository(
            database: database,
            maximumEntries: 3,
            retainedEntries: 2
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<4 {
            let key = "translation-retention-\(index)"
            try repository.store(
                "translated-\(index)",
                source: "source-\(index)",
                scope: "retention-test",
                target: "en",
                for: key,
                updatedAt: start.addingTimeInterval(TimeInterval(index))
            )
        }

        let remaining = try database.context.fetch(FetchDescriptor<DBTranslation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        ))
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining.map(\.cacheKey)), ["translation-retention-2", "translation-retention-3"])
    }
}
