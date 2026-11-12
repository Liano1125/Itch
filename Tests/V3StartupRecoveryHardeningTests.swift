import XCTest
import SwiftData
@testable import itchPocket

final class V3StartupRecoveryHardeningTests: XCTestCase {
    @MainActor
    func testFailedV2BackfillIsSurfacedWithoutQuarantiningValidV3AndCanRetry() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-backfill-retry-\(UUID().uuidString)", isDirectory: true)
        let v2Directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        let v2StoreURL = v2Directory.appendingPathComponent("itchPocket-v2.store")
        let v3Directory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        let v3StoreURL = v3Directory.appendingPathComponent(V3StoreBootstrap.storeFileName)
        let recoveryMarkerURL = v3Directory.appendingPathComponent(".v2-detail-recovery-v1")
        let backupDirectory = root.appendingPathComponent("v2-backup", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: v2Directory, withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration(
                "itchPocket-v2-backfill-retry-fixture-\(UUID().uuidString)",
                schema: schema,
                url: v2StoreURL
            )
            var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
            do {
                let context = container!.mainContext
                context.insert(
                    ItchPocketSchemaV2Snapshot.DBGame(
                        id: "game-a",
                        title: "Game A",
                        descriptionText: "Preserved legacy description"
                    )
                )
                try context.save()
            }
            container = nil
        }

        _ = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
        XCTAssertTrue(fileManager.fileExists(atPath: v3StoreURL.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v3StoreURL)

        // Simulate an interrupted/unfinished one-time backfill: remove its
        // completion marker, then make the retained V2 source unreadable.
        try fileManager.removeItem(at: recoveryMarkerURL)
        try fileManager.copyItem(at: v2Directory, to: backupDirectory)
        try Data("corrupt V2 backup".utf8).write(to: v2StoreURL)

        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL))

        // The valid V3 database remains in place; a backup-read failure must
        // not be mistaken for V3 corruption and must not quarantine it.
        XCTAssertTrue(fileManager.fileExists(atPath: v3StoreURL.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v3StoreURL)
        XCTAssertFalse(
            try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix("itchPocket-v3.quarantine-") }
        )

        try fileManager.removeItem(at: v2Directory)
        try fileManager.copyItem(at: backupDirectory, to: v2Directory)

        let retriedURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
        XCTAssertEqual(retriedURL, v3StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: retriedURL)
        XCTAssertTrue(fileManager.fileExists(atPath: recoveryMarkerURL.path))
    }
    @MainActor
    func testMissingV2BackupWithIncompleteRecoveryMarkerFailsWithoutQuarantiningV3() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-missing-backup-incomplete-\(UUID().uuidString)", isDirectory: true)
        let v2Directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        let v2StoreURL = v2Directory.appendingPathComponent("itchPocket-v2.store")
        let v3Directory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        let v3StoreURL = v3Directory.appendingPathComponent(V3StoreBootstrap.storeFileName)
        let detailMarkerURL = v3Directory.appendingPathComponent(".v2-detail-recovery-v1")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: v2Directory, withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration(
                "itchPocket-v2-missing-backup-incomplete-\(UUID().uuidString)",
                schema: schema,
                url: v2StoreURL
            )
            var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
            do {
                let context = container!.mainContext
                context.insert(
                    ItchPocketSchemaV2Snapshot.DBGame(
                        id: "game-a",
                        title: "Game A",
                        descriptionText: "Recoverable legacy description"
                    )
                )
                try context.save()
            }
            container = nil
        }

        _ = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
        XCTAssertTrue(fileManager.fileExists(atPath: v3StoreURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: detailMarkerURL.path))

        // An absent marker means a recovery generation is not known to have
        // completed. Losing its source backup must fail closed, even though
        // the V3 SQLite file itself remains structurally healthy.
        try fileManager.removeItem(at: detailMarkerURL)
        try fileManager.removeItem(at: v2Directory)

        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL))
        XCTAssertTrue(fileManager.fileExists(atPath: v3StoreURL.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v3StoreURL)
        XCTAssertFalse(
            try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix("itchPocket-v3.quarantine-") }
        )
    }

}
