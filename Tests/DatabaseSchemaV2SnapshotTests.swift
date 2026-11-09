import XCTest
import SwiftData
@testable import itchPocket

final class DatabaseSchemaV2SnapshotTests: XCTestCase {
    @MainActor
    func testFrozenV2DiskStoreReopensThroughVersionedV2Schema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v2-disk-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("itchPocket-v2.store")

        do {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-disk-fixture", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.insert(ItchPocketSchemaV2Snapshot.DBGame(
                id: "disk-game",
                title: "Disk Game",
                descriptionText: "Retained legacy description",
                galleryURLs: ["https://cdn.example/disk.png"]
            ))
            context.insert(ItchPocketSchemaV2Snapshot.DBGameDetail(
                gameID: "disk-game",
                descriptionText: "Normalized description"
            ))
            context.insert(ItchPocketSchemaV2Snapshot.DBLibraryCollection(
                id: "disk-collection",
                title: "Disk Collection",
                gameIDs: ["disk-game"]
            ))
            try context.save()
        }

        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)

        // Reopen through the app's public V2 schema declaration, not the
        // fixture's direct snapshot schema, and verify legacy fields survive.
        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration("itchPocket-v2-disk-reopen", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let game = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>()).first)
        XCTAssertEqual(game.id, "disk-game")
        XCTAssertEqual(game.descriptionText, "Retained legacy description")
        XCTAssertEqual(game.galleryURLs, ["https://cdn.example/disk.png"])
        let collection = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollection>()).first)
        XCTAssertEqual(collection.gameIDs, ["disk-game"])
        let detail = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameDetail>()).first)
        XCTAssertEqual(detail.descriptionText, "Normalized description")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameDetail>()), 1)
        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)
    }

    @MainActor
    func testFrozenV2SchemaContainsAndPersistsAllFourteenModels() throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
        let configuration = ModelConfiguration(
            "itchPocket-v2-snapshot",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        context.insert(ItchPocketSchemaV2Snapshot.DBDeveloper(id: "developer-1", name: "Developer"))
        context.insert(ItchPocketSchemaV2Snapshot.DBGame(id: "game-1", title: "Game", descriptionText: "Legacy detail"))
        context.insert(ItchPocketSchemaV2Snapshot.DBLibraryEntry(gameID: "game-1", status: "playing"))
        context.insert(ItchPocketSchemaV2Snapshot.DBGameUpdate(id: "update-1", gameID: "game-1", summary: "Update"))
        context.insert(ItchPocketSchemaV2Snapshot.DBCalendarEvent(id: "event-1", gameID: "game-1", kind: "custom"))
        context.insert(ItchPocketSchemaV2Snapshot.DBSparkMetadata(gameID: "game-1", runtimeSeconds: 120))
        context.insert(ItchPocketSchemaV2Snapshot.DBTranslation(
            cacheKey: "translation-1",
            scope: "description",
            sourceHash: "hash",
            sourceText: "hello",
            targetLanguage: "zh-CN",
            translatedText: "你好"
        ))
        context.insert(ItchPocketSchemaV2Snapshot.DBDiscoverySnapshot(
            key: "discovery-1",
            payload: Data("payload".utf8),
            expiresAt: .distantFuture
        ))
        context.insert(ItchPocketSchemaV2Snapshot.DBUpdateWatch(gameID: "game-1"))
        context.insert(ItchPocketSchemaV2Snapshot.DBLibraryCollection(
            id: "collection-1",
            title: "Collection",
            gameIDs: ["game-1"]
        ))
        context.insert(ItchPocketSchemaV2Snapshot.DBLibraryStatusEvent(
            id: "status-1",
            gameID: "game-1",
            fromStatus: nil,
            toStatus: "playing"
        ))
        context.insert(ItchPocketSchemaV2Snapshot.DBAppState(key: "state-1", stringValue: "value"))
        context.insert(ItchPocketSchemaV2Snapshot.DBGameDetail(
            gameID: "game-1",
            descriptionText: "Normalized detail"
        ))
        context.insert(ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem(
            id: ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem.stableID(
                collectionID: "collection-1",
                gameID: "game-1"
            ),
            collectionID: "collection-1",
            gameID: "game-1",
            sortOrder: 0
        ))
        try context.save()

        XCTAssertEqual(ItchPocketSchemaV2Snapshot.models.count, 14)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBDeveloper>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameUpdate>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBCalendarEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBSparkMetadata>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBTranslation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBDiscoverySnapshot>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBUpdateWatch>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollection>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryStatusEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBAppState>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameDetail>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem>()), 1)

        let game = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>()).first)
        XCTAssertEqual(game.descriptionText, "Legacy detail")
        let collection = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollection>()).first)
        XCTAssertEqual(collection.gameIDs, ["game-1"])
    }
}
