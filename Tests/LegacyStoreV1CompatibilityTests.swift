import XCTest
import SwiftData
@testable import itchPocket

final class LegacyStoreV1CompatibilityTests: XCTestCase {
    @MainActor
    func testSQLiteQuickCheckRejectsCorruptDatabaseBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-sqlite-check-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let corruptURL = directory.appendingPathComponent("corrupt.store")
        try Data("not-a-sqlite-database".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try SQLiteStoreIntegrityChecker.quickCheck(at: corruptURL))
    }

    @MainActor
    func testExplicitRecoveryQuarantinesInvalidV2AndRebuildsFromLegacy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-recovery-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try createExactUnversionedLegacyStore(at: legacyURL)
        let originalStoreURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        )
        let damagedBytes = Data("damaged-v2-store".utf8)
        try damagedBytes.write(to: originalStoreURL)

        XCTAssertThrowsError(try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        ))

        let recoveredURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory,
            recoverInvalidExistingV2: true
        )
        XCTAssertEqual(recoveredURL, finalDirectory.appendingPathComponent("itchPocket-v2.store"))
        XCTAssertEqual(try legacyGameCount(at: legacyURL), 2)

        let quarantines = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { $0.lastPathComponent.hasPrefix("itchPocket-v2.quarantine-") }
        XCTAssertEqual(quarantines.count, 1)
        let quarantinedStore = quarantines[0].appendingPathComponent("itchPocket-v2.store")
        XCTAssertEqual(try Data(contentsOf: quarantinedStore), damagedBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: recoveredURL, allowsSave: false)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBGame>()), 2)
    }

    @MainActor
    func testUnversionedDiskStoreReopensWithV1SchemaWithoutLosingRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-legacy-v1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("itchPocket.store")
        try createUnversionedLegacyStore(at: storeURL)

        // Open a store created with the exact top-level model classes shipped
        // before versioning, using the frozen nested V1 declarations.
        let versionedSchema = Schema(versionedSchema: ItchPocketSchemaV1.self)
        let configuration = ModelConfiguration("itchPocket", schema: versionedSchema, url: storeURL)
        let container = try ModelContainer(for: versionedSchema, configurations: [configuration])
        let context = container.mainContext

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBDeveloper>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBGame>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBLibraryEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBGameUpdate>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBCalendarEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBSparkMetadata>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBTranslation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBDiscoverySnapshot>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBUpdateWatch>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBLibraryCollection>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBLibraryStatusEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBAppState>()), 1)

        let games = try context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBGame>())
        let primaryGame = try XCTUnwrap(games.first { $0.id == "legacy-game-a" })
        XCTAssertEqual(primaryGame.title, "Legacy Game A")
        XCTAssertEqual(primaryGame.descriptionText, "Saved legacy description")
        XCTAssertEqual(primaryGame.galleryURLs, ["https://example.com/one.jpg", "https://example.com/two.jpg"])
        XCTAssertEqual(primaryGame.discoveryTagsData, Data("legacy-tags".utf8))

        let libraryEntry = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBLibraryEntry>()).first)
        XCTAssertEqual(libraryEntry.gameID, "legacy-game-a")
        XCTAssertEqual(libraryEntry.status, "playing")
        XCTAssertTrue(libraryEntry.isFavorite)
        XCTAssertEqual(libraryEntry.notes, "Keep this note")

        let collection = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBLibraryCollection>()).first)
        XCTAssertEqual(collection.gameIDs, ["legacy-game-b", "legacy-game-a", "legacy-game-b"])

        let calendarEvent = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBCalendarEvent>()).first)
        XCTAssertEqual(calendarEvent.gameID, "legacy-game-a")
        XCTAssertNil(calendarEvent.date)
        XCTAssertEqual(calendarEvent.sourceUpdateID, "legacy-update-a")

        let update = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBGameUpdate>()).first)
        XCTAssertEqual(update.id, "legacy-update-a")
        XCTAssertEqual(update.title, "Legacy update")
        XCTAssertEqual(update.summary, "Historical update")
        XCTAssertEqual(update.detectedAt, Date(timeIntervalSince1970: 1_700_000_004))
        XCTAssertEqual(update.publishedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(update.url, "https://example.com/update")
        XCTAssertEqual(update.sourceID, "legacy-source-a")
        XCTAssertTrue(update.isHistorical)

        let appState = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBAppState>()).first)
        XCTAssertEqual(appState.key, "legacy.test.state")
        XCTAssertEqual(appState.stringValue, "preserve-me")
        XCTAssertEqual(appState.dataValue, Data("opaque-state".utf8))

        // Check the entity names for every frozen V1 model against the
        // original top-level model types used by the unversioned app.
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBDeveloper.self), Schema.entityName(for: DBDeveloper.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBGame.self), Schema.entityName(for: DBGame.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBLibraryEntry.self), Schema.entityName(for: DBLibraryEntry.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBGameUpdate.self), Schema.entityName(for: DBGameUpdate.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBCalendarEvent.self), Schema.entityName(for: DBCalendarEvent.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBSparkMetadata.self), Schema.entityName(for: DBSparkMetadata.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBTranslation.self), Schema.entityName(for: DBTranslation.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBDiscoverySnapshot.self), Schema.entityName(for: DBDiscoverySnapshot.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBUpdateWatch.self), Schema.entityName(for: DBUpdateWatch.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBLibraryCollection.self), Schema.entityName(for: DBLibraryCollection.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBLibraryStatusEvent.self), Schema.entityName(for: DBLibraryStatusEvent.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBAppState.self), Schema.entityName(for: DBAppState.self))

        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testLegacyBootstrapCopiesAllDataAndKeepsOriginalStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try createExactUnversionedLegacyStore(at: legacyURL)

        let finalURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path), "The original database must remain in place.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("itchPocket-v2.staging").path))

        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: finalURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBDeveloper>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGame>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGameUpdate>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBSparkMetadata>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBTranslation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBDiscoverySnapshot>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBUpdateWatch>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryCollection>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryStatusEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAppState>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGameDetail>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryCollectionItem>()), 2)

        let developer = try XCTUnwrap(context.fetch(FetchDescriptor<DBDeveloper>()).first)
        XCTAssertEqual(developer.name, "Legacy Developer")
        XCTAssertEqual(developer.profileURL, "https://example.com/developer")

        let game = try XCTUnwrap(context.fetch(FetchDescriptor<DBGame>()).first { $0.id == "legacy-game-a" })
        XCTAssertEqual(game.title, "Legacy Game A")
        XCTAssertEqual(game.gameURL, "https://example.com/game-a")
        XCTAssertEqual(game.coverURL, "https://example.com/cover.jpg")
        XCTAssertEqual(game.engine, "Ren'Py")
        XCTAssertEqual(game.developerID, "legacy-developer")
        XCTAssertEqual(game.updatedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(game.descriptionText, "Saved legacy description")
        XCTAssertEqual(game.galleryURLs, ["https://example.com/one.jpg", "https://example.com/two.jpg"])
        XCTAssertEqual(game.discoveryTagsData, Data("legacy-tags".utf8))

        let detail = try XCTUnwrap(context.fetch(FetchDescriptor<DBGameDetail>()).first)
        XCTAssertEqual(detail.gameID, "legacy-game-a")
        XCTAssertEqual(detail.descriptionText, "Saved legacy description")
        XCTAssertNil(detail.fetchedAt)
        XCTAssertFalse(detail.isComplete)

        let libraryEntry = try XCTUnwrap(context.fetch(FetchDescriptor<DBLibraryEntry>()).first)
        XCTAssertEqual(libraryEntry.status, "playing")
        XCTAssertTrue(libraryEntry.isFavorite)
        XCTAssertEqual(libraryEntry.notes, "Keep this note")

        let update = try XCTUnwrap(context.fetch(FetchDescriptor<DBGameUpdate>()).first)
        XCTAssertEqual(update.id, "legacy-update-a")
        XCTAssertEqual(update.sourceID, "legacy-source-a")
        XCTAssertTrue(update.isHistorical)

        let event = try XCTUnwrap(context.fetch(FetchDescriptor<DBCalendarEvent>()).first)
        XCTAssertEqual(event.gameTitleSnapshot, "Legacy Game A")
        XCTAssertEqual(event.title, "Legacy calendar event")
        XCTAssertEqual(event.kind, "custom")
        XCTAssertTrue(event.reminderEnabled)
        XCTAssertEqual(event.reminderMinutes, 45)
        XCTAssertEqual(event.notes, "Calendar note")
        XCTAssertEqual(event.sourceFingerprint, "legacy-fingerprint")
        XCTAssertEqual(event.sourceUpdateID, "legacy-update-a")
        XCTAssertNil(event.date)

        let spark = try XCTUnwrap(context.fetch(FetchDescriptor<DBSparkMetadata>()).first)
        XCTAssertEqual(spark.runtimeSeconds, 1234)
        XCTAssertEqual(spark.renpyVersion, "8.2.0")
        XCTAssertEqual(spark.saveCount, 3)
        XCTAssertEqual(spark.lastSaveAt, Date(timeIntervalSince1970: 1_700_000_005))
        XCTAssertEqual(spark.scannedAt, Date(timeIntervalSince1970: 1_700_000_006))

        let translation = try XCTUnwrap(context.fetch(FetchDescriptor<DBTranslation>()).first)
        XCTAssertEqual(translation.cacheKey, "legacy-translation")
        XCTAssertEqual(translation.scope, "description")
        XCTAssertEqual(translation.sourceHash, "legacy-hash")
        XCTAssertEqual(translation.sourceText, "hello")
        XCTAssertEqual(translation.targetLanguage, "zh-CN")
        XCTAssertEqual(translation.translatedText, "你好")
        XCTAssertEqual(translation.updatedAt, Date(timeIntervalSince1970: 1_700_000_007))
        let discovery = try XCTUnwrap(context.fetch(FetchDescriptor<DBDiscoverySnapshot>()).first)
        XCTAssertEqual(discovery.payload, Data("legacy-payload".utf8))
        XCTAssertEqual(discovery.fetchedAt, Date(timeIntervalSince1970: 1_700_000_008))
        XCTAssertEqual(discovery.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
        let watch = try XCTUnwrap(context.fetch(FetchDescriptor<DBUpdateWatch>()).first)
        XCTAssertEqual(watch.gameID, "legacy-game-a")
        XCTAssertEqual(watch.entityTag, "legacy-etag")
        XCTAssertEqual(watch.lastModified, "Wed, 01 Jan 2025 00:00:00 GMT")
        XCTAssertEqual(watch.contentHash, "legacy-content-hash")
        XCTAssertEqual(watch.lastCheckedAt, Date(timeIntervalSince1970: 1_700_000_009))
        XCTAssertTrue(watch.hasBaseline)
        XCTAssertTrue(watch.isEnabled)

        let collection = try XCTUnwrap(context.fetch(FetchDescriptor<DBLibraryCollection>()).first)
        XCTAssertEqual(collection.title, "Legacy collection")
        XCTAssertEqual(collection.gameIDs, ["legacy-game-b", "legacy-game-a", "legacy-game-b"])
        XCTAssertEqual(collection.createdAt, Date(timeIntervalSince1970: 1_700_000_010))
        XCTAssertEqual(collection.updatedAt, Date(timeIntervalSince1970: 1_700_000_011))
        let items = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(items.map(\.gameID), ["legacy-game-b", "legacy-game-a"])
        XCTAssertEqual(items.map(\.sortOrder), [0, 1])

        let status = try XCTUnwrap(context.fetch(FetchDescriptor<DBLibraryStatusEvent>()).first)
        XCTAssertEqual(status.id, "legacy-status-event")
        XCTAssertEqual(status.gameID, "legacy-game-a")
        XCTAssertNil(status.fromStatus)
        XCTAssertEqual(status.toStatus, "playing")
        XCTAssertEqual(status.changedAt, Date(timeIntervalSince1970: 1_700_000_012))
        let state = try XCTUnwrap(context.fetch(FetchDescriptor<DBAppState>()).first)
        XCTAssertEqual(state.key, "legacy.test.state")
        XCTAssertEqual(state.stringValue, "preserve-me")
        XCTAssertEqual(state.dateValue, Date(timeIntervalSince1970: 1_700_000_013))
        XCTAssertEqual(state.dataValue, Data("opaque-state".utf8))
        XCTAssertEqual(state.updatedAt, Date(timeIntervalSince1970: 1_700_000_014))
    }

    @MainActor
    func testBootstrapFailureKeepsLegacyStoreAndCanRetry() throws {
        enum InjectedFailure: Error { case stopBeforePromotion }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        let stagingDirectory = directory.appendingPathComponent("itchPocket-v2.staging", isDirectory: true)
        try createExactUnversionedLegacyStore(at: legacyURL)

        XCTAssertThrowsError(try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory,
            beforePromotion: { throw InjectedFailure.stopBeforePromotion }
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))

        // The old store is still readable after an interrupted migration.
        XCTAssertEqual(try legacyGameCount(at: legacyURL), 2)

        let recoveredURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @MainActor
    func testRepeatedBootstrapReusesCompletedV2StoreWithoutDuplicatingRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-repeat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try createExactUnversionedLegacyStore(at: legacyURL)

        let firstURL = try LegacyStoreBootstrap.prepareStore(legacyStoreURL: legacyURL, finalDirectory: finalDirectory)
        let secondURL = try LegacyStoreBootstrap.prepareStore(legacyStoreURL: legacyURL, finalDirectory: finalDirectory)
        XCTAssertEqual(firstURL, secondURL)

        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: secondURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBGame>()), 2)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBGameDetail>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBLibraryCollectionItem>()), 2)
    }

    @MainActor
    func testExistingCorruptV2StoreIsRejectedWithoutTouchingEitherStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-corrupt-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        let corruptStoreURL = finalDirectory.appendingPathComponent("itchPocket-v2.store")
        try createExactUnversionedLegacyStore(at: legacyURL)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let corruptBytes = Data("intentionally-corrupt-store".utf8)
        try corruptBytes.write(to: corruptStoreURL)

        XCTAssertThrowsError(try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        ))

        XCTAssertEqual(try Data(contentsOf: corruptStoreURL), corruptBytes)
        XCTAssertEqual(try legacyGameCount(at: legacyURL), 2)
    }

    @MainActor
    func testExistingV2StoreWithOrphanedCollectionItemIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try createExactUnversionedLegacyStore(at: legacyURL)
        let finalStoreURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        )

        // Start with a genuinely completed migration and valid receipt, then
        // introduce an invalid join row into the existing V2 database.
        do {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
            let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: finalStoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.insert(DBLibraryCollectionItem(
                id: "orphan-item",
                collectionID: "missing-collection",
                gameID: "legacy-game-a",
                sortOrder: 0
            ))
            try container.mainContext.save()
        }

        XCTAssertThrowsError(try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalStoreURL.path))
        XCTAssertEqual(try legacyGameCount(at: legacyURL), 2)
    }

    @MainActor
    func testExistingV2StoreWithCollectionItemReferencingMissingGameIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-orphan-game-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try createExactUnversionedLegacyStore(at: legacyURL)
        let finalStoreURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        )

        // Keep the migration receipt valid while introducing a broken game
        // reference, so this test exercises the relationship validator itself.
        do {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
            let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: finalStoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.insert(DBLibraryCollection(id: "valid-collection", title: "Valid collection"))
            container.mainContext.insert(DBLibraryCollectionItem(
                id: "orphan-game-item",
                collectionID: "valid-collection",
                gameID: "missing-game",
                sortOrder: 0
            ))
            try container.mainContext.save()
        }

        XCTAssertThrowsError(try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalStoreURL.path))
        XCTAssertEqual(try legacyGameCount(at: legacyURL), 2)
    }

    @MainActor
    func testExistingEmptyV2StoreWithoutReceiptIsRejectedWhenLegacyHasData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-empty-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        let finalStoreURL = finalDirectory.appendingPathComponent("itchPocket-v2.store")
        try createExactUnversionedLegacyStore(at: legacyURL)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)

        // A structurally readable but empty V2 store must not be mistaken for
        // a completed migration when the preserved legacy database has games.
        do {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
            let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: finalStoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            try container.mainContext.save()
        }

        XCTAssertThrowsError(try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalStoreURL.path))
        XCTAssertEqual(try legacyGameCount(at: legacyURL), 2)
    }

    @MainActor
    func testExistingV2StoreEmptiedAfterMigrationIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-emptied-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try createExactUnversionedLegacyStore(at: legacyURL)
        let finalStoreURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        )

        // Preserve the valid completion receipt but remove all migrated games.
        // Reuse must compare the current database against the recorded baseline.
        do {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
            let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: finalStoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            try container.mainContext.delete(model: DBGame.self)
            try container.mainContext.save()
        }

        XCTAssertThrowsError(try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalStoreURL.path))
        XCTAssertEqual(try legacyGameCount(at: legacyURL), 2)
    }

    @MainActor
    func testRestartAfterPromotionReusesValidatedV2Store() throws {
        enum SimulatedTermination: Error { case afterPromotion }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-bootstrap-post-promotion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("itchPocket.store")
        let finalDirectory = directory.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try createExactUnversionedLegacyStore(at: legacyURL)

        XCTAssertThrowsError(try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory,
            afterPromotion: { throw SimulatedTermination.afterPromotion }
        ))

        let promotedURL = finalDirectory.appendingPathComponent("itchPocket-v2.store")
        XCTAssertTrue(FileManager.default.fileExists(atPath: promotedURL.path))
        XCTAssertEqual(try legacyGameCount(at: legacyURL), 2)

        let recoveredURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyURL,
            finalDirectory: finalDirectory
        )
        XCTAssertEqual(recoveredURL, promotedURL)

        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: recoveredURL, allowsSave: false)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBGame>()), 2)
    }

    @MainActor
    private func createUnversionedLegacyStore(at storeURL: URL) throws {
        // This is intentionally built from the original top-level model types,
        // not the V1 nested snapshots, so the test exercises the real legacy shape.
        let legacySchema = Schema([
            DBDeveloper.self, DBGame.self, DBLibraryEntry.self, DBGameUpdate.self,
            DBCalendarEvent.self, DBSparkMetadata.self, DBTranslation.self,
            DBDiscoverySnapshot.self, DBUpdateWatch.self, DBLibraryCollection.self,
            DBLibraryStatusEvent.self, DBAppState.self
        ])
        let configuration = ModelConfiguration("itchPocket", schema: legacySchema, url: storeURL)
        let legacyContainer = try ModelContainer(for: legacySchema, configurations: [configuration])
        let context = legacyContainer.mainContext

        context.insert(DBDeveloper(id: "legacy-developer", name: "Legacy Developer", profileURL: "https://example.com/developer"))
        context.insert(DBGame(
            id: "legacy-game-a",
            title: "Legacy Game A",
            gameURL: "https://example.com/game-a",
            coverURL: "https://example.com/cover.jpg",
            descriptionText: "Saved legacy description",
            galleryURLs: ["https://example.com/one.jpg", "https://example.com/two.jpg"],
            discoveryTagsData: Data("legacy-tags".utf8),
            engine: "Ren'Py",
            developerID: "legacy-developer"
        ))
        context.insert(DBGame(id: "legacy-game-b", title: "Legacy Game B"))
        context.insert(DBLibraryEntry(gameID: "legacy-game-a", status: "playing", isFavorite: true, notes: "Keep this note"))
        context.insert(DBGameUpdate(
            id: "legacy-update-a",
            gameID: "legacy-game-a",
            title: "Legacy update",
            summary: "Historical update",
            detectedAt: Date(timeIntervalSince1970: 1_700_000_004),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            url: "https://example.com/update",
            sourceID: "legacy-source-a",
            isHistorical: true
        ))
        context.insert(DBCalendarEvent(
            id: "legacy-calendar-a",
            gameID: "legacy-game-a",
            title: "Legacy calendar event",
            date: nil,
            kind: "custom",
            sourceUpdateID: "legacy-update-a"
        ))
        context.insert(DBSparkMetadata(gameID: "legacy-game-a", runtimeSeconds: 1234, renpyVersion: "8.2.0", saveCount: 3))
        context.insert(DBTranslation(
            cacheKey: "legacy-translation",
            scope: "description",
            sourceHash: "legacy-hash",
            sourceText: "hello",
            targetLanguage: "zh-CN",
            translatedText: "你好"
        ))
        context.insert(DBDiscoverySnapshot(
            key: "legacy-discovery",
            payload: Data("legacy-payload".utf8),
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        ))
        context.insert(DBUpdateWatch(
            gameID: "legacy-game-a",
            entityTag: "legacy-etag",
            lastModified: "Wed, 01 Jan 2025 00:00:00 GMT",
            contentHash: "legacy-content-hash",
            hasBaseline: true,
            isEnabled: true
        ))
        context.insert(DBLibraryCollection(
            id: "legacy-collection",
            title: "Legacy collection",
            gameIDs: ["legacy-game-b", "legacy-game-a", "legacy-game-b"]
        ))
        context.insert(DBLibraryStatusEvent(
            id: "legacy-status-event",
            gameID: "legacy-game-a",
            fromStatus: nil,
            toStatus: "playing"
        ))
        context.insert(DBAppState(
            key: "legacy.test.state",
            stringValue: "preserve-me",
            dataValue: Data("opaque-state".utf8)
        ))

        try context.save()
    }
    @MainActor
    private func createExactUnversionedLegacyStore(at storeURL: URL) throws {
        // Build the database from the frozen V1 model types without attaching
        // VersionedSchema metadata, matching the released unversioned store.
        let schema = Schema(ItchPocketSchemaV1.models)
        let configuration = ModelConfiguration("itchPocket", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let developer = ItchPocketSchemaV1.DBDeveloper()
        developer.id = "legacy-developer"
        developer.name = "Legacy Developer"
        developer.profileURL = "https://example.com/developer"
        context.insert(developer)

        let gameA = ItchPocketSchemaV1.DBGame()
        gameA.id = "legacy-game-a"
        gameA.title = "Legacy Game A"
        gameA.gameURL = "https://example.com/game-a"
        gameA.coverURL = "https://example.com/cover.jpg"
        gameA.descriptionText = "Saved legacy description"
        gameA.galleryURLs = ["https://example.com/one.jpg", "https://example.com/two.jpg"]
        gameA.discoveryTagsData = Data("legacy-tags".utf8)
        gameA.engine = "Ren'Py"
        gameA.developerID = "legacy-developer"
        gameA.updatedAt = Date(timeIntervalSince1970: 1_700_000_001)
        context.insert(gameA)

        let gameB = ItchPocketSchemaV1.DBGame()
        gameB.id = "legacy-game-b"
        gameB.title = "Legacy Game B"
        context.insert(gameB)

        let entry = ItchPocketSchemaV1.DBLibraryEntry()
        entry.gameID = "legacy-game-a"
        entry.status = "playing"
        entry.isFavorite = true
        entry.notes = "Keep this note"
        entry.addedAt = Date(timeIntervalSince1970: 1_700_000_002)
        entry.updatedAt = Date(timeIntervalSince1970: 1_700_000_003)
        context.insert(entry)

        let update = ItchPocketSchemaV1.DBGameUpdate()
        update.id = "legacy-update-a"
        update.gameID = "legacy-game-a"
        update.title = "Legacy update"
        update.summary = "Historical update"
        update.detectedAt = Date(timeIntervalSince1970: 1_700_000_004)
        update.publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        update.url = "https://example.com/update"
        update.sourceID = "legacy-source-a"
        update.isHistorical = true
        context.insert(update)

        let event = ItchPocketSchemaV1.DBCalendarEvent()
        event.id = "legacy-calendar-a"
        event.gameID = "legacy-game-a"
        event.title = "Legacy calendar event"
        event.date = nil
        event.kind = "custom"
        event.reminderEnabled = true
        event.reminderMinutes = 45
        event.notes = "Calendar note"
        event.sourceFingerprint = "legacy-fingerprint"
        event.sourceUpdateID = "legacy-update-a"
        context.insert(event)

        let spark = ItchPocketSchemaV1.DBSparkMetadata()
        spark.gameID = "legacy-game-a"
        spark.runtimeSeconds = 1234
        spark.lastSaveAt = Date(timeIntervalSince1970: 1_700_000_005)
        spark.renpyVersion = "8.2.0"
        spark.saveCount = 3
        spark.scannedAt = Date(timeIntervalSince1970: 1_700_000_006)
        context.insert(spark)

        let translation = ItchPocketSchemaV1.DBTranslation()
        translation.cacheKey = "legacy-translation"
        translation.scope = "description"
        translation.sourceHash = "legacy-hash"
        translation.sourceText = "hello"
        translation.targetLanguage = "zh-CN"
        translation.translatedText = "你好"
        translation.updatedAt = Date(timeIntervalSince1970: 1_700_000_007)
        context.insert(translation)

        let snapshot = ItchPocketSchemaV1.DBDiscoverySnapshot()
        snapshot.key = "legacy-discovery"
        snapshot.payload = Data("legacy-payload".utf8)
        snapshot.fetchedAt = Date(timeIntervalSince1970: 1_700_000_008)
        snapshot.expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        context.insert(snapshot)

        let watch = ItchPocketSchemaV1.DBUpdateWatch()
        watch.gameID = "legacy-game-a"
        watch.entityTag = "legacy-etag"
        watch.lastModified = "Wed, 01 Jan 2025 00:00:00 GMT"
        watch.contentHash = "legacy-content-hash"
        watch.lastCheckedAt = Date(timeIntervalSince1970: 1_700_000_009)
        watch.hasBaseline = true
        watch.isEnabled = true
        context.insert(watch)

        let collection = ItchPocketSchemaV1.DBLibraryCollection()
        collection.id = "legacy-collection"
        collection.title = "Legacy collection"
        collection.gameIDs = ["legacy-game-b", "legacy-game-a", "legacy-game-b"]
        collection.createdAt = Date(timeIntervalSince1970: 1_700_000_010)
        collection.updatedAt = Date(timeIntervalSince1970: 1_700_000_011)
        context.insert(collection)

        let statusEvent = ItchPocketSchemaV1.DBLibraryStatusEvent()
        statusEvent.id = "legacy-status-event"
        statusEvent.gameID = "legacy-game-a"
        statusEvent.fromStatus = nil
        statusEvent.toStatus = "playing"
        statusEvent.changedAt = Date(timeIntervalSince1970: 1_700_000_012)
        context.insert(statusEvent)

        let appState = ItchPocketSchemaV1.DBAppState()
        appState.key = "legacy.test.state"
        appState.stringValue = "preserve-me"
        appState.dateValue = Date(timeIntervalSince1970: 1_700_000_013)
        appState.dataValue = Data("opaque-state".utf8)
        appState.updatedAt = Date(timeIntervalSince1970: 1_700_000_014)
        context.insert(appState)

        try context.save()
    }


    @MainActor
    private func legacyGameCount(at storeURL: URL) throws -> Int {
        let schema = Schema(versionedSchema: ItchPocketSchemaV1.self)
        let configuration = ModelConfiguration("itchPocket", schema: schema, url: storeURL, allowsSave: false)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return try container.mainContext.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBGame>())
    }


}
