import XCTest
import SwiftData
@testable import itchPocket

final class V4MigrationCoordinatorTests: XCTestCase {
    @MainActor
    private func makeV4Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-coordinator-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func withOwnerLock<T>(
        _ operation: (URL, V4MigrationOwnerLock.Lease) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4MigrationCoordinatorLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("migration-owner.lock")
        let lease = try V4MigrationOwnerLock.acquire(at: lockURL)
        defer { lease.release() }
        return try operation(lockURL, lease)
    }

    @MainActor
    func testEmptyStoreCompletesCoveredMigrationPipelineWithoutProductionPromotion() throws {
        let source = try AppDatabase(inMemory: true)
        let destination = try makeV4Container()
        let attempt = try withOwnerLock { lockURL, lease in
            try V4MigrationCoordinator.run(
                source: source.context,
                destination: destination.mainContext,
                runID: "empty-store-test",
                ownerLockURL: lockURL,
                ownerLease: lease,
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        XCTAssertTrue(attempt.verification.isVerified)
        XCTAssertTrue(attempt.referenceVerification.isValid)
        XCTAssertTrue(attempt.manifest.referenceVerification?.isValid == true)
        XCTAssertTrue(attempt.manifest.isPromotionEligible)
        XCTAssertEqual(attempt.outcome, .manifestEligibleForIndependentSafetyGates)
        XCTAssertEqual(attempt.sharedCatalog.totalRows, 0)
        XCTAssertTrue(attempt.sharedCatalogVerification.isVerified)
        XCTAssertEqual(attempt.library.totalRows, 0)
        XCTAssertEqual(attempt.appState.totalRows, 0)
    }

    @MainActor
    func testStructuralPreflightFailureAbortsBeforeWritingDestination() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBLibraryEntry(gameID: "missing-game", status: "playing"))
        try source.save()
        let destination = try makeV4Container()

        try withOwnerLock { lockURL, lease in
            XCTAssertThrowsError(try V4MigrationCoordinator.run(
                source: source.context, destination: destination.mainContext,
                runID: "invalid-source-test",
                ownerLockURL: lockURL, ownerLease: lease
            )) { error in
                XCTAssertEqual(error as? V4MigrationCoordinator.CoordinatorError, .sourcePreflightFailed)
            }
        }
        XCTAssertEqual(try destination.mainContext.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        ), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(
            FetchDescriptor<DBScopedAppState>()
        ), 0)
    }

    @MainActor
    func testUnimplementedSourceDomainsRemainManifestBlocked() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBDeveloper(
            id: "dev-a", name: "Developer A", profileURL: "https://example.com/dev",
            avatarURL: "https://example.com/avatar.png", updatedAt: Date(timeIntervalSince1970: 100)
        ))
        source.context.insert(DBGame(
            id: "game-a", title: "Game A", gameURL: "https://example.com/game",
            coverURL: "https://example.com/cover.png", engine: "Ren'Py",
            developerID: "dev-a", updatedAt: Date(timeIntervalSince1970: 200)
        ))
        source.context.insert(DBGameDetail(
            gameID: "game-a", descriptionText: "A game description",
            galleryURLs: ["https://example.com/shot.png"],
            discoveryTagsData: Data([1, 2, 3]),
            fetchedAt: Date(timeIntervalSince1970: 300), isComplete: true
        ))
        // Keep one non-empty, not-yet-migrated domain in the fixture. Empty
        // uncovered tables do not block migration; populated ones must.
        source.context.insert(DBCalendarEvent(
            id: "calendar-a", gameID: "game-a", title: "Legacy event",
            date: Date(timeIntervalSince1970: 500), kind: "release"
        ))
        try source.save()
        let destination = try makeV4Container()
        let attempt = try withOwnerLock { lockURL, lease in
            try V4MigrationCoordinator.run(
                source: source.context, destination: destination.mainContext,
                runID: "uncovered-domain-test",
                ownerLockURL: lockURL, ownerLease: lease
            )
        }
        XCTAssertTrue(attempt.verification.isVerified)
        XCTAssertEqual(attempt.sharedCatalog.developerCount, 1)
        XCTAssertEqual(attempt.sharedCatalog.gameCount, 1)
        XCTAssertEqual(attempt.sharedCatalog.gameDetailCount, 1)
        let copiedDeveloper = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBDeveloper>()).first)
        XCTAssertEqual(copiedDeveloper.name, "Developer A")
        let copiedGame = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBGame>()).first)
        XCTAssertEqual(copiedGame.developerID, "dev-a")
        let copiedDetail = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBGameDetail>()).first)
        XCTAssertEqual(copiedDetail.descriptionText, "A game description")
        XCTAssertEqual(copiedDetail.galleryURLs, ["https://example.com/shot.png"])
        XCTAssertEqual(copiedDetail.discoveryTagsData, Data([1, 2, 3]))
        XCTAssertTrue(attempt.sharedCatalogVerification.isVerified)
        XCTAssertEqual(attempt.manifest.domains["sharedCatalog"]?.payloadVerification.status, .verified)
        XCTAssertFalse(attempt.manifest.isPromotionEligible)
        XCTAssertEqual(attempt.outcome, .blockedByManifest)
        XCTAssertTrue(attempt.manifest.integrityDiagnostics.contains(
            "migration.domainCoverage.incomplete"
        ))
    }

    

    @MainActor
    func testSparkMetadataMigratesAsDeviceScopedDataAndVerifiesAllFields() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBGame(id: "spark-game", title: "Spark game"))
        source.context.insert(DBSparkMetadata(
            gameID: "spark-game", runtimeSeconds: 987.5,
            lastSaveAt: Date(timeIntervalSince1970: 100),
            renpyVersion: "8.2.1", saveCount: 7,
            scannedAt: Date(timeIntervalSince1970: 200)
        ))
        try source.save()
        let destination = try makeV4Container()
        let report = try V4SparkMetadataConverter.convert(
            source: source.context, destination: destination.mainContext
        )
        XCTAssertEqual(report.rowCount, 1)
        let copied = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBSparkMetadata>()).first)
        XCTAssertEqual(copied.gameID, "spark-game")
        XCTAssertEqual(copied.runtimeSeconds, 987.5)
        XCTAssertEqual(copied.lastSaveAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(copied.renpyVersion, "8.2.1")
        XCTAssertEqual(copied.saveCount, 7)
        XCTAssertEqual(copied.scannedAt, Date(timeIntervalSince1970: 200))
        let verification = try V4SparkMetadataVerifier.verify(
            source: source.context, destination: destination.mainContext
        )
        XCTAssertTrue(verification.isVerified)
        XCTAssertEqual(verification.verifiedRows, 1)
    }

    @MainActor
    func testSparkMetadataVerifierDetectsMutatedDestinationField() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBGame(id: "spark-game", title: "Spark game"))
        source.context.insert(DBSparkMetadata(
            gameID: "spark-game", runtimeSeconds: 10, scannedAt: Date(timeIntervalSince1970: 100)
        ))
        try source.save()
        let destination = try makeV4Container()
        _ = try V4SparkMetadataConverter.convert(source: source.context, destination: destination.mainContext)
        let copied = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBSparkMetadata>()).first)
        copied.runtimeSeconds = 999
        try destination.mainContext.save()
        let report = try V4SparkMetadataVerifier.verify(source: source.context, destination: destination.mainContext)
        XCTAssertFalse(report.isVerified)
        XCTAssertEqual(report.unverifiedRows, 2)
        XCTAssertTrue(report.diagnostics.contains("migration.sparkMetadata.rowMismatch"))
    }


    @MainActor
    func testCoordinatorRecordsSparkMigrationUnderDeviceScope() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBGame(id: "spark-game", title: "Spark game"))
        source.context.insert(DBSparkMetadata(
            gameID: "spark-game", runtimeSeconds: 321,
            scannedAt: Date(timeIntervalSince1970: 321)
        ))
        try source.save()
        let destination = try makeV4Container()
        let attempt = try withOwnerLock { lockURL, lease in
            try V4MigrationCoordinator.run(
                source: source.context, destination: destination.mainContext,
                runID: "spark-device-scope-test",
                ownerLockURL: lockURL, ownerLease: lease
            )
        }
        XCTAssertTrue(attempt.sparkMetadataVerification.isVerified)
        XCTAssertEqual(attempt.sparkMetadata.rowCount, 1)
        XCTAssertEqual(attempt.manifest.domains["sparkMetadata"]?.scopeCounts["device"], 1)
        XCTAssertEqual(attempt.manifest.domains["sparkMetadata"]?.payloadVerification.status, .verified)
        XCTAssertTrue(attempt.manifest.isPromotionEligible)
    }

    @MainActor
    func testGameUpdatesMigrateAndVerifyEveryStoredField() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBGame(id: "update-game", title: "Update game"))
        source.context.insert(DBGameUpdate(
            id: "update-1", gameID: "update-game", title: "Version 2",
            summary: "A detailed update", detectedAt: Date(timeIntervalSince1970: 100),
            publishedAt: Date(timeIntervalSince1970: 200),
            url: "https://example.com/update", sourceID: "feed-1", isHistorical: true
        ))
        try source.save()
        let destination = try makeV4Container()
        let report = try V4GameUpdateConverter.convert(
            source: source.context, destination: destination.mainContext
        )
        XCTAssertEqual(report.rowCount, 1)
        let copied = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBGameUpdate>()).first)
        XCTAssertEqual(copied.title, "Version 2")
        XCTAssertEqual(copied.summary, "A detailed update")
        XCTAssertEqual(copied.detectedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(copied.publishedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(copied.url, "https://example.com/update")
        XCTAssertEqual(copied.sourceID, "feed-1")
        XCTAssertTrue(copied.isHistorical)
        let verification = try V4GameUpdateVerifier.verify(
            source: source.context, destination: destination.mainContext
        )
        XCTAssertTrue(verification.isVerified)
        XCTAssertEqual(verification.verifiedRows, 1)
    }

    @MainActor
    func testGameUpdateVerifierDetectsMutatedDestinationField() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBGame(id: "update-game", title: "Update game"))
        source.context.insert(DBGameUpdate(
            id: "update-1", gameID: "update-game", summary: "Original summary"
        ))
        try source.save()
        let destination = try makeV4Container()
        _ = try V4GameUpdateConverter.convert(source: source.context, destination: destination.mainContext)
        let copied = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBGameUpdate>()).first)
        copied.summary = "Mutated summary"
        try destination.mainContext.save()
        let report = try V4GameUpdateVerifier.verify(source: source.context, destination: destination.mainContext)
        XCTAssertFalse(report.isVerified)
        XCTAssertEqual(report.unverifiedRows, 2)
        XCTAssertTrue(report.diagnostics.contains("migration.gameUpdates.rowMismatch"))
    }

    @MainActor
    func testSharedCatalogVerifierDetectsMutatedDestinationPayload() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBGame(id: "catalog-game", title: "Original title"))
        try source.save()
        let destination = try makeV4Container()

        let migration = try V4SharedCatalogConverter.convert(
            source: source.context, destination: destination.mainContext
        )
        XCTAssertEqual(migration.gameCount, 1)
        let copied = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBGame>()).first)
        copied.title = "Mutated title"
        try destination.mainContext.save()

        let report = try V4SharedCatalogVerifier.verify(
            source: source.context, destination: destination.mainContext
        )
        XCTAssertFalse(report.isVerified)
        XCTAssertEqual(report.unverifiedRows, 2)
        XCTAssertTrue(report.diagnostics.contains("migration.sharedCatalog.gameMismatch"))
    }

    @MainActor
    func testRejectsDirtyContextsBeforeStarting() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBAppState(key: "pending"))
        let destination = try makeV4Container()
        try withOwnerLock { lockURL, lease in
            XCTAssertThrowsError(try V4MigrationCoordinator.run(
                source: source.context, destination: destination.mainContext,
                runID: "dirty-context-test",
                ownerLockURL: lockURL, ownerLease: lease
            )) { error in
                XCTAssertEqual(error as? V4MigrationCoordinator.CoordinatorError, .sourceHasPendingChanges)
            }
        }
    }

    @MainActor
    func testRejectsLeaseForDifferentLockPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4MigrationWrongLease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let heldURL = root.appendingPathComponent("held.lock")
        let expectedURL = root.appendingPathComponent("expected.lock")
        let lease = try V4MigrationOwnerLock.acquire(at: heldURL)
        defer { lease.release() }

        let source = try AppDatabase(inMemory: true)
        let destination = try makeV4Container()
        XCTAssertThrowsError(try V4MigrationCoordinator.run(
            source: source.context, destination: destination.mainContext,
            runID: "wrong-lock-path",
            ownerLockURL: expectedURL, ownerLease: lease
        )) { error in
            XCTAssertEqual(error as? V4MigrationOwnerLock.LockError, .leaseNotActive)
        }
        XCTAssertEqual(try destination.mainContext.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        ), 0)
    }
}
