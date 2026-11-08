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

        let games = try context.fetch(FetchDescriptor<DBGame>())
        let primaryGame = try XCTUnwrap(games.first { $0.id == "legacy-game-a" })
        XCTAssertEqual(primaryGame.title, "Legacy Game A")
        XCTAssertEqual(primaryGame.descriptionText, "Saved legacy description")
        XCTAssertEqual(primaryGame.galleryURLs, ["https://example.com/one.jpg", "https://example.com/two.jpg"])
        XCTAssertEqual(primaryGame.discoveryTagsData, Data("legacy-tags".utf8))

        let libraryEntry = try XCTUnwrap(
            context.fetch(FetchDescriptor<DBLibraryEntry>()).first
        )
        XCTAssertEqual(libraryEntry.gameID, "legacy-game-a")
        XCTAssertEqual(libraryEntry.status, "playing")
        XCTAssertTrue(libraryEntry.isFavorite)
        XCTAssertEqual(libraryEntry.notes, "Keep this note")

        let collection = try XCTUnwrap(
            context.fetch(FetchDescriptor<DBLibraryCollection>()).first
        )
        // V1 must preserve the old array exactly. De-duplication/reordering,
        // if ever needed, belongs to a separately tested later migration.
        XCTAssertEqual(collection.gameIDs, ["legacy-game-b", "legacy-game-a", "legacy-game-b"])

        let calendarEvent = try XCTUnwrap(
            context.fetch(FetchDescriptor<DBCalendarEvent>()).first
        )
        XCTAssertEqual(calendarEvent.gameID, "legacy-game-a")
        XCTAssertNil(calendarEvent.date)
        XCTAssertEqual(calendarEvent.sourceUpdateID, "legacy-update-a")

        let update = try XCTUnwrap(context.fetch(FetchDescriptor<DBGameUpdate>()).first)
        XCTAssertEqual(update.id, "legacy-update-a")
        XCTAssertEqual(update.sourceID, "legacy-source-a")
        XCTAssertTrue(update.isHistorical)

        let appState = try XCTUnwrap(context.fetch(FetchDescriptor<DBAppState>()).first)
        XCTAssertEqual(appState.key, "legacy.test.state")
        XCTAssertEqual(appState.stringValue, "preserve-me")
        XCTAssertEqual(appState.dataValue, Data("opaque-state".utf8))

        // A read-only open must not mutate the store as a side effect.
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    private func createUnversionedLegacyStore(at storeURL: URL) throws {
        // Keep this list in exact parity with the pre-migration AppDatabase
        // schema. This intentionally uses plain Schema([...]), not V1.
        let legacySchema = Schema([
            DBDeveloper.self,
            DBGame.self,
            DBLibraryEntry.self,
            DBGameUpdate.self,
            DBCalendarEvent.self,
            DBSparkMetadata.self,
            DBTranslation.self,
            DBDiscoverySnapshot.self,
            DBUpdateWatch.self,
            DBLibraryCollection.self,
            DBLibraryStatusEvent.self,
            DBAppState.self
        ])
        let configuration = ModelConfiguration(
            "itchPocket",
            schema: legacySchema,
            url: storeURL
        )

        do {
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [configuration]
            )
            let context = legacyContainer.mainContext

            context.insert(DBDeveloper(
                id: "legacy-developer",
                name: "Legacy Developer",
                profileURL: "https://example.com/developer"
            ))
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
            context.insert(DBGame(
                id: "legacy-game-b",
                title: "Legacy Game B"
            ))
            context.insert(DBLibraryEntry(
                gameID: "legacy-game-a",
                status: "playing",
                isFavorite: true,
                notes: "Keep this note"
            ))
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
            context.insert(DBSparkMetadata(
                gameID: "legacy-game-a",
                runtimeSeconds: 1234,
                renpyVersion: "8.2.0",
                saveCount: 3
            ))
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
}
