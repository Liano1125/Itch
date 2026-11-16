import XCTest
@testable import itchPocket

final class V4MigrationManifestBuilderTests: XCTestCase {
    private func makePreflight(
        rowCounts: [String: Int],
        ownershipReviewCounts: [String: Int] = [:],
        integrityIssues: [String] = []
    ) throws -> V3MigrationPreflightReport {
        try V3MigrationPreflightReport(
            sourceSchemaVersion: "3.0.0",
            rowCounts: rowCounts,
            ownershipReviewCounts: ownershipReviewCounts,
            integrityIssues: integrityIssues
        )
    }

    func testBuildAggregatesReportsAndUsesRealAppStateScopeIDs() throws {
        let preflight = try makePreflight(
            rowCounts: [
                "games": 4, "libraryEntries": 2, "collections": 1,
                "collectionItems": 3, "libraryStatusEvents": 2, "appStates": 3
            ],
            ownershipReviewCounts: [
                "libraryEntries": 2, "collections": 1, "collectionItems": 3,
                "libraryStatusEvents": 2, "appStates": 3
            ]
        )
        let library = V4LegacyLibraryMigrationReport(
            libraryEntryCount: 2, collectionCount: 1, collectionItemCount: 3,
            statusEventCount: 2, inventoryDigest: String(repeating: "a", count: 64)
        )
        let appState = V4LegacyAppStateMigrationReport(
            totalRows: 3, deviceScopedRows: 1, appGlobalRows: 1,
            quarantinedRows: 1, inventoryDigest: String(repeating: "b", count: 64)
        )

        let manifest = V4MigrationManifestBuilder.build(
            preflight: preflight, library: library, appState: appState,
            runID: "builder-test", generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationSchemaVersion: "4.0.0"
        )

        XCTAssertEqual(manifest.sourceRowCount, 15)
        XCTAssertEqual(manifest.sourceInventoryDigest, preflight.inventoryDigest)
        XCTAssertEqual(manifest.registryVersion, AppStateScopeRegistry.registryVersion)

        let libraryDomain = try XCTUnwrap(manifest.domains["library"])
        XCTAssertEqual(libraryDomain.sourceRowCount, 8)
        XCTAssertEqual(libraryDomain.destinationRowCount, 8)
        XCTAssertEqual(libraryDomain.scopeCounts, ["account-unassigned": 8])
        XCTAssertEqual(libraryDomain.quarantinedRowCount, 0)
        XCTAssertEqual(libraryDomain.digestKind, .stableIdentitySHA256)

        let appStateDomain = try XCTUnwrap(manifest.domains["appState"])
        XCTAssertEqual(appStateDomain.scopeCounts, [
            AppStateScope.device.scopeID: 1,
            AppStateScope.appGlobal.scopeID: 1,
            AppStateScope.legacyUnclassified.scopeID: 1
        ])
        XCTAssertEqual(appStateDomain.digestKind, .keyOnlySHA256)
        XCTAssertEqual(appStateDomain.payloadVerification.status, .notRun)
        XCTAssertEqual(appStateDomain.payloadVerification.method, .none)
        XCTAssertEqual(appStateDomain.payloadVerification.unverifiedRows, 3)
        XCTAssertTrue(manifest.integrityDiagnostics.contains("migration.domainCoverage.incomplete"))
        XCTAssertFalse(manifest.isPromotionEligible)
    }

    func testCountMismatchAndUnmigratedOwnershipBecomeStableDiagnostics() throws {
        let preflight = try makePreflight(
            rowCounts: [
                "libraryEntries": 2, "collections": 0, "collectionItems": 0,
                "libraryStatusEvents": 0, "appStates": 1
            ],
            ownershipReviewCounts: ["updateWatches": 2],
            integrityIssues: ["libraryEntry.missingGame:private-game-id"]
        )
        let library = V4LegacyLibraryMigrationReport(
            libraryEntryCount: 1, collectionCount: 0, collectionItemCount: 0,
            statusEventCount: 0, inventoryDigest: String(repeating: "c", count: 64)
        )
        let appState = V4LegacyAppStateMigrationReport(
            totalRows: 1, deviceScopedRows: 0, appGlobalRows: 0,
            quarantinedRows: 1, inventoryDigest: String(repeating: "d", count: 64)
        )

        let manifest = V4MigrationManifestBuilder.build(
            preflight: preflight, library: library, appState: appState,
            runID: "diagnostic-test", generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationSchemaVersion: "4.0.0"
        )
        XCTAssertTrue(manifest.integrityDiagnostics.contains("libraryEntry.missingGame"))
        XCTAssertTrue(manifest.integrityDiagnostics.contains("ownership.unhandledDomainsRequireReview"))
        XCTAssertTrue(manifest.integrityDiagnostics.contains("migration.library.sourceCountMismatch"))
        let json = try XCTUnwrap(String(data: manifest.encodedJSON(), encoding: .utf8))
        XCTAssertFalse(json.contains("private-game-id"))
        XCTAssertFalse(manifest.isPromotionEligible)
    }

    func testBuilderIntegratesFieldByFieldVerificationIntoPromotionGate() throws {
        let preflight = try makePreflight(
            rowCounts: [
                "libraryEntries": 1, "collections": 0, "collectionItems": 0,
                "libraryStatusEvents": 0, "appStates": 1
            ]
        )
        let library = V4LegacyLibraryMigrationReport(
            libraryEntryCount: 1, collectionCount: 0, collectionItemCount: 0,
            statusEventCount: 0, inventoryDigest: String(repeating: "e", count: 64)
        )
        let appState = V4LegacyAppStateMigrationReport(
            totalRows: 1, deviceScopedRows: 1, appGlobalRows: 0,
            quarantinedRows: 0, inventoryDigest: String(repeating: "f", count: 64)
        )
        let verification = V4MigrationPayloadVerificationReport(
            library: V4MigrationPayloadVerificationSummary(
                status: .verified, method: .fieldByFieldCanonicalValues,
                verifiedRows: 1, unverifiedRows: 0
            ),
            appState: V4MigrationPayloadVerificationSummary(
                status: .verified, method: .fieldByFieldCanonicalValues,
                verifiedRows: 1, unverifiedRows: 0
            ),
            integrityDiagnostics: []
        )

        let manifest = V4MigrationManifestBuilder.build(
            preflight: preflight, library: library, appState: appState,
            verification: verification,
            runID: "verified-builder-test",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationSchemaVersion: "4.0.0"
        )

        XCTAssertEqual(manifest.domains["library"]?.payloadVerification.status, .verified)
        XCTAssertEqual(manifest.domains["appState"]?.payloadVerification.status, .verified)
        XCTAssertTrue(manifest.integrityDiagnostics.isEmpty)
        XCTAssertTrue(manifest.isPromotionEligible)
    }

    func testBuilderCarriesVerifierDiagnosticsAndBlocksPromotion() throws {
        let preflight = try makePreflight(
            rowCounts: [
                "libraryEntries": 1, "collections": 0, "collectionItems": 0,
                "libraryStatusEvents": 0, "appStates": 1
            ]
        )
        let library = V4LegacyLibraryMigrationReport(
            libraryEntryCount: 1, collectionCount: 0, collectionItemCount: 0,
            statusEventCount: 0, inventoryDigest: String(repeating: "1", count: 64)
        )
        let appState = V4LegacyAppStateMigrationReport(
            totalRows: 1, deviceScopedRows: 0, appGlobalRows: 0,
            quarantinedRows: 1, inventoryDigest: String(repeating: "2", count: 64)
        )
        let verification = V4MigrationPayloadVerificationReport(
            library: V4MigrationPayloadVerificationSummary(
                status: .failed, method: .fieldByFieldCanonicalValues,
                verifiedRows: 0, unverifiedRows: 2
            ),
            appState: V4MigrationPayloadVerificationSummary(
                status: .verified, method: .fieldByFieldCanonicalValues,
                verifiedRows: 1, unverifiedRows: 0
            ),
            integrityDiagnostics: ["migration.library.entry.payloadMismatch"]
        )

        let manifest = V4MigrationManifestBuilder.build(
            preflight: preflight, library: library, appState: appState,
            verification: verification,
            runID: "failed-builder-test",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationSchemaVersion: "4.0.0"
        )

        XCTAssertEqual(manifest.domains["library"]?.payloadVerification.status, .failed)
        XCTAssertEqual(manifest.domains["appState"]?.payloadVerification.status, .verified)
        XCTAssertTrue(manifest.integrityDiagnostics.contains(
            "migration.library.entry.payloadMismatch"
        ))
        XCTAssertFalse(manifest.isPromotionEligible)
    }

}
