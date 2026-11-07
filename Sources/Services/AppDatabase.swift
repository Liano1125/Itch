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
        var changed = item.modelContext == nil
        if item.modelContext == nil { context.insert(item) }
        if item.title != title { item.title = title; changed = true }
        if let gameURL, item.gameURL != gameURL { item.gameURL = gameURL; changed = true }
        if let coverURL, item.coverURL != coverURL { item.coverURL = coverURL; changed = true }
        if let description, item.descriptionText != description { item.descriptionText = description; changed = true }
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

    func upsertGameDetail(
        id: String,
        title: String,
        gameURL: String?,
        coverURL: String?,
        description: String?,
        galleryURLs: [String],
        discoveryTags: [LibraryDiscoveryTag],
        engine: String?,
        developerID: String?,
        developerName: String?,
        developerProfileURL: String?,
        patreonURL: String?,
        discordURL: String?
    ) throws {
        let context = self.context
        if let developerID {
            let descriptor = FetchDescriptor<DBDeveloper>(predicate: #Predicate { $0.id == developerID })
            let developer = try context.fetch(descriptor).first
                ?? DBDeveloper(id: developerID, name: developerName ?? "itch.io 开发者")
            if developer.modelContext == nil { context.insert(developer) }
            var changed = false
            if let developerName, developer.name != developerName { developer.name = developerName; changed = true }
            if let developerProfileURL, developer.profileURL != developerProfileURL {
                developer.profileURL = developerProfileURL
                changed = true
            }
            if let patreonURL, developer.patreonURL != patreonURL { developer.patreonURL = patreonURL; changed = true }
            if let discordURL, developer.discordURL != discordURL { developer.discordURL = discordURL; changed = true }
            if changed { developer.updatedAt = .now }
        }

        let descriptor = FetchDescriptor<DBGame>(predicate: #Predicate { $0.id == id })
        let game = try context.fetch(descriptor).first ?? DBGame(id: id, title: title)
        if game.modelContext == nil { context.insert(game) }
        var changed = false
        if game.title != title { game.title = title; changed = true }
        if let gameURL, game.gameURL != gameURL { game.gameURL = gameURL; changed = true }
        if let coverURL, game.coverURL != coverURL { game.coverURL = coverURL; changed = true }
        if let description, game.descriptionText != description { game.descriptionText = description; changed = true }
        if !galleryURLs.isEmpty && game.galleryURLs != galleryURLs { game.galleryURLs = galleryURLs; changed = true }
        if !discoveryTags.isEmpty {
            let data = try JSONEncoder().encode(discoveryTags)
            if game.discoveryTagsData != data { game.discoveryTagsData = data; changed = true }
        }
        if let engine, game.engine != engine { game.engine = engine; changed = true }
        if let developerID, game.developerID != developerID { game.developerID = developerID; changed = true }
        if changed { game.updatedAt = .now }
        try save()
    }

    func setGameDescription(_ description: String, for gameID: String) throws {
        guard let item = try game(id: gameID) else { return }
        guard item.descriptionText != description else { return }
        item.descriptionText = description
        item.updatedAt = .now
        try save()
    }

    func setDiscoveryTags(_ tags: [LibraryDiscoveryTag], for gameID: String) throws {
        guard let item = try game(id: gameID) else { return }
        let data = try JSONEncoder().encode(tags)
        guard item.discoveryTagsData != data else { return }
        item.discoveryTagsData = data
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
