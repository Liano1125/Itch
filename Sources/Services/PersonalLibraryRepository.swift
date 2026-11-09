import Foundation
import SwiftData

struct PersonalLibrarySnapshot {
    let records: [LibraryRecord]
    let statusEvents: [String: [LibraryStatusEvent]]
    let collections: [PersonalGameCollection]
}

/// The single SwiftData boundary for the personal library, its history,
/// collections, and Spark play metadata.
@MainActor
final class PersonalLibraryRepository {
    static let shared = PersonalLibraryRepository(database: .shared)

    private let database: AppDatabase
    private let gameDetailRepository: GameDetailRepository

    init(database: AppDatabase, gameDetailRepository: GameDetailRepository? = nil) {
        self.database = database
        self.gameDetailRepository = gameDetailRepository ?? GameDetailRepository(database: database)
    }

    func snapshot() throws -> PersonalLibrarySnapshot {
        let context = database.context
        let games = try context.fetch(FetchDescriptor<DBGame>())
        let entries = try context.fetch(FetchDescriptor<DBLibraryEntry>())
        let developers = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBDeveloper>()).map { ($0.id, $0) })
        let updates = try context.fetch(FetchDescriptor<DBGameUpdate>())
        let metadata = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBSparkMetadata>()).map { ($0.gameID, $0) })
        let gameByID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
        let updatesByGame = Dictionary(grouping: updates, by: \.gameID)

        let records = entries.compactMap { entry -> LibraryRecord? in
            guard let game = gameByID[entry.gameID] else { return nil }
            let developer = game.developerID.flatMap { developers[$0] }
            let spark = metadata[game.id]
            let gameUpdates = (updatesByGame[game.id] ?? []).map {
                GameLibraryUpdate(
                    id: $0.id,
                    title: $0.title,
                    summary: $0.summary,
                    detectedAt: $0.detectedAt,
                    publishedAt: $0.publishedAt,
                    url: $0.url,
                    sourceID: $0.sourceID,
                    isHistorical: $0.isHistorical
                )
            }.sorted { ($0.publishedAt ?? $0.detectedAt) > ($1.publishedAt ?? $1.detectedAt) }
            return LibraryRecord(
                id: game.id,
                title: game.title,
                gameURL: game.gameURL,
                coverURL: game.coverURL,
                developer: developer?.name,
                developerProfileURL: developer?.profileURL,
                patreonAvatarURL: developer?.avatarSource == "patreon" ? developer?.avatarURL : nil,
                developerAvatarURL: developer?.avatarSource != "patreon" ? developer?.avatarURL : nil,
                status: LibraryStatus(rawValue: entry.status) ?? .playing,
                isFavorite: entry.isFavorite,
                notes: entry.notes,
                addedAt: entry.addedAt,
                updatedAt: entry.updatedAt,
                gameUpdates: gameUpdates,
                discoveryTags: gameDetailRepository.discoveryTags(for: game),
                engine: game.engine,
                patreonURL: developer?.patreonURL,
                discordURL: developer?.discordURL,
                sparkPlaytimeSeconds: spark?.runtimeSeconds,
                sparkLastSaveAt: spark?.lastSaveAt,
                sparkRenpyVersion: spark?.renpyVersion,
                sparkSaveCount: spark?.saveCount
            )
        }.sorted { $0.addedAt > $1.addedAt }

        let statusRows = try context.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        let statusEvents = Dictionary(grouping: statusRows, by: \.gameID).mapValues { rows in
            rows.map {
                LibraryStatusEvent(
                    id: $0.id,
                    fromStatus: $0.fromStatus.flatMap(LibraryStatus.init(rawValue:)),
                    toStatus: LibraryStatus(rawValue: $0.toStatus) ?? .playing,
                    changedAt: $0.changedAt
                )
            }
        }
        let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>()).map {
            PersonalGameCollection(id: $0.id, title: $0.title, gameIDs: $0.gameIDs, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        return PersonalLibrarySnapshot(records: records, statusEvents: statusEvents, collections: collections)
    }

    func save() throws {
        try database.save()
    }

    func saveSparkMetadata(records: [LibraryRecord], changedGameIDs: Set<String>) throws {
        guard !changedGameIDs.isEmpty else { return }
        let context = database.context
        for record in records where changedGameIDs.contains(record.id) {
            guard let runtime = record.sparkPlaytimeSeconds else { continue }
            let gameID = record.id
            let descriptor = FetchDescriptor<DBSparkMetadata>(
                predicate: #Predicate { $0.gameID == gameID }
            )
            let item = try context.fetch(descriptor).first
                ?? DBSparkMetadata(gameID: record.id, runtimeSeconds: runtime)
            if item.modelContext == nil { context.insert(item) }
            item.runtimeSeconds = runtime
            item.lastSaveAt = record.sparkLastSaveAt
            item.renpyVersion = record.sparkRenpyVersion
            item.saveCount = record.sparkSaveCount
            item.scannedAt = .now
        }
        try database.save()
    }

    func remove(
        gameID: String,
        statusEvents: [String: [LibraryStatusEvent]],
        collections: [PersonalGameCollection]
    ) throws {
        let context = database.context
        let targetGameID = gameID
        if let entry = try context.fetch(FetchDescriptor<DBLibraryEntry>(
            predicate: #Predicate { $0.gameID == targetGameID }
        )).first {
            context.delete(entry)
        }
        if let metadata = try context.fetch(FetchDescriptor<DBSparkMetadata>(
            predicate: #Predicate { $0.gameID == targetGameID }
        )).first {
            context.delete(metadata)
        }
        try saveStatusEvents(statusEvents, save: false)
        try saveCollections(collections, save: false)
        try database.save()
    }

    func saveRecord(
        _ record: LibraryRecord,
        save shouldSave: Bool = true,
        updatesAreCompleteSnapshot: Bool = false
    ) {
        let context = database.context
        do {
            let developerID: String?
            if let profileURL = record.developerProfileURL, !profileURL.isEmpty {
                developerID = AppDatabase.canonicalDeveloperID(profileURL)
            } else if let name = record.developer, !name.isEmpty {
                developerID = "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } else {
                developerID = nil
            }

            if let developerID, let name = record.developer {
                let descriptor = FetchDescriptor<DBDeveloper>(predicate: #Predicate { $0.id == developerID })
                let developer = try context.fetch(descriptor).first ?? DBDeveloper(id: developerID, name: name)
                if developer.modelContext == nil { context.insert(developer) }
                var changed = false
                if developer.name != name { developer.name = name; changed = true }
                if let profileURL = record.developerProfileURL, developer.profileURL != profileURL {
                    developer.profileURL = profileURL
                    changed = true
                }
                if let patreonURL = record.patreonURL, developer.patreonURL != patreonURL {
                    developer.patreonURL = patreonURL
                    changed = true
                }
                if let discordURL = record.discordURL, developer.discordURL != discordURL {
                    developer.discordURL = discordURL
                    changed = true
                }
                if let avatar = record.patreonAvatarURL,
                   developer.avatarURL != avatar || developer.avatarSource != "patreon" {
                    developer.avatarURL = avatar
                    developer.avatarSource = "patreon"
                    changed = true
                } else if let avatar = record.developerAvatarURL, developer.avatarURL == nil {
                    developer.avatarURL = avatar
                    developer.avatarSource = "itch"
                    changed = true
                }
                if changed { developer.updatedAt = .now }
            }

            let gameID = record.id
            let gameDescriptor = FetchDescriptor<DBGame>(predicate: #Predicate { $0.id == gameID })
            let game = try context.fetch(gameDescriptor).first ?? DBGame(id: gameID, title: record.title)
            if game.modelContext == nil { context.insert(game) }
            var gameChanged = false
            if game.title != record.title { game.title = record.title; gameChanged = true }
            if let gameURL = record.gameURL, game.gameURL != gameURL { game.gameURL = gameURL; gameChanged = true }
            if let coverURL = record.coverURL, game.coverURL != coverURL { game.coverURL = coverURL; gameChanged = true }
            if let engine = record.engine, game.engine != engine { game.engine = engine; gameChanged = true }
            if let developerID, game.developerID != developerID { game.developerID = developerID; gameChanged = true }
            if let tags = record.discoveryTags {
                try gameDetailRepository.applyPartialUpdate(
                    GameDetailPartialUpdate(discoveryTags: tags),
                    for: gameID,
                    save: false
                )
            }
            if gameChanged { game.updatedAt = .now }

            let entryDescriptor = FetchDescriptor<DBLibraryEntry>(predicate: #Predicate { $0.gameID == gameID })
            let entry = try context.fetch(entryDescriptor).first ?? DBLibraryEntry(gameID: gameID, status: record.status.rawValue)
            if entry.modelContext == nil { context.insert(entry) }
            if entry.status != record.status.rawValue { entry.status = record.status.rawValue }
            if entry.isFavorite != record.isFavorite { entry.isFavorite = record.isFavorite }
            if entry.notes != record.notes { entry.notes = record.notes }
            if entry.addedAt != record.addedAt { entry.addedAt = record.addedAt }
            if entry.updatedAt != record.updatedAt { entry.updatedAt = record.updatedAt }

            // A snapshot is partial by default. Deletion is allowed only when
            // the caller explicitly confirms that it contains the full history.
            let oldUpdates = try context.fetch(FetchDescriptor<DBGameUpdate>(predicate: #Predicate { $0.gameID == gameID }))
            let updates = record.gameUpdates ?? []
            let currentIDs = Set(updates.map { $0.id })
            for old in oldUpdates where LibraryUpdatePersistencePolicy.shouldDeleteStoredUpdate(
                storedID: old.id,
                incomingIDs: currentIDs,
                isCompleteSnapshot: updatesAreCompleteSnapshot
            ) {
                context.delete(old)
            }
            for update in updates {
                let updateID = update.id
                let updateDescriptor = FetchDescriptor<DBGameUpdate>(predicate: #Predicate { $0.id == updateID })
                let item = try context.fetch(updateDescriptor).first ?? DBGameUpdate(id: updateID, gameID: gameID, summary: update.summary)
                if item.modelContext == nil { context.insert(item) }
                if item.gameID != gameID { item.gameID = gameID }
                if item.title != update.title { item.title = update.title }
                if item.summary != update.summary { item.summary = update.summary }
                if item.detectedAt != update.detectedAt { item.detectedAt = update.detectedAt }
                if item.publishedAt != update.publishedAt { item.publishedAt = update.publishedAt }
                if item.url != update.url { item.url = update.url }
                if item.sourceID != update.sourceID { item.sourceID = update.sourceID }
                let isHistorical = update.isHistorical ?? false
                if item.isHistorical != isHistorical { item.isHistorical = isHistorical }
            }
            if shouldSave { try database.save() }
        } catch {
            print("itchPocket library database write failed: \(error)")
        }
    }


    func saveStatusEvents(save shouldSave: Bool = true) {
        let context = database.context
        do {
            let desired = statusEvents.flatMap { gameID, events in events.map { (gameID, $0) } }
            let existing = try context.fetch(FetchDescriptor<DBLibraryStatusEvent>())
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let desiredIDs = Set(desired.map { $0.1.id })
            for item in existing where !desiredIDs.contains(item.id) { context.delete(item) }
            for (gameID, event) in desired {
                let item = existingByID[event.id] ?? DBLibraryStatusEvent(
                    id: event.id,
                    gameID: gameID,
                    fromStatus: event.fromStatus?.rawValue,
                    toStatus: event.toStatus.rawValue,
                    changedAt: event.changedAt
                )
                if item.modelContext == nil { context.insert(item) }
                if item.gameID != gameID { item.gameID = gameID }
                let fromStatus = event.fromStatus?.rawValue
                if item.fromStatus != fromStatus { item.fromStatus = fromStatus }
                if item.toStatus != event.toStatus.rawValue { item.toStatus = event.toStatus.rawValue }
                if item.changedAt != event.changedAt { item.changedAt = event.changedAt }
            }
            if shouldSave { try database.save() }
        } catch {
            print("itchPocket status history save failed: \(error)")
        }
    }


    func saveCollections(save shouldSave: Bool = true) {
        let context = database.context
        do {
            let existing = try context.fetch(FetchDescriptor<DBLibraryCollection>())
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let desiredIDs = Set(collections.map(\.id))
            for item in existing where !desiredIDs.contains(item.id) { context.delete(item) }
            for collection in collections {
                let item = existingByID[collection.id] ?? DBLibraryCollection(
                    id: collection.id,
                    title: collection.title,
                    gameIDs: collection.gameIDs,
                    createdAt: collection.createdAt,
                    updatedAt: collection.updatedAt
                )
                if item.modelContext == nil { context.insert(item) }
                if item.title != collection.title { item.title = collection.title }
                if item.gameIDs != collection.gameIDs { item.gameIDs = collection.gameIDs }
                if item.createdAt != collection.createdAt { item.createdAt = collection.createdAt }
                if item.updatedAt != collection.updatedAt { item.updatedAt = collection.updatedAt }
            }
            if shouldSave { try database.save() }
        } catch {
            print("itchPocket collections save failed: \(error)")
        }
    }


}
