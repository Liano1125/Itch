import Foundation
import SwiftData

/// Owns the app's one durable database. Feature stores and views must use
/// repositories backed by this container instead of creating their own files.
@MainActor
final class AppDatabase {
    /// Installed by the app entry point only after durable storage is verified.
    private static var sharedInstance: AppDatabase?

    static var isInstalled: Bool { sharedInstance != nil }

    static var shared: AppDatabase {
        guard let sharedInstance else {
            preconditionFailure("AppDatabase.shared accessed before successful database startup.")
        }
        return sharedInstance
    }

    static func installShared(_ database: AppDatabase) {
        sharedInstance = database
    }

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    static var hasLegacyStoreForRecovery: Bool {
        let schema = Schema(versionedSchema: ItchPocketSchemaV1.self)
        let configuration = ModelConfiguration(
            LegacyStoreBootstrap.legacyConfigurationName,
            schema: schema
        )
        return FileManager.default.fileExists(atPath: configuration.url.path)
    }

    init(inMemory: Bool = false, recoverCorruptV2: Bool = false) throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        if inMemory {
            let configuration = ModelConfiguration(
                "itchPocket",
                schema: schema,
                isStoredInMemoryOnly: true
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        } else {
            // Resolve the exact pre-versioning store location through the
            // same configuration name used by released builds.
            let legacySchema = Schema(versionedSchema: ItchPocketSchemaV1.self)
            let legacyConfiguration = ModelConfiguration(
                LegacyStoreBootstrap.legacyConfigurationName,
                schema: legacySchema
            )
            let finalDirectory = legacyConfiguration.url
                .deletingLastPathComponent()
                .appendingPathComponent(LegacyStoreBootstrap.v2DirectoryName, isDirectory: true)
            let v2StoreURL = try LegacyStoreBootstrap.prepareStore(
                legacyStoreURL: legacyConfiguration.url,
                finalDirectory: finalDirectory,
                recoverInvalidExistingV2: recoverCorruptV2
            )
            let configuration = ModelConfiguration(
                LegacyStoreBootstrap.v2ConfigurationName,
                schema: schema,
                url: v2StoreURL
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    func save() throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    enum TransactionError: LocalizedError {
        case pendingChanges

        var errorDescription: String? {
            switch self {
            case .pendingChanges:
                return "A transaction cannot start while the shared context contains pending changes."
            }
        }
    }

    /// Runs one synchronous unit of work against a clean shared context.
    /// On failure, rollback is safe because no unrelated pending changes were
    /// present at entry. Callers that intentionally batch with other stores
    /// must continue using save:false and own the outer transaction boundary.
    func performTransaction<Value>(_ operation: () throws -> Value) throws -> Value {
        guard !context.hasChanges else {
            throw TransactionError.pendingChanges
        }

        do {
            let value = try operation()
            try save()
            return value
        } catch {
            context.rollback()
            throw error
        }
    }

    func removeAllAppData() throws {
        try AppStateRepository(database: self).removeAll(save: false)
        try context.delete(model: DBLibraryCollectionItem.self)
        try context.delete(model: DBGameDetail.self)
        try context.delete(model: DBLibraryStatusEvent.self)
        try context.delete(model: DBLibraryCollection.self)
        try context.delete(model: DBUpdateWatch.self)
        try context.delete(model: DBDiscoverySnapshot.self)
        try context.delete(model: DBTranslation.self)
        try context.delete(model: DBSparkMetadata.self)
        try context.delete(model: DBCalendarEvent.self)
        try context.delete(model: DBGameUpdate.self)
        try context.delete(model: DBLibraryEntry.self)
        try context.delete(model: DBGame.self)
        try context.delete(model: DBDeveloper.self)
        try save()
    }
}
