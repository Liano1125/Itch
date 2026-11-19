import Foundation

/// Aggregates existing preflight and converter reports without touching persistence.
enum V4MigrationManifestBuilder {
    static func build(
        preflight: V3MigrationPreflightReport,
        sharedCatalog: V4SharedCatalogMigrationReport? = nil,
        sharedCatalogVerification: V4SharedCatalogVerificationReport? = nil,
        gameUpdates: V4GameUpdateMigrationReport? = nil,
        gameUpdateVerification: V4GameUpdateVerificationReport? = nil,
        updateWatches: V4UpdateWatchMigrationReport? = nil,
        updateWatchVerification: V4UpdateWatchVerificationReport? = nil,
        sparkMetadata: V4SparkMetadataMigrationReport? = nil,
        sparkMetadataVerification: V4SparkMetadataVerificationReport? = nil,
        translations: V4TranslationCacheMigrationReport? = nil,
        translationVerification: V4TranslationCacheVerificationReport? = nil,
        discoveryCacheDisposition: V4DiscoveryCacheDispositionReport? = nil,
        discoveryCacheVerified: Bool = false,
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

        var diagnostics = preflight.integrityIssues
            .filter { !$0.hasPrefix("updateWatch.missingGame:") }
            .map(Self.stableDiagnosticCode)
        diagnostics.append(contentsOf: verification?.integrityDiagnostics ?? [])
        diagnostics.append(contentsOf: sharedCatalogVerification?.diagnostics ?? [])
        diagnostics.append(contentsOf: gameUpdateVerification?.diagnostics ?? [])
        diagnostics.append(contentsOf: updateWatchVerification?.diagnostics ?? [])
        diagnostics.append(contentsOf: sparkMetadataVerification?.diagnostics ?? [])
        diagnostics.append(contentsOf: translationVerification?.diagnostics ?? [])
        if let referenceVerification {
            diagnostics.append(contentsOf: referenceVerification.diagnostics)
        } else {
            diagnostics.append("migration.references.notRun")
        }

        // A source table counts as covered only when its converter and field verifier ran.
        var reportedSourceTables: Set<String> = [
            "libraryEntries", "collections", "collectionItems",
            "libraryStatusEvents", "appStates"
        ]
        let catalogSourceRows = (preflight.rowCounts["developers"] ?? 0)
            + (preflight.rowCounts["games"] ?? 0)
            + (preflight.rowCounts["gameDetails"] ?? 0)
        if let sharedCatalog, let sharedCatalogVerification {
            reportedSourceTables.formUnion(["developers", "games", "gameDetails"])
            if sharedCatalog.totalRows != catalogSourceRows
                || sharedCatalogVerification.unverifiedRows != 0
                || !sharedCatalogVerification.isVerified
                || sharedCatalogVerification.verifiedRows < sharedCatalog.totalRows {
                diagnostics.append("migration.sharedCatalog.verificationFailed")
            }
        } else if catalogSourceRows > 0 {
            diagnostics.append("migration.sharedCatalog.notRun")
        }
        let gameUpdateSourceRows = preflight.rowCounts["gameUpdates"] ?? 0
        if let gameUpdates, let gameUpdateVerification {
            reportedSourceTables.insert("gameUpdates")
            if gameUpdates.rowCount != gameUpdateSourceRows
                || gameUpdateVerification.unverifiedRows != 0
                || !gameUpdateVerification.isVerified
                || gameUpdateVerification.verifiedRows < gameUpdates.rowCount {
                diagnostics.append("migration.gameUpdates.verificationFailed")
            }
        } else if gameUpdateSourceRows > 0 {
            diagnostics.append("migration.gameUpdates.notRun")
        }
        let updateWatchSourceRows = preflight.rowCounts["updateWatches"] ?? 0
        if let updateWatches, let updateWatchVerification {
            reportedSourceTables.insert("updateWatches")
            if updateWatches.rowCount != updateWatchSourceRows
                || updateWatchVerification.unverifiedRows != 0
                || !updateWatchVerification.isVerified
                || updateWatchVerification.verifiedRows < updateWatches.rowCount
                || updateWatchVerification.quarantinedRowCount != updateWatches.quarantinedRowCount {
                diagnostics.append("migration.updateWatches.verificationFailed")
            }
        } else if updateWatchSourceRows > 0 {
            diagnostics.append("migration.updateWatches.notRun")
        }
        let sparkSourceRows = preflight.rowCounts["sparkMetadata"] ?? 0
        if let updateWatches, let updateWatchVerification {
            domains["updateWatches"] = V4MigrationDomainManifest(
                sourceRowCount: updateWatchSourceRows,
                destinationRowCount: updateWatches.rowCount,
                scopeCounts: ["legacy-unassigned": updateWatches.rowCount],
                quarantinedRowCount: updateWatches.quarantinedRowCount,
                inventoryDigest: updateWatches.inventoryDigest,
                digestKind: .stableIdentitySHA256,
                payloadVerification: V4MigrationPayloadVerificationSummary(
                    status: updateWatchVerification.isVerified
                        && updateWatchVerification.verifiedRows >= updateWatches.rowCount ? .verified : .failed,
                    method: .fieldByFieldCanonicalValues,
                    verifiedRows: updateWatchVerification.verifiedRows,
                    unverifiedRows: updateWatchVerification.unverifiedRows
                ),
                integrityDiagnostics: updateWatchVerification.diagnostics
            )
        }

        if let sparkMetadata, let sparkMetadataVerification {
            reportedSourceTables.insert("sparkMetadata")
            if sparkMetadata.rowCount != sparkSourceRows
                || sparkMetadataVerification.unverifiedRows != 0
                || !sparkMetadataVerification.isVerified
                || sparkMetadataVerification.verifiedRows < sparkMetadata.rowCount {
                diagnostics.append("migration.sparkMetadata.verificationFailed")
            }
        } else if sparkSourceRows > 0 {
            diagnostics.append("migration.sparkMetadata.notRun")
        }
        let translationSourceRows = preflight.rowCounts["translations"] ?? 0
        if let translations, let translationVerification {
            reportedSourceTables.insert("translations")
            if translations.rowCount != translationSourceRows
                || translationVerification.unverifiedRows != 0
                || !translationVerification.isVerified
                || translationVerification.verifiedRows < translations.rowCount {
                diagnostics.append("migration.translations.verificationFailed")
            }
        } else if translationSourceRows > 0 {
            diagnostics.append("migration.translations.notRun")
        }
        let discoverySourceRows = preflight.rowCounts["discoverySnapshots"] ?? 0
        if let discoveryCacheDisposition {
            reportedSourceTables.insert("discoverySnapshots")
            if discoveryCacheDisposition.discardedRowCount != discoverySourceRows || !discoveryCacheVerified {
                diagnostics.append("migration.discoveryCache.discardVerificationFailed")
            }
        } else if discoverySourceRows > 0 {
            diagnostics.append("migration.discoveryCache.dispositionNotRun")
        }
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

        // Calendar events remain uncovered; update watches are now copied only
        // into the unassigned legacy quarantine, never claimed by an account.
        let unhandledOwnershipRows = preflight.ownershipReviewCounts["calendarEvents"] ?? 0
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

        var domains: [String: V4MigrationDomainManifest] = [
            "library": libraryDomain,
            "appState": appStateDomain
        ]
        if let sharedCatalog, let sharedCatalogVerification {
            domains["sharedCatalog"] = V4MigrationDomainManifest(
                sourceRowCount: catalogSourceRows,
                destinationRowCount: sharedCatalog.totalRows,
                scopeCounts: ["shared": sharedCatalog.totalRows],
                quarantinedRowCount: 0,
                inventoryDigest: sharedCatalog.inventoryDigest,
                digestKind: .stableIdentitySHA256,
                payloadVerification: V4MigrationPayloadVerificationSummary(
                    status: sharedCatalogVerification.isVerified
                        && sharedCatalogVerification.verifiedRows >= sharedCatalog.totalRows ? .verified : .failed,
                    method: .fieldByFieldCanonicalValues,
                    verifiedRows: sharedCatalogVerification.verifiedRows,
                    unverifiedRows: sharedCatalogVerification.unverifiedRows
                ),
                integrityDiagnostics: sharedCatalogVerification.diagnostics
            )
        }

        if let gameUpdates, let gameUpdateVerification {
            domains["gameUpdates"] = V4MigrationDomainManifest(
                sourceRowCount: gameUpdateSourceRows,
                destinationRowCount: gameUpdates.rowCount,
                scopeCounts: ["shared": gameUpdates.rowCount],
                quarantinedRowCount: 0,
                inventoryDigest: gameUpdates.inventoryDigest,
                digestKind: .stableIdentitySHA256,
                payloadVerification: V4MigrationPayloadVerificationSummary(
                    status: gameUpdateVerification.isVerified
                        && gameUpdateVerification.verifiedRows >= gameUpdates.rowCount ? .verified : .failed,
                    method: .fieldByFieldCanonicalValues,
                    verifiedRows: gameUpdateVerification.verifiedRows,
                    unverifiedRows: gameUpdateVerification.unverifiedRows
                ),
                integrityDiagnostics: gameUpdateVerification.diagnostics
            )
        }

        if let sparkMetadata, let sparkMetadataVerification {
            domains["sparkMetadata"] = V4MigrationDomainManifest(
                sourceRowCount: sparkSourceRows,
                destinationRowCount: sparkMetadata.rowCount,
                scopeCounts: ["device": sparkMetadata.rowCount],
                quarantinedRowCount: 0,
                inventoryDigest: sparkMetadata.inventoryDigest,
                digestKind: .stableIdentitySHA256,
                payloadVerification: V4MigrationPayloadVerificationSummary(
                    status: sparkMetadataVerification.isVerified
                        && sparkMetadataVerification.verifiedRows >= sparkMetadata.rowCount ? .verified : .failed,
                    method: .fieldByFieldCanonicalValues,
                    verifiedRows: sparkMetadataVerification.verifiedRows,
                    unverifiedRows: sparkMetadataVerification.unverifiedRows
                ),
                integrityDiagnostics: sparkMetadataVerification.diagnostics
            )
        }

        if let translations, let translationVerification {
            domains["translations"] = V4MigrationDomainManifest(
                sourceRowCount: translationSourceRows,
                destinationRowCount: translations.rowCount,
                scopeCounts: ["shared-public-content": translations.rowCount],
                quarantinedRowCount: 0,
                inventoryDigest: translations.inventoryDigest,
                digestKind: .stableIdentitySHA256,
                payloadVerification: V4MigrationPayloadVerificationSummary(
                    status: translationVerification.isVerified
                        && translationVerification.verifiedRows >= translations.rowCount ? .verified : .failed,
                    method: .fieldByFieldCanonicalValues,
                    verifiedRows: translationVerification.verifiedRows,
                    unverifiedRows: translationVerification.unverifiedRows
                ),
                integrityDiagnostics: translationVerification.diagnostics
            )
        }

        if let discoveryCacheDisposition {
            domains["discoverySnapshots"] = V4MigrationDomainManifest(
                disposition: .discardedRebuildableCache,
                sourceRowCount: discoverySourceRows,
                destinationRowCount: 0,
                scopeCounts: [:],
                quarantinedRowCount: 0,
                inventoryDigest: discoveryCacheDisposition.inventoryDigest,
                digestKind: .stableIdentitySHA256,
                payloadVerification: V4MigrationPayloadVerificationSummary(
                    status: discoveryCacheVerified ? .verified : .failed,
                    method: .identityAndCounts,
                    verifiedRows: discoveryCacheDisposition.discardedRowCount,
                    unverifiedRows: discoveryCacheVerified ? 0 : 1
                ),
                integrityDiagnostics: discoveryCacheVerified ? [] : ["migration.discoveryCache.discardVerificationFailed"]
            )
        }

        return V4MigrationManifest(
            runID: runID,
            generatedAt: generatedAt,
            sourceSchemaVersion: preflight.sourceSchemaVersion,
            destinationSchemaVersion: destinationSchemaVersion,
            registryVersion: AppStateScopeRegistry.registryVersion,
            sourceRowCount: totalSourceRows,
            sourceInventoryDigest: preflight.inventoryDigest,
            domains: domains,
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
