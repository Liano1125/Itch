import XCTest
import SwiftData
@testable import itchPocket

final class DatabaseV3MigrationTests: XCTestCase {
    @MainActor
    func testV3BootstrapMigratesNormalizedRecordsAndRetainsV2Backup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-migration-\(UUID().uuidString)", isDirectory: true)
        let v2Directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let v2StoreURL = v2Directory.appendingPathComponent("itchPocket-v2.store")

        try createV2Fixture(at: v2StoreURL, conflictingCollection: false)
        let v3StoreURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v3StoreURL.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: v3StoreURL)

        let v3Schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
        let v3Configuration = ModelConfiguration(
            V3StoreBootstrap.directoryName,
            schema: v3Schema,
            url: v3StoreURL
        )
        let v3Container = try ModelContainer(for: v3Schema, configurations: [v3Configuration])
        let v3Context = v3Container.mainContext

        let game = try XCTUnwrap(v3Context.fetch(FetchDescriptor<DBGame>()).first { $0.id == "game-a" })
        XCTAssertEqual(game.title, "Game A")
        let detail = try XCTUnwrap(v3Context.fetch(FetchDescriptor<DBGameDetail>()).first { $0.gameID == "game-a" })
        XCTAssertEqual(detail.descriptionText, "Legacy description")
        XCTAssertEqual(detail.galleryURLs, ["https://cdn.example/a.png"])
        XCTAssertEqual(detail.discoveryTagsData, Data("[]".utf8))

        let items = try v3Context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(items.map(\.gameID), ["game-b", "game-a"])
        XCTAssertEqual(items.map(\.sortOrder), [0, 1])
        XCTAssertTrue(try v3Context.fetch(FetchDescriptor<DBLibraryCollection>()).contains { $0.id == "favorites" })

        // Reopen the untouched V2 source and verify its compatibility fields
        // remain available for recovery after a successful V3 migration.
        let v2Schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
        let v2Configuration = ModelConfiguration("itchPocket-v2-backup", schema: v2Schema, url: v2StoreURL)
        let v2Container = try ModelContainer(for: v2Schema, configurations: [v2Configuration])
        let v2Context = v2Container.mainContext
        let oldGame = try XCTUnwrap(v2Context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>()).first { $0.id == "game-a" })
        XCTAssertEqual(oldGame.descriptionText, "Legacy description")
        XCTAssertEqual(oldGame.galleryURLs, ["https://cdn.example/a.png"])
        let staleDetail = try XCTUnwrap(v2Context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameDetail>()).first)
        XCTAssertEqual(staleDetail.descriptionText, "Stale normalized description")
        let oldCollection = try XCTUnwrap(v2Context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollection>()).first)
        XCTAssertEqual(oldCollection.gameIDs, ["game-b", "game-a", "game-b"])
    }

    @MainActor
    func testExistingV3StoreBackfillsMissingDetailsFromRetainedV2Backup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-backfill-\\(UUID().uuidString)", isDirectory: true)
        let v2Directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        let v3Directory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: v2Directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: v3Directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let v2StoreURL = v2Directory.appendingPathComponent("itchPocket-v2.store")
        let v3StoreURL = v3Directory.appendingPathComponent(V3StoreBootstrap.storeFileName)
        try createV2Fixture(at: v2StoreURL, conflictingCollection: false)

        // Simulate a previously-created V3 store whose detail payloads are empty.
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration("itchPocket-v3-incomplete-fixture", schema: schema, url: v3StoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.insert(DBGame(id: "game-a", title: "Game A"))
            context.insert(DBGame(id: "game-b", title: "Game B"))
            context.insert(DBGameDetail(gameID: "game-a"))
            try context.save()
        }

        _ = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)

        let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
        let configuration = ModelConfiguration("itchPocket-v3-backfill-verify", schema: schema, url: v3StoreURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let detail = try XCTUnwrap(context.fetch(FetchDescriptor<DBGameDetail>()).first { $0.gameID == "game-a" })
        XCTAssertEqual(detail.descriptionText, "Legacy description")
        XCTAssertEqual(detail.galleryURLs, ["https://cdn.example/a.png"])
        XCTAssertEqual(detail.discoveryTagsData, Data("[]".utf8))

        // Recovery must not modify or replace the V2 source.
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
    }

    @MainActor
    func testV3MigrationRejectsOrphanedGameReferencesWithoutChangingV2() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-orphaned-references-\(UUID().uuidString)", isDirectory: true)
        let v2Directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let v2StoreURL = v2Directory.appendingPathComponent("itchPocket-v2.store")

        try createV2Fixture(at: v2StoreURL, conflictingCollection: false)
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-orphan-fixture", schema: schema, url: v2StoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.insert(ItchPocketSchemaV2Snapshot.DBLibraryEntry(
                gameID: "missing-game",
                status: "playing"
            ))
            context.insert(ItchPocketSchemaV2Snapshot.DBGameUpdate(
                id: "orphan-update",
                gameID: "missing-game",
                summary: "Orphan update"
            ))
            context.insert(ItchPocketSchemaV2Snapshot.DBCalendarEvent(
                id: "orphan-event",
                gameID: "missing-game",
                kind: "release"
            ))
            context.insert(ItchPocketSchemaV2Snapshot.DBSparkMetadata(
                gameID: "missing-game",
                runtimeSeconds: 42
            ))
            context.insert(ItchPocketSchemaV2Snapshot.DBUpdateWatch(gameID: "missing-game"))
            context.insert(ItchPocketSchemaV2Snapshot.DBLibraryStatusEvent(
                id: "orphan-status",
                gameID: "missing-game",
                fromStatus: nil,
                toStatus: "playing"
            ))
            try context.save()
        }

        let v3Directory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v3Directory.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)

        // The retained source still contains every orphaned row; migration
        // fails closed rather than silently dropping or rewriting user data.
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-orphan-verify", schema: schema, url: v2StoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryEntry>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameUpdate>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBCalendarEvent>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBSparkMetadata>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBUpdateWatch>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryStatusEvent>()), 1)
        }
    }

    @MainActor
    func testV3MigrationRejectsConflictingMembershipWithoutChangingV2() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-conflict-\(UUID().uuidString)", isDirectory: true)
        let v2Directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let v2StoreURL = v2Directory.appendingPathComponent("itchPocket-v2.store")

        try createV2Fixture(at: v2StoreURL, conflictingCollection: true)
        let v3Directory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v3Directory.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
    }

    @MainActor
    private func createV2Fixture(at storeURL: URL, conflictingCollection: Bool) throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-fixture", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.insert(ItchPocketSchemaV2Snapshot.DBGame(
                id: "game-a",
                title: "Game A",
                descriptionText: "Legacy description",
                galleryURLs: ["https://cdn.example/a.png"],
                discoveryTagsData: Data("[]".utf8)
            ))
            context.insert(ItchPocketSchemaV2Snapshot.DBGame(id: "game-b", title: "Game B"))
            context.insert(ItchPocketSchemaV2Snapshot.DBGameDetail(
            gameID: "game-a",
            descriptionText: "Stale normalized description",
            galleryURLs: ["https://cdn.example/stale.png"],
            discoveryTagsData: Data("stale".utf8)
        ))
            context.insert(ItchPocketSchemaV2Snapshot.DBLibraryCollection(
                id: "favorites",
                title: "Favorites",
                gameIDs: ["game-b", "game-a", "game-b"]
            ))
            if conflictingCollection {
                context.insert(ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem(
                    id: ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem.stableID(
                        collectionID: "favorites",
                        gameID: "game-a"
                    ),
                    collectionID: "favorites",
                    gameID: "game-a",
                    sortOrder: 0
                ))
            }
            try context.save()
        }
    }
}
