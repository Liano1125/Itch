import Foundation
import SwiftData

/// Result of one isolated V3 → V4 staging attempt.
/// A manifest-eligible result is still not permission to replace production.
struct V4MigrationAttempt: Equatable {
    enum Outcome: Equatable {
        case manifestEligibleForIndependentSafetyGates
        case blockedByManifest
    }

    let runID: String
    let preflight: V3MigrationPreflightReport
    let sharedCatalog: V4SharedCatalogMigrationReport
    let sharedCatalogVerification: V4SharedCatalogVerificationReport
    let gameUpdates: V4GameUpdateMigrationReport
    let gameUpdateVerification: V4GameUpdateVerificationReport
    let updateWatches: V4UpdateWatchMigrationReport
    let updateWatchVerification: V4UpdateWatchVerificationReport
    let calendarEvents: V4CalendarEventMigrationReport
    let calendarEventVerification: V4CalendarEventVerificationReport
    let sparkMetadata: V4SparkMetadataMigrationReport
    let sparkMetadataVerification: V4SparkMetadataVerificationReport
    let translations: V4TranslationCacheMigrationReport
    let translationVerification: V4TranslationCacheVerificationReport
    let discoveryCacheDisposition: V4DiscoveryCacheDispositionReport
    let discoveryCacheVerified: Bool
    let library: V4LegacyLibraryMigrationReport
    let appState: V4LegacyAppStateMigrationReport
    let verification: V4MigrationPayloadVerificationReport
    let referenceVerification: V4StoreReferenceVerificationReport
    let manifest: V4MigrationManifest
    let outcome: Outcome
}

/// Coordinates the currently supported migration slices inside a disposable
/// V4 staging store. It never opens the production V4 location, persists a
/// checkpoint, switches app startup, or promotes a store.
///
/// IMPORTANT: Supply a newly created, isolated V4 staging ModelContext for
/// every attempt. The converters save their own domains independently. If a
/// later step throws, the caller MUST discard the entire staging store rather
/// than retrying against the partially populated context.
@MainActor
enum V4MigrationCoordinator {
    enum CoordinatorError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case sourcePreflightFailed
        case sourceChangedDuringMigration

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges:
                return "The V3 source context must be clean before migration."
            case .destinationHasPendingChanges:
                return "The isolated V4 staging context must be clean before migration."
            case .sourcePreflightFailed:
                return "The V3 source failed structural preflight; no migration was started."
            case .sourceChangedDuringMigration:
                return "The V3 source inventory changed during migration; discard the staging store."
            }
        }
    }

    /// Runs the shared catalog, Library, and AppState converters. Other non-empty
    /// V3 domains remain explicitly uncovered in Manifest and block promotion.
    static func run(
        source: ModelContext,
        destination: ModelContext,
        runID: String,
        ownerLockURL: URL,
        ownerLease: V4MigrationOwnerLock.Lease,
        generatedAt: Date = Date(),
        destinationSchemaVersion: String = "4.0.0"
    ) throws -> V4MigrationAttempt {
        // A conversion must never run outside the same owner lease used for
        // snapshot creation and journal transitions.
        try ownerLease.validateOwnership(at: ownerLockURL)

        guard !source.hasChanges else {
            throw CoordinatorError.sourceHasPendingChanges
        }
        guard !destination.hasChanges else {
            throw CoordinatorError.destinationHasPendingChanges
        }

        let initialPreflight = try V3MigrationPreflight.inspect(context: source)
        guard initialPreflight.isStructurallyValid else {
            throw CoordinatorError.sourcePreflightFailed
        }

        // Each converter commits its own domain into this disposable staging
        // store. No production database is touched by this coordinator.
        let sharedCatalog = try V4SharedCatalogConverter.convert(
            source: source, destination: destination
        )
        let gameUpdates = try V4GameUpdateConverter.convert(source: source, destination: destination)
        let updateWatches = try V4UpdateWatchConverter.convert(source: source, destination: destination)
        let calendarEvents = try V4CalendarEventConverter.convert(source: source, destination: destination)
        let sparkMetadata = try V4SparkMetadataConverter.convert(source: source, destination: destination)
        let translations = try V4TranslationCacheConverter.convert(source: source, destination: destination)
        let discoveryCacheDisposition = try V4DiscoveryCacheDisposition.discard(source: source, destination: destination)
        let library = try V4LegacyLibraryConverter.convert(
            source: source, destination: destination
        )
        let appState = try V4LegacyAppStateConverter.convert(
            source: source, destination: destination
        )

        let sharedCatalogVerification = try V4SharedCatalogVerifier.verify(
            source: source, destination: destination
        )
        let gameUpdateVerification = try V4GameUpdateVerifier.verify(source: source, destination: destination)
        let updateWatchVerification = try V4UpdateWatchVerifier.verify(source: source, destination: destination)
        let calendarEventVerification = try V4CalendarEventVerifier.verify(source: source, destination: destination)
        let sparkMetadataVerification = try V4SparkMetadataVerifier.verify(source: source, destination: destination)
        let translationVerification = try V4TranslationCacheVerifier.verify(source: source, destination: destination)
        let discoveryCacheVerified = try V4DiscoveryCacheDisposition.verify(
            source: source, destination: destination, report: discoveryCacheDisposition
        )
        let verification = try V4MigrationPayloadVerifier.verify(
            source: source, destination: destination
        )
        // Validate ownership and cross-record references in the clean staging
        // store before allowing the manifest to report independent-gate eligibility.
        let referenceVerification = try V4StoreReferenceVerifier.verify(context: destination)

        // Detect concurrent source mutations across the conversion window.
        // A mismatch invalidates this staging attempt; it is never promoted.
        let finalPreflight = try V3MigrationPreflight.inspect(context: source)
        guard finalPreflight.inventoryDigest == initialPreflight.inventoryDigest else {
            throw CoordinatorError.sourceChangedDuringMigration
        }

        let manifest = V4MigrationManifestBuilder.build(
            preflight: finalPreflight,
            sharedCatalog: sharedCatalog,
            sharedCatalogVerification: sharedCatalogVerification,
            gameUpdates: gameUpdates,
            gameUpdateVerification: gameUpdateVerification,
            updateWatches: updateWatches,
            updateWatchVerification: updateWatchVerification,
            calendarEvents: calendarEvents,
            calendarEventVerification: calendarEventVerification,
            sparkMetadata: sparkMetadata,
            sparkMetadataVerification: sparkMetadataVerification,
            translations: translations,
            translationVerification: translationVerification,
            discoveryCacheDisposition: discoveryCacheDisposition,
            discoveryCacheVerified: discoveryCacheVerified,
            library: library,
            appState: appState,
            verification: verification,
            referenceVerification: referenceVerification,
            runID: runID,
            generatedAt: generatedAt,
            destinationSchemaVersion: destinationSchemaVersion
        )

        return V4MigrationAttempt(
            runID: runID,
            preflight: finalPreflight,
            sharedCatalog: sharedCatalog,
            sharedCatalogVerification: sharedCatalogVerification,
            gameUpdates: gameUpdates,
            gameUpdateVerification: gameUpdateVerification,
            updateWatches: updateWatches,
            updateWatchVerification: updateWatchVerification,
            sparkMetadata: sparkMetadata,
            sparkMetadataVerification: sparkMetadataVerification,
            translations: translations,
            translationVerification: translationVerification,
            discoveryCacheDisposition: discoveryCacheDisposition,
            discoveryCacheVerified: discoveryCacheVerified,
            library: library,
            appState: appState,
            verification: verification,
            referenceVerification: referenceVerification,
            manifest: manifest,
            outcome: manifest.isPromotionEligible
                ? .manifestEligibleForIndependentSafetyGates
                : .blockedByManifest
        )
    }
}
