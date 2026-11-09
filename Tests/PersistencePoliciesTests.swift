import XCTest
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


final class GameCalendarRepositoryTests: XCTestCase {
    @MainActor
    func testCalendarRepositoryLoadsLinkedHistoricalUpdateAndPreservesEventFallbackAfterUnlink() throws {
        let database = AppDatabase(inMemory: true)
        let game = DBGame(id: "calendar-game", title: "Calendar Game", gameURL: "https://example.com/game")
        let publishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let update = DBGameUpdate(
            id: "calendar-update",
            gameID: "calendar-game",
            title: "Devlog title",
            summary: "Devlog summary",
            detectedAt: Date(timeIntervalSince1970: 1_799_000_000),
            publishedAt: publishedAt,
            url: "https://example.com/devlog",
            sourceID: "stable-source",
            isHistorical: true
        )
        database.context.insert(game)
        database.context.insert(update)
        try database.save()

        let repository = GameCalendarRepository(database: database)
        let event = GameCalendarEvent(
            id: "calendar-event",
            gameID: "calendar-game",
            gameTitle: "Calendar Game",
            gameURL: game.gameURL,
            title: "Saved fallback title",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .update,
            reminderEnabled: false,
            notes: "Saved fallback notes",
            sourceFingerprint: "devlog:stable-source"
        )
        try repository.saveEvent(event, sourceUpdateID: update.id)

        let linked = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(linked.gameTitle, "Calendar Game")
        XCTAssertEqual(linked.gameURL, "https://example.com/game")
        XCTAssertEqual(linked.title, "更新：Devlog title")
        XCTAssertEqual(linked.date, publishedAt)
        XCTAssertTrue(linked.notes.contains("Devlog summary"))

        try repository.saveEvent(event, clearSourceUpdateLink: true)
        let unlinked = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(unlinked.title, "Saved fallback title")
        XCTAssertEqual(unlinked.date, event.date)
        XCTAssertEqual(unlinked.notes, "Saved fallback notes")
    }

    @MainActor
    func testCalendarRepositoryUpsertsHistoricalUpdateWithoutChangingStableIdentity() throws {
        let database = AppDatabase(inMemory: true)
        let repository = GameCalendarRepository(database: database)
        let first = GameLibraryUpdate(
            id: "first-id",
            title: "First title",
            summary: "First summary",
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceID: "same-source",
            isHistorical: true
        )
        let firstID = try repository.upsertHistoricalUpdate(gameID: "game", update: first)
        try repository.save()

        let refreshed = GameLibraryUpdate(
            id: "replacement-id",
            title: "Refreshed title",
            summary: "Refreshed summary",
            publishedAt: Date(timeIntervalSince1970: 1_810_000_000),
            sourceID: "same-source",
            isHistorical: true
        )
        let refreshedID = try repository.upsertHistoricalUpdate(gameID: "game", update: refreshed)
        XCTAssertEqual(refreshedID, firstID)

        let event = GameCalendarEvent(
            id: "linked-event",
            gameID: "game",
            gameTitle: "Game",
            gameURL: nil,
            title: "Fallback",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .update,
            reminderEnabled: false,
            notes: "Fallback notes",
            sourceFingerprint: "devlog:same-source"
        )
        try repository.saveEvent(event, sourceUpdateID: refreshedID)
        let loaded = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(loaded.title, "更新：Refreshed title")
        XCTAssertEqual(loaded.date, refreshed.publishedAt)
        XCTAssertTrue(loaded.notes.contains("Refreshed summary"))
    }

    @MainActor
    func testCalendarRepositoryOrdinaryEditPreservesExistingSourceUpdateLink() throws {
        let database = AppDatabase(inMemory: true)
        let game = DBGame(id: "calendar-edit-game", title: "Calendar Edit Game")
        let update = DBGameUpdate(
            id: "calendar-edit-update",
            gameID: "calendar-edit-game",
            title: "Linked Devlog",
            summary: "Linked summary",
            detectedAt: Date(timeIntervalSince1970: 1_799_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceID: "calendar-edit-source",
            isHistorical: true
        )
        database.context.insert(game)
        database.context.insert(update)
        try database.save()

        let repository = GameCalendarRepository(database: database)
        let original = GameCalendarEvent(
            id: "calendar-edit-event",
            gameID: "calendar-edit-game",
            gameTitle: "Calendar Edit Game",
            gameURL: nil,
            title: "Original fallback",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .update,
            reminderEnabled: false,
            notes: "Original fallback notes"
        )
        try repository.saveEvent(original, sourceUpdateID: update.id)

        var edited = original
        edited.title = "Edited fallback"
        edited.date = Date(timeIntervalSince1970: 1_710_000_000)
        edited.notes = "Edited fallback notes"
        try repository.saveEvent(edited)

        let stillLinked = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(stillLinked.title, "更新：Linked Devlog")
        XCTAssertEqual(stillLinked.date, update.publishedAt)
        XCTAssertTrue(stillLinked.notes.contains("Linked summary"))

        try repository.saveEvent(edited, clearSourceUpdateLink: true)
        let unlinked = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(unlinked.title, "Edited fallback")
        XCTAssertEqual(unlinked.date, edited.date)
        XCTAssertEqual(unlinked.notes, "Edited fallback notes")
    }

    @MainActor
    func testCalendarRepositoryEditPreservesExistingSourceUpdateLink() throws {
        let database = AppDatabase(inMemory: true)
        let updateDate = Date(timeIntervalSince1970: 1_800_000_000)
        let update = DBGameUpdate(
            id: "linked-update",
            gameID: "calendar-game",
            title: "Linked Devlog",
            summary: "Linked summary",
            detectedAt: Date(timeIntervalSince1970: 1_799_000_000),
            publishedAt: updateDate,
            url: "https://example.com/devlog",
            sourceID: "linked-source",
            isHistorical: true
        )
        database.context.insert(update)
        try database.save()

        let repository = GameCalendarRepository(database: database)
        let original = GameCalendarEvent(
            id: "editable-event",
            gameID: "calendar-game",
            gameTitle: "Calendar Game",
            gameURL: nil,
            title: "Original fallback",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .update,
            reminderEnabled: false,
            notes: "Original notes",
            sourceFingerprint: "devlog:linked-source"
        )
        try repository.saveEvent(original, sourceUpdateID: update.id)

        let edited = GameCalendarEvent(
            id: original.id,
            gameID: original.gameID,
            gameTitle: original.gameTitle,
            gameURL: original.gameURL,
            title: "Edited fallback",
            date: Date(timeIntervalSince1970: 1_710_000_000),
            kind: original.kind,
            reminderEnabled: false,
            notes: "Edited notes",
            sourceFingerprint: original.sourceFingerprint
        )
        // Omitting sourceUpdateID during an ordinary edit must retain the
        // existing relationship; only clearSourceUpdateLink explicitly unlinks it.
        try repository.saveEvent(edited)

        let loaded = try XCTUnwrap(repository.events().first)
        XCTAssertEqual(loaded.title, "更新：Linked Devlog")
        XCTAssertEqual(loaded.date, updateDate)
        XCTAssertTrue(loaded.notes.contains("Linked summary"))
    }

    @MainActor
    func testCalendarRepositoryDeletesOnlyRequestedEvent() throws {
        let database = AppDatabase(inMemory: true)
        let repository = GameCalendarRepository(database: database)
        for id in ["keep", "remove"] {
            let event = GameCalendarEvent(
                id: id,
                gameID: "game",
                gameTitle: "Game",
                gameURL: nil,
                title: id,
                date: Date(timeIntervalSince1970: 1_800_000_000),
                kind: .custom
            )
            try repository.saveEvent(event, save: false)
        }
        try repository.save()

        try repository.deleteEvent(id: "remove")
        XCTAssertEqual(try repository.events().map(\.id), ["keep"])
    }
}
