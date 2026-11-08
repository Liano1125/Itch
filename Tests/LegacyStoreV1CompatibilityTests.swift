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

        // Reopen the exact same on-disk store with the new VersionedSchema
        // declaration. No migration stage is involved because V1 must be
        // structurally identical to the legacy schema.
        let versionedSchema = Schema(versionedSchema: ItchPocketSchemaV1.self)
        let configuration = ModelConfiguration(
            "itchPocket",
            schema: versionedSchema,
            url: storeURL
        )
        let container = try ModelContainer(
            for: versionedSchema,
            configurations: [configuration]
        )
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

        let libraryEntry = try XCTUnwrap(
            context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBLibraryEntry>()).first
        )
        XCTAssertEqual(libraryEntry.gameID, "legacy-game-a")
        XCTAssertEqual(libraryEntry.status, "playing")
        XCTAssertTrue(libraryEntry.isFavorite)
        XCTAssertEqual(libraryEntry.notes, "Keep this note")

        let collection = try XCTUnwrap(
            context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBLibraryCollection>()).first
        )
        // V1 must preserve the old array exactly. De-duplication/reordering,
        // if ever needed, belongs to a separately tested later migration.
        XCTAssertEqual(collection.gameIDs, ["legacy-game-b", "legacy-game-a", "legacy-game-b"])

        let calendarEvent = try XCTUnwrap(
            context.fetch(FetchDescriptor<ItchPocketSchemaV1.DBCalendarEvent>()).first
        )
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

        // Versioned nested model snapshots must retain the entity names of
        // the original top-level model classes used by the shipped app.
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBGame.self), Schema.entityName(for: DBGame.self))
        XCTAssertEqual(Schema.entityName(for: ItchPocketSchemaV1.DBCalendarEvent.self), Schema.entityName(for: DBCalendarEvent.self))

        // A read-only open must not mutate the store as a side effect.
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
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ItchPocketMigrationPlan.self,
            configurations: [configuration]
        )
        let context = container.mainContext

        let detail = try XCTUnwrap(
            context.fetch(FetchDescriptor<DBGameDetail>()).first { $0.gameID == "legacy-game-a" }
        )
        XCTAssertEqual(detail.descriptionText, "Saved legacy description")
        XCTAssertEqual(detail.galleryURLs, [
            "https://example.com/one.jpg", "https://example.com/two.jpg"
        ])
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

        let migratedCollection = try XCTUnwrap(
            context.fetch(FetchDescriptor<DBLibraryCollection>()).first
        )
        XCTAssertEqual(
            migratedCollection.gameIDs,
            ["legacy-game-b", "legacy-game-a", "legacy-game-b"]
        )

        let event = try XCTUnwrap(context.fetch(FetchDescriptor<DBCalendarEvent>()).first)
        XCTAssertEqual(event.gameTitleSnapshot, "Legacy Game A")
        XCTAssertEqual(event.sourceUpdateID, "legacy-update-a")
        XCTAssertNil(event.date)
    }

    @MainActor
    private func createUnversionedLegacyStore(at storeURL: URL) throws {
        // Create a plain, unversioned store using the frozen V1 model snapshot.
        // This mirrors the shipped twelve-entity shape without importing V2 fields.
        let legacySchema = Schema(ItchPocketSchemaV1.models)
        let configuration = ModelConfiguration("itchPocket", schema: legacySchema, url: storeURL)
        let legacyContainer = try ModelContainer(for: legacySchema, configurations: [configuration])
        let context = legacyContainer.mainContext

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
        context.insert(gameA)

        let gameB = ItchPocketSchemaV1.DBGame()
        gameB.id = "legacy-game-b"
        gameB.title = "Legacy Game B"
        context.insert(gameB)

        let libraryEntry = ItchPocketSchemaV1.DBLibraryEntry()
        libraryEntry.gameID = "legacy-game-a"
        libraryEntry.status = "playing"
        libraryEntry.isFavorite = true
        libraryEntry.notes = "Keep this note"
        context.insert(libraryEntry)

        let update = ItchPocketSchemaV1.DBGameUpdate()
        update.id = "legacy-update-a"
        update.gameID = "legacy-game-a"
        update.title = "Legacy update"
        update.summary = "Historical update"
        update.publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        update.sourceID = "legacy-source-a"
        update.isHistorical = true
        context.insert(update)

        let calendarEvent = ItchPocketSchemaV1.DBCalendarEvent()
        calendarEvent.id = "legacy-calendar-a"
        calendarEvent.gameID = "legacy-game-a"
        calendarEvent.title = "Legacy calendar event"
        calendarEvent.date = nil
        calendarEvent.kind = "custom"
        calendarEvent.sourceUpdateID = "legacy-update-a"
        context.insert(calendarEvent)

        let spark = ItchPocketSchemaV1.DBSparkMetadata()
        spark.gameID = "legacy-game-a"
        spark.runtimeSeconds = 1234
        spark.renpyVersion = "8.2.0"
        spark.saveCount = 3
        context.insert(spark)

        let translation = ItchPocketSchemaV1.DBTranslation()
        translation.cacheKey = "legacy-translation"
        translation.scope = "description"
        translation.sourceHash = "legacy-hash"
        translation.sourceText = "hello"
        translation.targetLanguage = "zh-CN"
        translation.translatedText = "你好"
        context.insert(translation)

        let discovery = ItchPocketSchemaV1.DBDiscoverySnapshot()
        discovery.key = "legacy-discovery"
        discovery.payload = Data("legacy-payload".utf8)
        discovery.expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        context.insert(discovery)

        let watch = ItchPocketSchemaV1.DBUpdateWatch()
        watch.gameID = "legacy-game-a"
        watch.entityTag = "legacy-etag"
        watch.lastModified = "Wed, 01 Jan 2025 00:00:00 GMT"
        watch.contentHash = "legacy-content-hash"
        watch.hasBaseline = true
        watch.isEnabled = true
        context.insert(watch)

        let collection = ItchPocketSchemaV1.DBLibraryCollection()
        collection.id = "legacy-collection"
        collection.title = "Legacy collection"
        collection.gameIDs = ["legacy-game-b", "legacy-game-a", "legacy-game-b"]
        context.insert(collection)

        let statusEvent = ItchPocketSchemaV1.DBLibraryStatusEvent()
        statusEvent.id = "legacy-status-event"
        statusEvent.gameID = "legacy-game-a"
        statusEvent.toStatus = "playing"
        context.insert(statusEvent)

        let appState = ItchPocketSchemaV1.DBAppState()
        appState.key = "legacy.test.state"
        appState.stringValue = "preserve-me"
        appState.dataValue = Data("opaque-state".utf8)
        context.insert(appState)

        try context.save()
    }
}
