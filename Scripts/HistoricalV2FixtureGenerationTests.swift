import XCTest
import SwiftData
@testable import itchPocket

/// This test is copied into the pinned historical V2 checkout by CI.
/// It intentionally compiles against that checkout's original top-level @Model
/// classes and ItchPocketSchemaV2, rather than today's frozen snapshot types.
final class HistoricalV2FixtureGenerationTests: XCTestCase {
    @MainActor
    func testGenerateHistoricalV2Fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["ITCHPOCKET_HISTORICAL_V2_FIXTURE_OUTPUT"],
              !path.isEmpty else {
            XCTFail("ITCHPOCKET_HISTORICAL_V2_FIXTURE_OUTPUT must point to the fixture store.")
            return
        }

        let storeURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration(
            "historical-v2-fixture",
            schema: schema,
            url: storeURL
        )
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext

            let developer = DBDeveloper(
                id: "historical-v2-developer",
                name: "Historical V2 Developer",
                profileURL: "https://example.com/developer",
                patreonURL: "https://patreon.com/historical-v2",
                updatedAt: timestamp
            )
            context.insert(developer)

            let game = DBGame(
                id: "historical-v2-game",
                title: "Historical V2 Game",
                gameURL: "https://example.com/historical-v2-game",
                coverURL: "https://cdn.example/historical-v2-cover.png",
                descriptionText: "Historical V2 game description",
                galleryURLs: ["https://cdn.example/historical-v2.png"],
                discoveryTagsData: Data("historical-v2-tags".utf8),
                engine: "Ren'Py",
                developerID: developer.id,
                updatedAt: timestamp
            )
            context.insert(game)

            context.insert(DBLibraryEntry(
                gameID: game.id,
                status: "playing",
                isFavorite: true,
                notes: "historical V2 library entry",
                addedAt: timestamp,
                updatedAt: timestamp
            ))

            let update = DBGameUpdate(
                id: "historical-v2-update",
                gameID: game.id,
                title: "Historical V2 update",
                summary: "Historical update summary",
                detectedAt: timestamp,
                publishedAt: timestamp,
                url: "https://example.com/historical-v2-update",
                sourceID: "historical-v2-source",
                isHistorical: true
            )
            context.insert(update)

            context.insert(DBCalendarEvent(
                id: "historical-v2-calendar",
                gameID: game.id,
                title: "Historical V2 calendar event",
                date: timestamp,
                kind: "release",
                reminderEnabled: true,
                reminderMinutes: 30,
                notes: "calendar note",
                sourceFingerprint: "historical-v2-fingerprint",
                sourceUpdateID: update.id,
                gameTitleSnapshot: game.title
            ))

            context.insert(DBSparkMetadata(
                gameID: game.id,
                runtimeSeconds: 9876,
                lastSaveAt: timestamp,
                renpyVersion: "8.2.0",
                saveCount: 12,
                scannedAt: timestamp
            ))

            context.insert(DBTranslation(
                cacheKey: "historical-v2-translation",
                scope: "game-detail",
                sourceHash: "historical-v2-hash",
                sourceText: "Hello",
                targetLanguage: "zh-CN",
                translatedText: "你好",
                updatedAt: timestamp
            ))

            context.insert(DBDiscoverySnapshot(
                key: "historical-v2-discovery",
                payload: Data("historical-v2-discovery-payload".utf8),
                fetchedAt: timestamp,
                expiresAt: timestamp.addingTimeInterval(3600)
            ))

            context.insert(DBUpdateWatch(
                gameID: game.id,
                entityTag: "historical-v2-etag",
                lastModified: "Tue, 14 Nov 2023 22:13:20 GMT",
                contentHash: "historical-v2-content-hash",
                lastCheckedAt: timestamp,
                hasBaseline: true,
                isEnabled: true
            ))

            context.insert(DBLibraryCollection(
                id: "historical-v2-collection",
                title: "Historical V2 Collection",
                gameIDs: [game.id],
                createdAt: timestamp,
                updatedAt: timestamp
            ))

            context.insert(DBLibraryStatusEvent(
                id: "historical-v2-status",
                gameID: game.id,
                fromStatus: "backlog",
                toStatus: "playing",
                changedAt: timestamp
            ))

            context.insert(DBAppState(
                key: "historical-v2-app-state",
                stringValue: "preserved",
                dateValue: timestamp,
                dataValue: Data("historical-v2-state".utf8),
                updatedAt: timestamp
            ))

            context.insert(DBGameDetail(
                gameID: game.id,
                descriptionText: "Historical normalized detail",
                galleryURLs: ["https://cdn.example/historical-v2.png"],
                discoveryTagsData: Data("historical-v2-normalized-tags".utf8),
                fetchedAt: timestamp,
                isComplete: true
            ))

            context.insert(DBLibraryCollectionItem(
                id: DBLibraryCollectionItem.stableID(
                    collectionID: "historical-v2-collection",
                    gameID: game.id
                ),
                collectionID: "historical-v2-collection",
                gameID: game.id,
                sortOrder: 0,
                addedAt: timestamp
            ))

            try context.save()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }
}
