import Foundation
import SwiftData
import SwiftUI

/// Narrow persistence capability supplied to repositories. The underlying
/// ModelContext never escapes this wrapper in Release builds.
@MainActor
final class RepositoryContext {
    private let modelContext: ModelContext

    fileprivate init(_ modelContext: ModelContext) { self.modelContext = modelContext }
    var hasChanges: Bool { modelContext.hasChanges }

    func fetch<Model>(_ descriptor: FetchDescriptor<Model>) throws -> [Model] where Model: PersistentModel {
        try modelContext.fetch(descriptor)
    }
    func fetchCount<Model>(_ descriptor: FetchDescriptor<Model>) throws -> Int where Model: PersistentModel {
        try modelContext.fetchCount(descriptor)
    }
    func insert<Model>(_ model: Model) where Model: PersistentModel { modelContext.insert(model) }
    func delete<Model>(_ model: Model) where Model: PersistentModel { modelContext.delete(model) }
}

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

    private let container: ModelContainer
    private var modelContext: ModelContext { container.mainContext }
    var repositoryContext: RepositoryContext { RepositoryContext(modelContext) }

    #if DEBUG
    /// Test-only escape hatch for persistence fixtures. Not present in Release.
    var context: ModelContext { modelContext }
    var simulatedSaveError: (() -> Error?)?
    #endif

    static var hasLegacyStoreForRecovery: Bool {
        let schema = Schema(versionedSchema: ItchPocketSchemaV1.self)
        let configuration = ModelConfiguration(
            LegacyStoreBootstrap.legacyConfigurationName,
            schema: schema
        )
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configuration.url.path) {
            return true
        }
        let v2StoreURL = configuration.url
            .deletingLastPathComponent()
            .appendingPathComponent(LegacyStoreBootstrap.v2DirectoryName, isDirectory: true)
            .appendingPathComponent(LegacyStoreBootstrap.v2StoreFileName)
        return fileManager.fileExists(atPath: v2StoreURL.path)
    }

    init(inMemory: Bool = false, recoverCorruptV2: Bool = false) throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
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
            // A validated V3 store is authoritative. Do not make normal app
            // startup depend on the older V2 backup still being present.
            let v3StoreURL = try Self.prepareDurableStore(
                legacyStoreURL: legacyConfiguration.url,
                recoverCorruptV2: recoverCorruptV2
            )
            let configuration = ModelConfiguration(
                V3StoreBootstrap.directoryName,
                schema: schema,
                url: v3StoreURL
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// Selects the newest valid durable store without ever rebuilding a
    /// missing V2 backup from a stale V1 snapshot when a V3 store exists.
    static func prepareDurableStore(
        legacyStoreURL: URL,
        recoverCorruptV2: Bool = false
    ) throws -> URL {
        let parent = legacyStoreURL.deletingLastPathComponent()
        let v2Directory = parent.appendingPathComponent(
            LegacyStoreBootstrap.v2DirectoryName,
            isDirectory: true
        )
        let v2StoreURL = v2Directory.appendingPathComponent(LegacyStoreBootstrap.v2StoreFileName)
        let v3StoreURL = parent
            .appendingPathComponent(V3StoreBootstrap.directoryName, isDirectory: true)
            .appendingPathComponent(V3StoreBootstrap.storeFileName)

        if FileManager.default.fileExists(atPath: v3StoreURL.path) {
            return try V3StoreBootstrap.prepareStore(
                v2StoreURL: v2StoreURL,
                recoverInvalidExistingV3: recoverCorruptV2
            )
        }

        let preparedV2StoreURL = try LegacyStoreBootstrap.prepareStore(
            legacyStoreURL: legacyStoreURL,
            finalDirectory: v2Directory,
            recoverInvalidExistingV2: recoverCorruptV2
        )
        // Build V3 from a staging copy and retain the authoritative V2 source.
        return try V3StoreBootstrap.prepareStore(
            v2StoreURL: preparedV2StoreURL,
            recoverInvalidExistingV3: recoverCorruptV2
        )
    }

    func attachModelContainer<Content: View>(to content: Content) -> some View {
        content.modelContainer(container)
    }

    func save() throws {
        guard modelContext.hasChanges else { return }
        do {
            #if DEBUG
            if let error = simulatedSaveError?() { throw error }
            #endif
            try modelContext.save()
        } catch {
            // A failed direct repository save must not strand pending mutations
            // in the shared context and block every later transaction.
            modelContext.rollback()
            throw error
        }
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

    /// Runs a synchronous unit of work against a clean shared context.
    /// A failed operation rolls back only because no unrelated pending changes
    /// were present at entry. Successful save:false callers may leave changes
    /// pending for a larger caller-owned batch.
    func performUnitOfWork<Value>(_ operation: () throws -> Value) throws -> Value {
        guard !modelContext.hasChanges else {
            throw TransactionError.pendingChanges
        }

        do {
            return try operation()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Runs a clean-context unit of work and commits it with one save.
    /// Operation failures are rolled back by performUnitOfWork; save failures
    /// are rolled back by save(), keeping rollback ownership in one place.
    func performTransaction<Value>(_ operation: () throws -> Value) throws -> Value {
        let value = try performUnitOfWork(operation)
        try save()
        return value
    }

    /// Clears every persisted app-data model as one atomic unit of work.
    /// Existing pending changes are rejected by performTransaction rather than
    /// being accidentally committed or rolled back with this destructive action.
    func removeAllAppData() throws {
        try performTransaction {
            try AppStateRepository(database: self).removeAll(save: false)
            try modelContext.delete(model: DBLibraryCollectionItem.self)
            try modelContext.delete(model: DBGameDetail.self)
            try modelContext.delete(model: DBLibraryStatusEvent.self)
            try modelContext.delete(model: DBLibraryCollection.self)
            try modelContext.delete(model: DBUpdateWatch.self)
            try modelContext.delete(model: DBDiscoverySnapshot.self)
            try modelContext.delete(model: DBTranslation.self)
            try modelContext.delete(model: DBSparkMetadata.self)
            try modelContext.delete(model: DBCalendarEvent.self)
            try modelContext.delete(model: DBGameUpdate.self)
            try modelContext.delete(model: DBLibraryEntry.self)
            try modelContext.delete(model: DBGame.self)
            try modelContext.delete(model: DBDeveloper.self)
        }
    }
}
