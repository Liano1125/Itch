import XCTest
import SwiftData
@testable import itchPocket

final class LegacyStoreV1CompatibilityTests: XCTestCase {
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
    func testV1ToV2MigrationCopiesDetailsCollectionsAndCalendarSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v1-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("itchPocket.store")
        try createUnversionedLegacyStore(at: storeURL)

        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration("itchPocket", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, migrationPlan: ItchPocketMigrationPlan.self, configurations: [configuration])
        let context = container.mainContext

        let detail = try XCTUnwrap(context.fetch(FetchDescriptor<DBGameDetail>()).first { $0.gameID == "legacy-game-a" })
        XCTAssertEqual(detail.descriptionText, "Saved legacy description")
        XCTAssertEqual(detail.galleryURLs, ["https://example.com/one.jpg", "https://example.com/two.jpg"])
        XCTAssertEqual(detail.discoveryTagsData, Data("legacy-tags".utf8))
        XCTAssertNil(detail.fetchedAt)
        XCTAssertFalse(detail.isComplete)

        let items = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
            .filter { $0.collectionID == "legacy-collection" }
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(items.map(\.gameID), ["legacy-game-b", "legacy-game-a"])
        XCTAssertEqual(items.map(\.sortOrder), [0, 1])
        XCTAssertEqual(items.map(\.id), items.map {
            DBLibraryCollectionItem.stableID(collectionID: $0.collectionID, gameID: $0.gameID)
        })

        let migratedCollection = try XCTUnwrap(context.fetch(FetchDescriptor<DBLibraryCollection>()).first)
        XCTAssertEqual(migratedCollection.gameIDs, ["legacy-game-b", "legacy-game-a", "legacy-game-b"])

        let event = try XCTUnwrap(context.fetch(FetchDescriptor<DBCalendarEvent>()).first)
        XCTAssertEqual(event.gameTitleSnapshot, "Legacy Game A")
        XCTAssertEqual(event.sourceUpdateID, "legacy-update-a")
        XCTAssertNil(event.date)
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
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
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
}
