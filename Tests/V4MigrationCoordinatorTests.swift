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

    @MainActor
    func testEmptyStoreCompletesCoveredMigrationPipelineWithoutProductionPromotion() throws {
        let source = try AppDatabase(inMemory: true)
        let destination = try makeV4Container()
        let attempt = try V4MigrationCoordinator.run(
            source: source.context,
            destination: destination.mainContext,
            runID: "empty-store-test",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(attempt.verification.isVerified)
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

        XCTAssertThrowsError(try V4MigrationCoordinator.run(
            source: source.context, destination: destination.mainContext,
            runID: "invalid-source-test"
        )) { error in
            XCTAssertEqual(error as? V4MigrationCoordinator.CoordinatorError, .sourcePreflightFailed)
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
        let attempt = try V4MigrationCoordinator.run(
            source: source.context, destination: destination.mainContext,
            runID: "uncovered-domain-test"
        )
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
        XCTAssertThrowsError(try V4MigrationCoordinator.run(
            source: source.context, destination: destination.mainContext,
            runID: "dirty-context-test"
        )) { error in
            XCTAssertEqual(error as? V4MigrationCoordinator.CoordinatorError, .sourceHasPendingChanges)
        }
    }
}
