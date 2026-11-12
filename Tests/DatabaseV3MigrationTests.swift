import XCTest
import SwiftData
@testable import itchPocket

final class DatabaseV3MigrationTests: XCTestCase {
    @MainActor
    func testValidatedV3StoreStartsWithoutV1OrV2Backups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-without-backups-\(UUID().uuidString)", isDirectory: true)
        let v2Directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let v2StoreURL = v2Directory.appendingPathComponent("itchPocket-v2.store")
        try createV2Fixture(at: v2StoreURL, conflictingCollection: false)
        let expectedV3URL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)

        // Simulate loss of both older recovery snapshots after a successful
        // V3 cutover. A valid V3 store must remain the authoritative startup source.
        try FileManager.default.removeItem(at: v2Directory)
        let missingLegacyStoreURL = root.appendingPathComponent("itchPocket.store")
        let selectedURL = try AppDatabase.prepareDurableStore(legacyStoreURL: missingLegacyStoreURL)

        XCTAssertEqual(selectedURL, expectedV3URL)
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration("itchPocket-v3-no-backup-verify", schema: schema, url: selectedURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBGame>()), 2)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBGameDetail>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBLibraryCollectionItem>()), 2)
        }
    }

    @MainActor
    func testUnversionedV1StoreMigratesThroughV2IntoV3AndRestartsIdempotently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v1-to-v3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyStoreURL = root.appendingPathComponent("itchPocket.store")
        let v2Directory = root.appendingPathComponent(LegacyStoreBootstrap.v2DirectoryName, isDirectory: true)
        let v3Directory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)

        try autoreleasepool {
            let schema = Schema(ItchPocketSchemaV1.models)
            let configuration = ModelConfiguration("itchPocket", schema: schema, url: legacyStoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext

            let developer = ItchPocketSchemaV1.DBDeveloper()
            developer.id = "developer-v1"
            developer.name = "V1 Developer"
            developer.patreonURL = "https://patreon.com/v1creator"
            context.insert(developer)

            let game = ItchPocketSchemaV1.DBGame()
            game.id = "game-v1"
            game.title = "V1 Game"
            game.gameURL = "https://example.com/v1-game"
            game.descriptionText = "Description from unversioned V1"
            game.galleryURLs = ["https://cdn.example/v1-cover.png"]
            game.discoveryTagsData = Data("v1-tags".utf8)
            game.developerID = developer.id
            context.insert(game)

            let entry = ItchPocketSchemaV1.DBLibraryEntry()
            entry.gameID = game.id
            entry.status = "playing"
            context.insert(entry)

            let update = ItchPocketSchemaV1.DBGameUpdate()
            update.id = "update-v1"
            update.gameID = game.id
            update.summary = "V1 update"
            context.insert(update)

            let event = ItchPocketSchemaV1.DBCalendarEvent()
            event.id = "calendar-v1"
            event.gameID = game.id
            event.kind = "release"
            event.sourceUpdateID = update.id
            context.insert(event)

            let spark = ItchPocketSchemaV1.DBSparkMetadata()
            spark.gameID = game.id
            spark.runtimeSeconds = 321
            context.insert(spark)

            let watch = ItchPocketSchemaV1.DBUpdateWatch()
            watch.gameID = game.id
            watch.isEnabled = true
            context.insert(watch)

            let collection = ItchPocketSchemaV1.DBLibraryCollection()
            collection.id = "collection-v1"
            collection.title = "V1 Collection"
            collection.gameIDs = [game.id]
            context.insert(collection)

            let status = ItchPocketSchemaV1.DBLibraryStatusEvent()
            status.id = "status-v1"
            status.gameID = game.id
            status.toStatus = "playing"
            context.insert(status)

            try context.save()
        }

        let v2StoreURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyStoreURL,
            finalDirectory: v2Directory
        )
        let v3StoreURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStoreURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v3StoreURL.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: legacyStoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: v3StoreURL)

        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration("itchPocket-v3-e2e-verify", schema: schema, url: v3StoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext

            let game = try XCTUnwrap(context.fetch(FetchDescriptor<DBGame>()).first { $0.id == "game-v1" })
            XCTAssertEqual(game.title, "V1 Game")
            XCTAssertEqual(game.gameURL, "https://example.com/v1-game")
            XCTAssertEqual(game.developerID, "developer-v1")

            let detail = try XCTUnwrap(context.fetch(FetchDescriptor<DBGameDetail>()).first { $0.gameID == game.id })
            XCTAssertEqual(detail.descriptionText, "Description from unversioned V1")
            XCTAssertEqual(detail.galleryURLs, ["https://cdn.example/v1-cover.png"])
            XCTAssertEqual(detail.discoveryTagsData, Data("v1-tags".utf8))

            let collectionItems = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
            XCTAssertEqual(collectionItems.map(\.gameID), [game.id])
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryEntry>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGameUpdate>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBSparkMetadata>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBUpdateWatch>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLibraryStatusEvent>()), 1)
            let calendarEvent = try XCTUnwrap(context.fetch(FetchDescriptor<DBCalendarEvent>()).first)
            XCTAssertEqual(calendarEvent.sourceUpdateID, "update-v1")
        }

        let restartedV3URL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
        XCTAssertEqual(restartedV3URL, v3StoreURL)
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration("itchPocket-v3-e2e-restart", schema: schema, url: restartedV3URL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBGame>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBGameDetail>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBLibraryCollectionItem>()), 1)
        }
    }

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

        // Keep the verification container strictly inside this scope. The
        // SQLite integrity check and deferred temporary-directory cleanup must
        // run only after SwiftData has released every V3 store handle.
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration("itchPocket-v3-backfill-verify", schema: schema, url: v3StoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let detail = try XCTUnwrap(context.fetch(FetchDescriptor<DBGameDetail>()).first { $0.gameID == "game-a" })
            XCTAssertEqual(detail.descriptionText, "Legacy description")
            XCTAssertEqual(detail.galleryURLs, ["https://cdn.example/a.png"])
            XCTAssertEqual(detail.discoveryTagsData, Data("[]".utf8))
        }

        // Both stores are checked only after all SwiftData containers close.
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: v3StoreURL)
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
    func testV3MigrationRejectsDuplicateNormalizedCollectionMembersWithoutChangingV2() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-duplicate-members-\\(UUID().uuidString)", isDirectory: true)
        let v2Directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let v2StoreURL = v2Directory.appendingPathComponent("itchPocket-v2.store")

        try createV2Fixture(at: v2StoreURL, conflictingCollection: false)
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-duplicate-members-fixture", schema: schema, url: v2StoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.insert(ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem(
                id: "legacy-duplicate-membership-row",
                collectionID: "favorites",
                gameID: "game-a",
                sortOrder: 2
            ))
            try context.save()
        }

        let v3Directory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)) { error in
            guard let migrationError = error as? ItchPocketMigrationPlan.MigrationError,
                  case .duplicateCollectionMember("favorites") = migrationError else {
                return XCTFail("Expected duplicate normalized membership to be rejected, got \\(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v3Directory.path))
        let stagingDirectory = root.appendingPathComponent(V3StoreBootstrap.stagingDirectoryName, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)

        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-duplicate-members-verify", schema: schema, url: v2StoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let items = try context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem>())
                .filter { $0.collectionID == "favorites" }
            XCTAssertEqual(items.filter { $0.gameID == "game-a" }.count, 2)
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
        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)) { error in
            guard let migrationError = error as? ItchPocketMigrationPlan.MigrationError,
                  case .collectionMembershipConflict("favorites") = migrationError else {
                return XCTFail("Expected the V2 preflight to reject conflicting favorites membership, got \\(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v3Directory.path))
        let stagingDirectory = root.appendingPathComponent(V3StoreBootstrap.stagingDirectoryName, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
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
