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
    func delete<Model>(model: Model.Type) throws where Model: PersistentModel {
        try modelContext.delete(model: model)
    }
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
    #endif

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

    func attachModelContainer<Content: View>(to content: Content) -> some View {
        content.modelContainer(container)
    }

    func save() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
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
    func performTransaction<Value>(_ operation: () throws -> Value) throws -> Value {
        let value = try performUnitOfWork(operation)
        do {
            try save()
            return value
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func removeAllAppData() throws {
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
        try save()
    }
}
