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

    init(inMemory: Bool = false) throws {
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
                finalDirectory: finalDirectory
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

    static func canonicalDeveloperID(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else { return rawURL.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.string ?? rawURL.lowercased()
    }

    func developer(id: String) throws -> DBDeveloper? {
        let descriptor = FetchDescriptor<DBDeveloper>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func upsertDeveloper(
        id: String,
        name: String,
        profileURL: String? = nil,
        patreonURL: String? = nil,
        discordURL: String? = nil
    ) throws {
        let item = try developer(id: id) ?? DBDeveloper(id: id, name: name)
        var changed = item.modelContext == nil
        if item.modelContext == nil { context.insert(item) }
        if !name.isEmpty && item.name != name { item.name = name; changed = true }
        if let profileURL, item.profileURL != profileURL { item.profileURL = profileURL; changed = true }
        if let patreonURL, item.patreonURL != patreonURL { item.patreonURL = patreonURL; changed = true }
        if let discordURL, item.discordURL != discordURL { item.discordURL = discordURL; changed = true }
        if changed { item.updatedAt = .now }
        try save()
    }

    func setDeveloperAvatar(id: String, url: String?, source: String?) throws {
        guard let item = try developer(id: id) else { return }
        let changed = item.avatarURL != url || item.avatarSource != source
        item.avatarURL = url
        item.avatarSource = source
        item.avatarResolvedAt = .now
        if changed { item.updatedAt = .now }
        try save()
    }

    func invalidateDeveloperAvatarCaches() throws {
        let developers = try context.fetch(FetchDescriptor<DBDeveloper>())
        for developer in developers {
            developer.avatarURL = nil
            developer.avatarSource = nil
            developer.avatarResolvedAt = nil
        }
        try save()
    }

    func game(id: String) throws -> DBGame? {
        let descriptor = FetchDescriptor<DBGame>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func upsertGame(
        id: String,
        title: String,
        gameURL: String? = nil,
        coverURL: String? = nil,
        engine: String? = nil,
        developerID: String? = nil
    ) throws {
        let item = try game(id: id) ?? DBGame(id: id, title: title)
        var changed = item.modelContext == nil
        if item.modelContext == nil { context.insert(item) }
        if item.title != title { item.title = title; changed = true }
        if let gameURL, item.gameURL != gameURL { item.gameURL = gameURL; changed = true }
        if let coverURL, item.coverURL != coverURL { item.coverURL = coverURL; changed = true }
        if let engine, item.engine != engine { item.engine = engine; changed = true }
        if let developerID, item.developerID != developerID { item.developerID = developerID; changed = true }
        if changed { item.updatedAt = .now }
        try save()
    }

    func state(for key: String) throws -> DBAppState? {
        let descriptor = FetchDescriptor<DBAppState>(
            predicate: #Predicate { $0.key == key }
        )
        return try context.fetch(descriptor).first
    }

    func setState(_ value: String?, for key: String) throws {
        let item = try state(for: key) ?? DBAppState(key: key)
        if item.modelContext == nil { context.insert(item) }
        item.stringValue = value
        item.updatedAt = .now
        try save()
    }

    func setState(_ value: Date?, for key: String) throws {
        let item = try state(for: key) ?? DBAppState(key: key)
        if item.modelContext == nil { context.insert(item) }
        item.dateValue = value
        item.updatedAt = .now
        try save()
    }

    func setState(_ value: Data?, for key: String) throws {
        let item = try state(for: key) ?? DBAppState(key: key)
        if item.modelContext == nil { context.insert(item) }
        item.dataValue = value
        item.updatedAt = .now
        try save()
    }

    func removeAllAppData() throws {
        try context.delete(model: DBAppState.self)
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
