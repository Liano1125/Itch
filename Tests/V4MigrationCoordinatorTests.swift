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
        source.context.insert(DBGame(id: "game-a", title: "Game A"))
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
        XCTAssertFalse(attempt.manifest.isPromotionEligible)
        XCTAssertEqual(attempt.outcome, .blockedByManifest)
        XCTAssertTrue(attempt.manifest.integrityDiagnostics.contains(
            "migration.domainCoverage.incomplete"
        ))
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
