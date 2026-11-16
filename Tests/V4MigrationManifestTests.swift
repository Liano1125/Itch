import XCTest
@testable import itchPocket

final class V4MigrationManifestTests: XCTestCase {
    private func verifiedDomain(
        sourceRows: Int,
        destinationRows: Int,
        scopes: [String: Int],
        quarantinedRows: Int = 0
    ) -> V4MigrationDomainManifest {
        V4MigrationDomainManifest(
            sourceRowCount: sourceRows,
            destinationRowCount: destinationRows,
            scopeCounts: scopes,
            quarantinedRowCount: quarantinedRows,
            inventoryDigest: String(repeating: "a", count: 64),
            digestKind: .stableIdentitySHA256,
            payloadVerification: V4MigrationPayloadVerificationSummary(
                status: .verified,
                method: .fieldByFieldCanonicalValues,
                verifiedRows: destinationRows,
                unverifiedRows: 0
            ),
            integrityDiagnostics: []
        )
    }

    private func makeManifest(
        domain: V4MigrationDomainManifest,
        diagnostics: [String] = []
    ) -> V4MigrationManifest {
        V4MigrationManifest(
            runID: "fixture-run-001",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceSchemaVersion: "3.0.0",
            destinationSchemaVersion: "4.0.0",
            registryVersion: AppStateScopeRegistry.registryVersion,
            sourceRowCount: 3,
            sourceInventoryDigest: String(repeating: "b", count: 64),
            domains: ["appState": domain],
            integrityDiagnostics: diagnostics
        )
    }

    func testVerifiedManifestRoundTripsWithStableCanonicalJSON() throws {
        let manifest = makeManifest(domain: verifiedDomain(
            sourceRows: 2,
            destinationRows: 2,
            scopes: ["legacy-unclassified": 1, "app-global": 1],
            quarantinedRows: 1
        ))

        XCTAssertTrue(manifest.isPromotionEligible)

        let first = try manifest.encodedJSON()
        let decoded = try JSONDecoder.iso8601.decode(V4MigrationManifest.self, from: first)
        let second = try decoded.encodedJSON()

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(first, second)
    }

    func testManifestCannotPassPromotionGateBeforePayloadVerification() {
        let unverified = V4MigrationDomainManifest(
            sourceRowCount: 1,
            destinationRowCount: 1,
            scopeCounts: ["legacy-unclassified": 1],
            quarantinedRowCount: 1,
            inventoryDigest: String(repeating: "c", count: 64),
            digestKind: .keyOnlySHA256,
            payloadVerification: V4MigrationPayloadVerificationSummary(
                status: .notRun,
                method: .none,
                verifiedRows: 0,
                unverifiedRows: 1
            ),
            integrityDiagnostics: []
        )

        XCTAssertFalse(makeManifest(domain: unverified).isPromotionEligible)
    }

    func testManifestRejectsInconsistentScopeCountsAndIntegrityDiagnostics() {
        let inconsistent = verifiedDomain(
            sourceRows: 2,
            destinationRows: 2,
            scopes: ["legacy-unclassified": 1]
        )
        XCTAssertFalse(makeManifest(domain: inconsistent).isPromotionEligible)

        let diagnosed = makeManifest(
            domain: verifiedDomain(
                sourceRows: 1,
                destinationRows: 1,
                scopes: ["app-global": 1]
            ),
            diagnostics: ["reference.orphaned"]
        )
        XCTAssertFalse(diagnosed.isPromotionEligible)
    }


    func testManifestRejectsMalformedOrUntypedDigests() {
        let valid = verifiedDomain(
            sourceRows: 1,
            destinationRows: 1,
            scopes: ["app-global": 1]
        )
        let malformed = V4MigrationDomainManifest(
            sourceRowCount: valid.sourceRowCount,
            destinationRowCount: valid.destinationRowCount,
            scopeCounts: valid.scopeCounts,
            quarantinedRowCount: valid.quarantinedRowCount,
            inventoryDigest: "not-a-digest",
            digestKind: .stableIdentitySHA256,
            payloadVerification: valid.payloadVerification,
            integrityDiagnostics: []
        )
        XCTAssertFalse(makeManifest(domain: malformed).isPromotionEligible)

        let untyped = V4MigrationDomainManifest(
            sourceRowCount: valid.sourceRowCount,
            destinationRowCount: valid.destinationRowCount,
            scopeCounts: valid.scopeCounts,
            quarantinedRowCount: valid.quarantinedRowCount,
            inventoryDigest: valid.inventoryDigest,
            digestKind: nil,
            payloadVerification: valid.payloadVerification,
            integrityDiagnostics: []
        )
        XCTAssertFalse(makeManifest(domain: untyped).isPromotionEligible)
    }


    func testManifestSerializationDoesNotContainPrivatePayloads() throws {
        let manifest = makeManifest(domain: verifiedDomain(
            sourceRows: 1,
            destinationRows: 1,
            scopes: ["legacy-unassigned": 1],
            quarantinedRows: 1
        ))
        let json = try XCTUnwrap(String(data: manifest.encodedJSON(), encoding: .utf8))

        XCTAssertFalse(json.contains("private note"))
        XCTAssertFalse(json.contains("oauth"))
        XCTAssertFalse(json.contains("access_token"))
        XCTAssertFalse(json.contains("personal reminder"))
        XCTAssertTrue(json.contains("legacy-unassigned"))
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
