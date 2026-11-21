import Foundation
import SwiftData

/// Creates a clean V4 database without reading or importing any V1/V2/V3 data.
///
/// The legacy V3 store is deliberately outside this API. A fresh V4 store is
/// built in a unique sibling directory, closed, checked read-only, and only
/// then promoted by a same-volume directory rename. Existing V4 data is never
/// deleted; an invalid V4 directory is quarantined before a replacement is
/// created.
@MainActor
enum V4FreshStoreBootstrap {
    enum BootstrapError: LocalizedError, Equatable {
        case incompleteStore(URL)
        case nonEmptyFreshStore

        var errorDescription: String? {
            switch self {
            case .incompleteStore(let url):
                return "The V4 database directory is incomplete: \(url.lastPathComponent)."
            case .nonEmptyFreshStore:
                return "A newly created V4 database unexpectedly contains personal data."
            }
        }
    }

    static let directoryName = "itchPocket-v4"
    static let storeFileName = "itchPocket-v4.store"
    private static let stagingPrefix = "itchPocket-v4.staging-"
    private static let quarantinePrefix = "itchPocket-v4.quarantine-"
    private static let lockFileName = "itchPocket-v4.bootstrap.lock"

    /// Returns a validated V4 store URL.
    ///
    /// This operation never opens the V3 store and never migrates legacy rows.
    /// Callers must keep using the current production database until the
    /// account-aware repository graph and app startup switch are complete.
    static func prepareStore(
        in applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )

        let lockURL = applicationSupportDirectory.appendingPathComponent(
            lockFileName,
            isDirectory: false
        )
        let lease = try V4MigrationOwnerLock.acquire(at: lockURL)
        defer { lease.release() }
        try lease.validateOwnership(at: lockURL)

        let finalDirectory = applicationSupportDirectory.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        let finalStoreURL = finalDirectory.appendingPathComponent(
            storeFileName,
            isDirectory: false
        )

        if fileManager.fileExists(atPath: finalDirectory.path) {
            do {
                guard fileManager.fileExists(atPath: finalStoreURL.path) else {
                    throw BootstrapError.incompleteStore(finalStoreURL)
                }
                try validateExistingStore(at: finalStoreURL)
                return finalStoreURL
            } catch {
                // Keep every byte for diagnosis or manual recovery. Never
                // silently erase a previously initialized V4 database.
                let quarantine = applicationSupportDirectory.appendingPathComponent(
                    quarantinePrefix + UUID().uuidString,
                    isDirectory: true
                )
                try fileManager.moveItem(at: finalDirectory, to: quarantine)
            }
        }

        let stagingDirectory = applicationSupportDirectory.appendingPathComponent(
            stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        let stagingStoreURL = stagingDirectory.appendingPathComponent(
            storeFileName,
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            try createAndCloseEmptyV4Store(at: stagingStoreURL)
            try SQLiteStoreIntegrityChecker.fullCheck(at: stagingStoreURL)
            try lease.validateOwnership(at: lockURL)

            // Both directories are siblings on the same volume. The final
            // path is absent while the exclusive bootstrap lease is held.
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            return finalStoreURL
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func createAndCloseEmptyV4Store(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-fresh-bootstrap",
            schema: schema,
            url: storeURL
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )

        // The initial V4 store must not contain an account or account-owned
        // data. Shared catalog/cache tables also start empty by construction.
        let context = container.mainContext
        let accountCount = try context.fetchCount(FetchDescriptor<DBAccount>())
        let libraryCount = try context.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        )
        let collectionCount = try context.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>()
        )
        let membershipCount = try context.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>()
        )
        let statusCount = try context.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>()
        )
        let appStateCount = try context.fetchCount(
            FetchDescriptor<DBScopedAppState>()
        )
        let calendarCount = try context.fetchCount(
            FetchDescriptor<DBAccountCalendarEvent>()
        )
        let calendarOverlayCount = try context.fetchCount(
            FetchDescriptor<DBAccountCalendarOverlay>()
        )
        let updateWatchCount = try context.fetchCount(
            FetchDescriptor<DBAccountUpdateWatch>()
        )

        guard accountCount == 0,
              libraryCount == 0,
              collectionCount == 0,
              membershipCount == 0,
              statusCount == 0,
              appStateCount == 0,
              calendarCount == 0,
              calendarOverlayCount == 0,
              updateWatchCount == 0 else {
            throw BootstrapError.nonEmptyFreshStore
        }
        // The local container goes out of scope before SQLite integrity checks
        // and before the staging directory is promoted.
        withExtendedLifetime(container) {}
    }

    private static func validateExistingStore(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-existing-validation",
            schema: schema,
            url: storeURL,
            allowsSave: false
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        // Force a lightweight schema read before closing the read-only handle.
        _ = try container.mainContext.fetchCount(FetchDescriptor<DBAccount>())
        withExtendedLifetime(container) {}
        try SQLiteStoreIntegrityChecker.fullCheck(at: storeURL)
    }
}
