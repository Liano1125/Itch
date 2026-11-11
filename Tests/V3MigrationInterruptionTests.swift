import XCTest
import SwiftData
@testable import itchPocket

final class V3MigrationInterruptionTests: XCTestCase {
    private enum SimulatedInterruption: Error {
        case requested
    }

    @MainActor
    func testInterruptionAfterCopyKeepsV2AndRetryCompletesMigration() throws {
        let root = try makeRoot()
        // Keep this fixture directory until the simulator process exits. The
        // retry path can leave CoreData/SQLite file descriptors alive briefly
        // after SwiftData containers are released; unlinking the store family
        // during XCTest teardown triggers SQLite's vnode-unlinked diagnostic.
        // The CI simulator is ephemeral, so its sandbox reclaims this directory.
        try autoreleasepool {
        let v2StoreURL = try makeV2Store(in: root)
        let stagingDirectory = root.appendingPathComponent(V3StoreBootstrap.stagingDirectoryName, isDirectory: true)
        let finalDirectory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)

        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(
            v2StoreURL: v2StoreURL,
            afterPhase: { phase in
                if phase == .sourceCopiedToStaging {
                    throw SimulatedInterruption.requested
                }
            }
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalDirectory.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)

        let recoveredURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: recoveredURL)
        XCTAssertEqual(try v3GameCount(at: recoveredURL), 2)
        }
    }

    @MainActor
    func testRepeatedInterruptedMigrationAndBackfillRecoveryIsStableAndIdempotent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Drain any autoreleased CoreData/SQLite objects before the temporary store family is removed.
        try autoreleasepool {
        let v2StoreURL = try makeV2Store(in: root)
        let v3Directory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        let v3StoreURL = v3Directory.appendingPathComponent(V3StoreBootstrap.storeFileName)
        let recoveryMarkerURL = v3Directory.appendingPathComponent(".v2-detail-recovery-v1")

        // Exercise the copy/interruption/retry boundary once, then repeatedly
        // replay the one-time backfill by removing only its completion marker.
        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(
            v2StoreURL: v2StoreURL,
            afterPhase: { phase in
                if phase == .sourceCopiedToStaging {
                    throw SimulatedInterruption.requested
                }
            }
        ))

        for iteration in 0..<12 {
            let recoveredURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
            XCTAssertEqual(recoveredURL, v3StoreURL, "Unexpected V3 URL on iteration \(iteration)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryMarkerURL.path))
            XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)
            XCTAssertEqual(try v3GameCount(at: recoveredURL), 2)
            try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
            try SQLiteStoreIntegrityChecker.quickCheck(at: recoveredURL)

            let detailCount = try autoreleasepool {
                let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
                let configuration = ModelConfiguration(
                    "itchPocket-v3-stress-verify-\(UUID().uuidString)",
                    schema: schema,
                    url: recoveredURL,
                    allowsSave: false
                )
                var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
                let count = try container!.mainContext.fetchCount(FetchDescriptor<DBGameDetail>())
                container = nil
                return count
            }
            XCTAssertEqual(detailCount, 1, "Backfill duplicated detail rows on iteration \(iteration)")

            if iteration < 11 {
                try FileManager.default.removeItem(at: recoveryMarkerURL)
            }
        }

        // The legacy source remains intact after every retry and replay.
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        }
    }


    @MainActor
    func testInterruptionAfterBackfillSaveRetriesWithoutDuplicatingDetails() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try autoreleasepool {
            let v2StoreURL = try makeV2Store(in: root)
            let v3StoreURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
            let markerURL = v3StoreURL.deletingLastPathComponent()
                .appendingPathComponent(".v2-detail-recovery-v1")

            // Simulate an older/incomplete V3 store that still needs its V2
            // detail backfill. The existing V3 store itself remains valid.
            try FileManager.default.removeItem(at: markerURL)
            try autoreleasepool {
                let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
                let configuration = ModelConfiguration(
                    "itchPocket-v3-backfill-interruption-setup",
                    schema: schema,
                    url: v3StoreURL
                )
                var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
                do {
                    let context = container!.mainContext
                    let details = try context.fetch(FetchDescriptor<DBGameDetail>())
                    for detail in details { context.delete(detail) }
                    try context.save()
                }
                container = nil
            }

            XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(
                v2StoreURL: v2StoreURL,
                afterPhase: { phase in
                    if phase == .backfillApplied {
                        throw SimulatedInterruption.requested
                    }
                }
            ))

            // The data write completed, but the completion marker did not.
            // A restart must replay the backfill safely rather than duplicate it.
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
            XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)

            let interruptedSnapshot = try autoreleasepool {
                let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
                let configuration = ModelConfiguration(
                    "itchPocket-v3-backfill-interruption-verify",
                    schema: schema,
                    url: v3StoreURL,
                    allowsSave: false
                )
                var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
                let context = container!.mainContext
                let details = try context.fetch(FetchDescriptor<DBGameDetail>())
                let snapshot = (details.count, details.first?.descriptionText)
                container = nil
                return snapshot
            }
            XCTAssertEqual(interruptedSnapshot.0, 1)
            XCTAssertEqual(interruptedSnapshot.1, "Keep this legacy detail")

            let restartedURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
            XCTAssertEqual(restartedURL, v3StoreURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
            XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)

            let finalSnapshot = try autoreleasepool {
                let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
                let configuration = ModelConfiguration(
                    "itchPocket-v3-backfill-interruption-final",
                    schema: schema,
                    url: restartedURL,
                    allowsSave: false
                )
                var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
                let context = container!.mainContext
                let details = try context.fetch(FetchDescriptor<DBGameDetail>())
                let snapshot = (details.count, details.first?.descriptionText)
                container = nil
                return snapshot
            }
            XCTAssertEqual(finalSnapshot.0, 1)
            XCTAssertEqual(finalSnapshot.1, "Keep this legacy detail")
            try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
            try SQLiteStoreIntegrityChecker.quickCheck(at: restartedURL)
        }
    }

    @MainActor
    func testInterruptionAfterStagingValidationKeepsV2AndRetryCompletesMigration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Drain any autoreleased CoreData/SQLite objects before the temporary store family is removed.
        try autoreleasepool {
        let v2StoreURL = try makeV2Store(in: root)
        let stagingDirectory = root.appendingPathComponent(V3StoreBootstrap.stagingDirectoryName, isDirectory: true)
        let finalDirectory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)

        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(
            v2StoreURL: v2StoreURL,
            afterPhase: { phase in
                if phase == .stagingMigratedAndValidated {
                    throw SimulatedInterruption.requested
                }
            }
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalDirectory.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)

        let recoveredURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: recoveredURL)
        XCTAssertEqual(try v3GameCount(at: recoveredURL), 2)
        }
    }

    @MainActor
    func testInterruptionImmediatelyAfterPromotionReusesValidatedV3OnRestart() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Drain any autoreleased CoreData/SQLite objects before the temporary store family is removed.
        try autoreleasepool {
        let v2StoreURL = try makeV2Store(in: root)
        let stagingDirectory = root.appendingPathComponent(V3StoreBootstrap.stagingDirectoryName, isDirectory: true)
        let finalDirectory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        let finalStoreURL = finalDirectory.appendingPathComponent(V3StoreBootstrap.storeFileName)

        XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(
            v2StoreURL: v2StoreURL,
            afterPhase: { phase in
                if phase == .stagingPromoted {
                    throw SimulatedInterruption.requested
                }
            }
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: v2StoreURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalStoreURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: finalStoreURL)
        XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)
        XCTAssertEqual(try v3GameCount(at: finalStoreURL), 2)

        let restartedURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
        XCTAssertEqual(restartedURL, finalStoreURL)
        XCTAssertEqual(try v3GameCount(at: restartedURL), 2)
        XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)
        }
    }

    @MainActor
    func testExplicitRecoveryQuarantinesInvalidV3AndIgnoresStaleStagingAndQuarantine() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Drain any autoreleased CoreData/SQLite objects before the temporary store family is removed.
        try autoreleasepool {
        let v2StoreURL = try makeV2Store(in: root)
        let stagingDirectory = root.appendingPathComponent(V3StoreBootstrap.stagingDirectoryName, isDirectory: true)
        let finalDirectory = root.appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
        let existingQuarantine = root.appendingPathComponent("itchPocket-v3.quarantine-existing", isDirectory: true)

        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try Data("stale staging".utf8).write(to: stagingDirectory.appendingPathComponent("partial"))
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let invalidV3Bytes = Data("invalid V3 store".utf8)
        try invalidV3Bytes.write(to: finalDirectory.appendingPathComponent(V3StoreBootstrap.storeFileName))
        try FileManager.default.createDirectory(at: existingQuarantine, withIntermediateDirectories: true)
        let quarantineMarker = existingQuarantine.appendingPathComponent("preserve-me")
        try Data("prior quarantine".utf8).write(to: quarantineMarker)

        let recoveredURL = try V3StoreBootstrap.prepareStore(
            v2StoreURL: v2StoreURL,
            recoverInvalidExistingV3: true
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
        XCTAssertEqual(try Data(contentsOf: quarantineMarker), Data("prior quarantine".utf8))

        // Check both stores immediately after recovery, before reopening either
        // through SwiftData for logical assertions. This keeps SQLite's raw
        // integrity connection isolated from any persistent-store lifecycle.
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: recoveredURL)

        XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)
        XCTAssertEqual(try v3GameCount(at: recoveredURL), 2)

        let quarantinedDirectories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { $0.lastPathComponent.hasPrefix("itchPocket-v3.quarantine-") }
        XCTAssertGreaterThanOrEqual(quarantinedDirectories.count, 2)
        let movedInvalidStore = try XCTUnwrap(quarantinedDirectories.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(V3StoreBootstrap.storeFileName).path)
        })
        XCTAssertEqual(
            try Data(contentsOf: movedInvalidStore.appendingPathComponent(V3StoreBootstrap.storeFileName)),
            invalidV3Bytes
        )
        }
    }

    @MainActor
    func testRecoveryMarkerWriteFailureKeepsValidV3AndRetriesCleanly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try autoreleasepool {
            let v2StoreURL = try makeV2Store(in: root)
            let v3StoreURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
            let v3Directory = v3StoreURL.deletingLastPathComponent()
            let markerURL = v3Directory.appendingPathComponent(".v2-detail-recovery-v1")
            try FileManager.default.removeItem(at: markerURL)

            XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(
                v2StoreURL: v2StoreURL,
                writeRecoveryMarker: { _, _ in
                    throw SimulatedInterruption.requested
                }
            ))

            XCTAssertTrue(FileManager.default.fileExists(atPath: v3StoreURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
            try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
            try SQLiteStoreIntegrityChecker.quickCheck(at: v3StoreURL)
            XCTAssertEqual(try v3GameCount(at: v3StoreURL), 2)

            // The data backfill may already be committed, but without the
            // marker startup must safely replay it and then write the marker.
            let restartedURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
            XCTAssertEqual(restartedURL, v3StoreURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
            XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)
            XCTAssertEqual(try v3GameCount(at: restartedURL), 2)
            try SQLiteStoreIntegrityChecker.quickCheck(at: restartedURL)
        }
    }

    @MainActor
    func testCorruptV2BackupDoesNotQuarantineAlreadyValidV3Store() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try autoreleasepool {
            let v2StoreURL = try makeV2Store(in: root)
            let v3StoreURL = try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL)
            let markerURL = v3StoreURL.deletingLastPathComponent()
                .appendingPathComponent(".v2-detail-recovery-v1")
            try FileManager.default.removeItem(at: markerURL)

            // Simulate a damaged retained backup after V3 has already been
            // promoted and validated. Recovery must surface the backup error
            // without moving the authoritative V3 directory to quarantine.
            try Data("corrupt backup".utf8).write(to: v2StoreURL, options: .atomic)

            XCTAssertThrowsError(try V3StoreBootstrap.prepareStore(v2StoreURL: v2StoreURL))
            XCTAssertTrue(FileManager.default.fileExists(atPath: v3StoreURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
            try SQLiteStoreIntegrityChecker.quickCheck(at: v3StoreURL)
            XCTAssertEqual(try v3GameCount(at: v3StoreURL), 2)

            let quarantines = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { $0.lastPathComponent.hasPrefix("itchPocket-v3.quarantine-") }
            XCTAssertTrue(quarantines.isEmpty)
        }
    }

    @MainActor
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-interruption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func makeV2Store(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent("itchPocket-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("itchPocket-v2.store")

        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-interruption-fixture-\(UUID().uuidString)", schema: schema, url: storeURL)
            var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
            do {
                let context = container!.mainContext
                context.insert(ItchPocketSchemaV2Snapshot.DBGame(id: "game-a", title: "Game A"))
                context.insert(ItchPocketSchemaV2Snapshot.DBGame(id: "game-b", title: "Game B"))
                context.insert(ItchPocketSchemaV2Snapshot.DBGameDetail(
                    gameID: "game-a",
                    descriptionText: "Keep this legacy detail",
                    galleryURLs: ["https://cdn.example/cover.png"],
                    discoveryTagsData: Data("[]".utf8)
                ))
                context.insert(ItchPocketSchemaV2Snapshot.DBLibraryCollection(
                    id: "favorites",
                    title: "Favorites",
                    gameIDs: ["game-b", "game-a"]
                ))
                try context.save()
            }
            container = nil
        }

        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)
        return storeURL
    }

    @MainActor
    private func v2GameCount(at storeURL: URL) throws -> Int {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-interruption-verify-\(UUID().uuidString)", schema: schema, url: storeURL, allowsSave: false)
            var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
            let count: Int
            do {
                let context = container!.mainContext
                count = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>())
            }
            container = nil
            return count
        }
    }

    @MainActor
    private func v3GameCount(at storeURL: URL) throws -> Int {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration("itchPocket-v3-interruption-verify-\(UUID().uuidString)", schema: schema, url: storeURL, allowsSave: false)
            var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
            let count: Int
            do {
                let context = container!.mainContext
                count = try context.fetchCount(FetchDescriptor<DBGame>())
            }
            container = nil
            return count
        }
    }
}
