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
        defer { try? FileManager.default.removeItem(at: root) }
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

    @MainActor
    func testInterruptionAfterStagingValidationKeepsV2AndRetryCompletesMigration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
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

    @MainActor
    func testInterruptionImmediatelyAfterPromotionReusesValidatedV3OnRestart() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
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

    @MainActor
    func testExplicitRecoveryQuarantinesInvalidV3AndIgnoresStaleStagingAndQuarantine() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
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
        XCTAssertEqual(try v2GameCount(at: v2StoreURL), 2)
        XCTAssertEqual(try v3GameCount(at: recoveredURL), 2)
        try SQLiteStoreIntegrityChecker.quickCheck(at: v2StoreURL)
        try SQLiteStoreIntegrityChecker.quickCheck(at: recoveredURL)

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

    @MainActor
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v3-interruption-\\(UUID().uuidString)", isDirectory: true)
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
            let configuration = ModelConfiguration("itchPocket-v2-interruption-fixture", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
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

        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)
        return storeURL
    }

    @MainActor
    private func v2GameCount(at storeURL: URL) throws -> Int {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration("itchPocket-v2-interruption-verify", schema: schema, url: storeURL, allowsSave: false)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return try container.mainContext.fetchCount(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>())
        }
    }

    @MainActor
    private func v3GameCount(at storeURL: URL) throws -> Int {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration("itchPocket-v3-interruption-verify", schema: schema, url: storeURL, allowsSave: false)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return try container.mainContext.fetchCount(FetchDescriptor<DBGame>())
        }
    }
}
