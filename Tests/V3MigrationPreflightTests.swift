import XCTest
import SwiftData
@testable import itchPocket

final class V3MigrationPreflightTests: XCTestCase {
    @MainActor
    func testEmptyV3StoreProducesStableEmptyInventory() throws {
        let database = try AppDatabase(inMemory: true)
        let report = try V3MigrationPreflight.inspect(context: database.context)

        XCTAssertEqual(report.sourceSchemaVersion, "3.0.0")
        XCTAssertTrue(report.isStructurallyValid)
        XCTAssertFalse(report.hasUnresolvedOwnership)
        XCTAssertEqual(report.rowCounts["games"], 0)
        XCTAssertEqual(report.rowCounts["libraryEntries"], 0)
        XCTAssertEqual(report.ownershipReviewCounts["calendarEvents"], 0)
        XCTAssertEqual(report.inventoryDigest.count, 64)
        XCTAssertEqual(
            report.inventoryDigest,
            try V3MigrationPreflight.inspect(context: database.context).inventoryDigest
        )
        XCTAssertFalse(database.context.hasChanges)
    }

    @MainActor
    func testInventoryCountsRowsAndMarksLegacyPersonalDataForReview() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        context.insert(DBDeveloper(id: "dev-1", name: "Developer"))
        context.insert(DBGame(id: "game-1", title: "Game", developerID: "dev-1"))
        context.insert(DBLibraryEntry(
            gameID: "game-1", status: "playing", isFavorite: true,
            notes: "private note", addedAt: timestamp, updatedAt: timestamp
        ))
        context.insert(DBGameUpdate(
            id: "update-1", gameID: "game-1", summary: "Update", detectedAt: timestamp
        ))
        context.insert(DBCalendarEvent(
            id: "calendar-1", gameID: "game-1", title: "Release",
            date: timestamp, kind: "release", notes: "personal reminder",
            sourceUpdateID: "update-1"
        ))
        context.insert(DBSparkMetadata(gameID: "game-1", runtimeSeconds: 120))
        context.insert(DBTranslation(
            cacheKey: "translation-1", scope: "game", sourceHash: "hash",
            sourceText: "source", targetLanguage: "zh", translatedText: "translated"
        ))
        context.insert(DBDiscoverySnapshot(
            key: "discovery-1", payload: Data([1, 2, 3]), expiresAt: timestamp
        ))
        context.insert(DBUpdateWatch(gameID: "game-1", isEnabled: true))
        context.insert(DBLibraryCollection(id: "collection-1", title: "Collection"))
        context.insert(DBLibraryCollectionItem(
            id: DBLibraryCollectionItem.stableID(collectionID: "collection-1", gameID: "game-1"),
            collectionID: "collection-1", gameID: "game-1", sortOrder: 0
        ))
        context.insert(DBLibraryStatusEvent(
            id: "status-1", gameID: "game-1", fromStatus: nil,
            toStatus: "playing", changedAt: timestamp
        ))
        context.insert(DBAppState(key: "devlogSync.lastDate", dateValue: timestamp))
        context.insert(DBGameDetail(
            gameID: "game-1", descriptionText: "Description", fetchedAt: timestamp,
            isComplete: true
        ))
        try context.save()

        let report = try V3MigrationPreflight.inspect(context: context)

        XCTAssertTrue(report.isStructurallyValid, report.integrityIssues.joined(separator: ", "))
        XCTAssertTrue(report.hasUnresolvedOwnership)
        XCTAssertEqual(report.rowCounts["developers"], 1)
        XCTAssertEqual(report.rowCounts["games"], 1)
        XCTAssertEqual(report.rowCounts["libraryEntries"], 1)
        XCTAssertEqual(report.rowCounts["gameUpdates"], 1)
        XCTAssertEqual(report.rowCounts["calendarEvents"], 1)
        XCTAssertEqual(report.rowCounts["sparkMetadata"], 1)
        XCTAssertEqual(report.rowCounts["translations"], 1)
        XCTAssertEqual(report.rowCounts["discoverySnapshots"], 1)
        XCTAssertEqual(report.rowCounts["updateWatches"], 1)
        XCTAssertEqual(report.rowCounts["collections"], 1)
        XCTAssertEqual(report.rowCounts["collectionItems"], 1)
        XCTAssertEqual(report.rowCounts["libraryStatusEvents"], 1)
        XCTAssertEqual(report.rowCounts["appStates"], 1)
        XCTAssertEqual(report.rowCounts["gameDetails"], 1)

        XCTAssertEqual(report.ownershipReviewCounts["libraryEntries"], 1)
        XCTAssertEqual(report.ownershipReviewCounts["collections"], 1)
        XCTAssertEqual(report.ownershipReviewCounts["collectionItems"], 1)
        XCTAssertEqual(report.ownershipReviewCounts["libraryStatusEvents"], 1)
        XCTAssertEqual(report.ownershipReviewCounts["updateWatches"], 1)
        XCTAssertEqual(report.ownershipReviewCounts["calendarEvents"], 1)
        XCTAssertEqual(report.ownershipReviewCounts["appStates"], 1)

        // The preflight reports only counts and diagnostics, never user payloads.
        let encoded = try String(data: JSONEncoder().encode(report), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("private note"))
        XCTAssertFalse(encoded.contains("personal reminder"))
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testPreflightReportsOrphanedReferencesWithoutMutatingSource() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "game-1", title: "Game", developerID: "missing-dev"))
        context.insert(DBLibraryEntry(gameID: "missing-library-game", status: "playing"))
        context.insert(DBGameUpdate(
            id: "update-1", gameID: "missing-update-game", summary: "Update"
        ))
        context.insert(DBCalendarEvent(
            id: "calendar-1", gameID: "missing-calendar-game", kind: "release"
        ))
        context.insert(DBUpdateWatch(gameID: "missing-watch-game"))
        context.insert(DBLibraryStatusEvent(
            id: "status-1", gameID: "missing-status-game",
            fromStatus: nil, toStatus: "playing"
        ))
        context.insert(DBLibraryCollectionItem(
            id: "noncanonical-membership",
            collectionID: "missing-collection",
            gameID: "missing-membership-game",
            sortOrder: 0
        ))
        try context.save()

        let report = try V3MigrationPreflight.inspect(context: context)

        XCTAssertFalse(report.isStructurallyValid)
        XCTAssertTrue(report.integrityIssues.contains("game.missingDeveloper:game-1"))
        XCTAssertTrue(report.integrityIssues.contains("libraryEntry.missingGame:missing-library-game"))
        XCTAssertTrue(report.integrityIssues.contains("gameUpdate.missingGame:update-1"))
        XCTAssertTrue(report.integrityIssues.contains("calendarEvent.missingGame:calendar-1"))
        XCTAssertTrue(report.integrityIssues.contains("updateWatch.missingGame:missing-watch-game"))
        XCTAssertTrue(report.integrityIssues.contains("libraryStatusEvent.missingGame:status-1"))
        XCTAssertTrue(report.integrityIssues.contains("collectionItem.missingCollection:noncanonical-membership"))
        XCTAssertTrue(report.integrityIssues.contains("collectionItem.missingGame:noncanonical-membership"))
        XCTAssertTrue(report.integrityIssues.contains("collectionItem.nonCanonicalID:noncanonical-membership"))
        XCTAssertFalse(context.hasChanges)
    }
}
