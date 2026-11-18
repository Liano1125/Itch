import Foundation

/// Aggregates existing preflight and converter reports without touching persistence.
enum V4MigrationManifestBuilder {
    static func build(
        preflight: V3MigrationPreflightReport,
        library: V4LegacyLibraryMigrationReport,
        appState: V4LegacyAppStateMigrationReport,
        verification: V4MigrationPayloadVerificationReport? = nil,
        referenceVerification: V4StoreReferenceVerificationReport? = nil,
        runID: String,
        generatedAt: Date,
        destinationSchemaVersion: String
    ) -> V4MigrationManifest {
        let librarySourceRows =
            (preflight.rowCounts["libraryEntries"] ?? 0) +
            (preflight.rowCounts["collections"] ?? 0) +
            (preflight.rowCounts["collectionItems"] ?? 0) +
            (preflight.rowCounts["libraryStatusEvents"] ?? 0)
        let appStateSourceRows = preflight.rowCounts["appStates"] ?? 0
        let totalSourceRows = preflight.rowCounts.values.reduce(0, +)

        var diagnostics = preflight.integrityIssues.map(Self.stableDiagnosticCode)
        diagnostics.append(contentsOf: verification?.integrityDiagnostics ?? [])
        if let referenceVerification {
            diagnostics.append(contentsOf: referenceVerification.diagnostics)
        } else {
            diagnostics.append("migration.references.notRun")
        }

        // Only library and AppState converter reports are currently supplied.
        // Do not let those two verified domains imply whole-store coverage.
        let reportedSourceTables: Set<String> = [
            "libraryEntries", "collections", "collectionItems",
            "libraryStatusEvents", "appStates"
        ]
        let uncoveredSourceRows = preflight.rowCounts
            .filter { !reportedSourceTables.contains($0.key) }
            .values
            .reduce(0, +)
        if uncoveredSourceRows > 0 {
            diagnostics.append("migration.domainCoverage.incomplete")
        }
        if librarySourceRows != library.totalRows {
            diagnostics.append("migration.library.sourceCountMismatch")
        }
        if appStateSourceRows != appState.totalRows {
            diagnostics.append("migration.appState.sourceCountMismatch")
        }

        // Update watches and calendar events are not yet handled by these converters.
        let unhandledOwnershipRows =
            (preflight.ownershipReviewCounts["updateWatches"] ?? 0) +
            (preflight.ownershipReviewCounts["calendarEvents"] ?? 0)
        if unhandledOwnershipRows > 0 {
            diagnostics.append("ownership.unhandledDomainsRequireReview")
        }

        let libraryDomain = V4MigrationDomainManifest(
            sourceRowCount: librarySourceRows,
            destinationRowCount: library.totalRows,
            // Nil account ownership is an explicit unassigned destination
            // state, not a quarantine. Keep the two concepts separate.
            scopeCounts: ["account-unassigned": library.totalRows],
            quarantinedRowCount: 0,
            inventoryDigest: library.inventoryDigest,
            digestKind: .stableIdentitySHA256,
            payloadVerification: verification?.library ?? notRunVerification(rowCount: library.totalRows),
            integrityDiagnostics: librarySourceRows == library.totalRows
                ? [] : ["migration.library.sourceCountMismatch"]
        )

        let appStateScopeCounts = [
            AppStateScope.device.scopeID: appState.deviceScopedRows,
            AppStateScope.appGlobal.scopeID: appState.appGlobalRows,
            AppStateScope.legacyUnclassified.scopeID: appState.quarantinedRows
        ].filter { $0.value > 0 }

        let appStateDomain = V4MigrationDomainManifest(
            sourceRowCount: appStateSourceRows,
            destinationRowCount: appState.totalRows,
            scopeCounts: appStateScopeCounts,
            quarantinedRowCount: appState.quarantinedRows,
            inventoryDigest: appState.inventoryDigest,
            digestKind: .keyOnlySHA256,
            payloadVerification: verification?.appState ?? notRunVerification(rowCount: appState.totalRows),
            integrityDiagnostics: appStateSourceRows == appState.totalRows
                ? [] : ["migration.appState.sourceCountMismatch"]
        )

        return V4MigrationManifest(
            runID: runID,
            generatedAt: generatedAt,
            sourceSchemaVersion: preflight.sourceSchemaVersion,
            destinationSchemaVersion: destinationSchemaVersion,
            registryVersion: AppStateScopeRegistry.registryVersion,
            sourceRowCount: totalSourceRows,
            sourceInventoryDigest: preflight.inventoryDigest,
            domains: ["library": libraryDomain, "appState": appStateDomain],
            integrityDiagnostics: diagnostics,
            referenceVerification: referenceVerification
        )
    }

    private static func notRunVerification(rowCount: Int) -> V4MigrationPayloadVerificationSummary {
        V4MigrationPayloadVerificationSummary(
            status: .notRun,
            method: .none,
            verifiedRows: 0,
            unverifiedRows: rowCount
        )
    }

    /// Strip row identifiers from preflight issue strings before serialization.
    private static func stableDiagnosticCode(_ issue: String) -> String {
        String(issue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "preflight.unknown")
    }
}
