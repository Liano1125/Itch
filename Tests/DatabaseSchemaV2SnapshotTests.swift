import XCTest
import SwiftData
@testable import itchPocket

final class DatabaseSchemaV2SnapshotTests: XCTestCase {
    @MainActor
    func testFrozenV2SnapshotCanReadStoreCreatedByCurrentV2Models() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v2-schema-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("itchPocket-v2.store")
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
            let configuration = ModelConfiguration("itchPocket-v2", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext

            context.insert(DBDeveloper(id: "developer-1", name: "Developer"))
            context.insert(DBGame(id: "game-1", title: "Game", descriptionText: "Legacy detail"))
            context.insert(DBLibraryEntry(gameID: "game-1", status: "playing"))
            context.insert(DBGameUpdate(id: "update-1", gameID: "game-1", summary: "Update"))
            context.insert(DBCalendarEvent(id: "event-1", gameID: "game-1", kind: "custom"))
            context.insert(DBSparkMetadata(gameID: "game-1", runtimeSeconds: 120))
            context.insert(DBTranslation(
                cacheKey: "translation-1",
                scope: "description",
                sourceHash: "hash",
                sourceText: "hello",
                targetLanguage: "zh-CN",
                translatedText: "你好"
            ))
            context.insert(DBDiscoverySnapshot(
                key: "discovery-1",
                payload: Data("payload".utf8),
                expiresAt: .distantFuture
            ))
            context.insert(DBUpdateWatch(gameID: "game-1"))
            context.insert(DBLibraryCollection(id: "collection-1", title: "Collection", gameIDs: ["game-1"]))
            context.insert(DBLibraryStatusEvent(id: "status-1", gameID: "game-1", fromStatus: nil, toStatus: "playing"))
            context.insert(DBAppState(key: "state-1", stringValue: "value"))
            context.insert(DBGameDetail(gameID: "game-1", descriptionText: "Normalized detail"))
            context.insert(DBLibraryCollectionItem(
                id: DBLibraryCollectionItem.stableID(collectionID: "collection-1", gameID: "game-1"),
                collectionID: "collection-1",
                gameID: "game-1",
                sortOrder: 0
            ))
            try context.save()
        }

        try autoreleasepool {
                let snapshotSchema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let readOnlyConfiguration = ModelConfiguration(
                "itchPocket-v2",
                schema: snapshotSchema,
                url: storeURL,
                allowsSave: false
            )
            let snapshotContainer = try ModelContainer(
                for: snapshotSchema,
                configurations: [readOnlyConfiguration]
            )
            let snapshotContext = snapshotContainer.mainContext

            XCTAssertEqual(ItchPocketSchemaV2Snapshot.models.count, 14)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBDeveloper>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryEntry>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameUpdate>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBCalendarEvent>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBSparkMetadata>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBTranslation>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBDiscoverySnapshot>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBUpdateWatch>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollection>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryStatusEvent>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBAppState>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameDetail>()), 1)
            XCTAssertEqual(try snapshotContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem>()), 1)

            let game = try XCTUnwrap(snapshotContext.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>()).first)
            XCTAssertEqual(game.descriptionText, "Legacy detail")
            let collection = try XCTUnwrap(snapshotContext.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollection>()).first)
            XCTAssertEqual(collection.gameIDs, ["game-1"])
        }
    }
}
