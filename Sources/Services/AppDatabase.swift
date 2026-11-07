import Foundation
import SwiftData

/// Owns the app's one durable database. Feature stores and views must use
/// repositories backed by this container instead of creating their own files.
@MainActor
final class AppDatabase {
    static let shared = AppDatabase()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    private init() {
        let schema = Schema([
            DBDeveloper.self,
            DBGame.self,
            DBLibraryEntry.self,
            DBGameUpdate.self,
            DBCalendarEvent.self,
            DBSparkMetadata.self,
            DBTranslation.self,
            DBDiscoverySnapshot.self,
            DBUpdateWatch.self,
            DBLibraryCollection.self,
            DBLibraryStatusEvent.self,
            DBAppState.self
        ])
        let configuration = ModelConfiguration(
            "itchPocket",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A failed database open must be surfaced rather than silently
            // falling back to a second, divergent persistence mechanism.
            fatalError("Unable to open itchPocket database: \(error.localizedDescription)")
        }
    }

    func save() throws {
        guard context.hasChanges else { return }
        try context.save()
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
        if item.modelContext == nil { context.insert(item) }
        if !name.isEmpty { item.name = name }
        if let profileURL { item.profileURL = profileURL }
        if let patreonURL { item.patreonURL = patreonURL }
        if let discordURL { item.discordURL = discordURL }
        item.updatedAt = .now
        try save()
    }

    func setDeveloperAvatar(id: String, url: String?, source: String?) throws {
        guard let item = try developer(id: id) else { return }
        guard item.avatarURL != url || item.avatarSource != source else { return }
        item.avatarURL = url
        item.avatarSource = source
        item.avatarResolvedAt = .now
        item.updatedAt = .now
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
        description: String? = nil,
        engine: String? = nil,
        developerID: String? = nil
    ) throws {
        let item = try game(id: id) ?? DBGame(id: id, title: title)
        if item.modelContext == nil { context.insert(item) }
        item.title = title
        if let gameURL { item.gameURL = gameURL }
        if let coverURL { item.coverURL = coverURL }
        if let description { item.descriptionText = description }
        if let engine { item.engine = engine }
        if let developerID { item.developerID = developerID }
        item.updatedAt = .now
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

    func setGameDescription(_ description: String, for gameID: String) throws {
        guard let item = try game(id: gameID) else { return }
        guard item.descriptionText != description else { return }
        item.descriptionText = description
        item.updatedAt = .now
        try save()
    }

    func galleryURLs(for gameID: String) throws -> [String] {
        try game(id: gameID)?.galleryURLs ?? []
    }

    func setGalleryURLs(_ urls: [String], for gameID: String) throws {
        guard let item = try game(id: gameID) else { return }
        guard item.galleryURLs != urls else { return }
        item.galleryURLs = urls
        item.updatedAt = .now
        try save()
    }

    func removeAllAppData() throws {
        try context.delete(model: DBAppState.self)
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
