import XCTest
import SwiftData
@testable import itchPocket

final class V3StartupRecoveryHardeningTests: XCTestCase {
    @MainActor
    func testFailedV2BackfillIsSurfacedWithoutQuarantiningValidV3AndCanRetry() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-backfill-retry-\\(UUID().uuidString)", isDirectory: true)
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
                "itchPocket-v2-backfill-retry-fixture",
                schema: schema,
                url: v2StoreURL
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.insert(
                ItchPocketSchemaV2Snapshot.DBGame(
                    id: "game-a",
                    title: "Game A",
                    descriptionText: "Preserved legacy description"
                )
            )
            try container.mainContext.save()
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
}
