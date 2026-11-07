import Foundation
import SwiftUI

enum LibraryStatus: String, CaseIterable, Codable, Identifiable {
    case wishlist = "想玩"
    case playing = "在玩"
    case completed = "已完成"
    case onHold = "暂不玩"
    case dropped = "已放弃"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .wishlist: return "bookmark"
        case .playing: return "gamecontroller"
        case .completed: return "checkmark.circle"
        case .onHold: return "pause.circle"
        case .dropped: return "xmark.circle"
        }
    }
}

struct LibraryDiscoveryTag: Codable, Hashable, Identifiable {
    var name: String
    var url: String
    var id: String { url }
}

struct SparkPlayMetadata {
    let runtimeSeconds: Double
    let lastSaveAt: Date?
    let renpyVersion: String?
    let saveCount: Int?
}

struct LibraryRecord: Codable, Identifiable {
    var id: String
    var title: String
    var gameURL: String?
    var coverURL: String?
    var developer: String?
    var developerProfileURL: String? = nil
    var patreonAvatarURL: String? = nil
    var developerAvatarURL: String? = nil
    var status: LibraryStatus
    var isFavorite: Bool
    var notes: String
    var addedAt: Date
    var updatedAt: Date
    var gameUpdates: [GameLibraryUpdate]? = nil
    var discoveryTags: [LibraryDiscoveryTag]? = nil
    var engine: String? = nil
    var patreonURL: String? = nil
    var discordURL: String? = nil
    var sparkPlaytimeSeconds: Double? = nil
    var sparkLastSaveAt: Date? = nil
    var sparkRenpyVersion: String? = nil
    var sparkSaveCount: Int? = nil
}

struct GameLibraryUpdate: Codable, Identifiable {
    var id: String
    var title: String?
    var summary: String
    var detectedAt: Date
    var publishedAt: Date?
    var url: String?
    var sourceID: String?
    var isHistorical: Bool?

    init(id: String = UUID().uuidString, title: String? = nil, summary: String, detectedAt: Date = Date(), publishedAt: Date? = nil, url: String? = nil, sourceID: String? = nil, isHistorical: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.detectedAt = detectedAt
        self.publishedAt = publishedAt
        self.url = url
        self.sourceID = sourceID
        self.isHistorical = isHistorical
    }
}

struct LibraryStatusEvent: Codable, Identifiable {
    var id: String
    var fromStatus: LibraryStatus?
    var toStatus: LibraryStatus
    var changedAt: Date

    init(id: String = UUID().uuidString, fromStatus: LibraryStatus?, toStatus: LibraryStatus, changedAt: Date = Date()) {
        self.id = id
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.changedAt = changedAt
    }
}


struct PersonalGameCollection: Codable, Identifiable {
    var id: String
    var title: String
    var gameIDs: [String]
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, title: String, gameIDs: [String] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.gameIDs = gameIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class PersonalLibraryStore: ObservableObject {
    static let shared = PersonalLibraryStore()
    @Published private(set) var records: [LibraryRecord] = []
    @Published private(set) var collections: [PersonalGameCollection] = []
    @Published private(set) var statusEvents: [String: [LibraryStatusEvent]] = [:]

    private let database = AppDatabase.shared

    init() {
        load()
    }

    func contains(_ id: String) -> Bool {
        records.contains { $0.id == id }
    }

    func record(for id: String) -> LibraryRecord? {
        records.first { $0.id == id }
    }

    func history(for gameID: String) -> [LibraryStatusEvent] {
        (statusEvents[gameID] ?? []).sorted { $0.changedAt > $1.changedAt }
    }

    func updates(for gameID: String) -> [GameLibraryUpdate] {
        (record(for: gameID)?.gameUpdates ?? []).sorted {
            ($0.publishedAt ?? $0.detectedAt) > ($1.publishedAt ?? $1.detectedAt)
        }
    }

    func recordGameUpdate(gameID: String, summary: String, detectedAt: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == gameID }) else { return }
        var updated = records[index]
        var history = updated.gameUpdates ?? []
        history.insert(GameLibraryUpdate(summary: summary, detectedAt: detectedAt), at: 0)
        updated.gameUpdates = Array(history.prefix(30))
        updated.updatedAt = detectedAt
        records[index] = updated
        persist(updated)
    }

    @discardableResult
    func recordHistoricalUpdate(gameID: String, title: String, summary: String, publishedAt: Date, url: String?, sourceID: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == gameID }) else { return false }
        var updated = records[index]
        var history = updated.gameUpdates ?? []
        guard !history.contains(where: { $0.sourceID == sourceID || ($0.url != nil && $0.url == url) }) else { return false }
        history.append(GameLibraryUpdate(
            title: title,
            summary: summary,
            detectedAt: Date(),
            publishedAt: publishedAt,
            url: url,
            sourceID: sourceID,
            isHistorical: true
        ))
        history.sort { ($0.publishedAt ?? $0.detectedAt) > ($1.publishedAt ?? $1.detectedAt) }
        updated.gameUpdates = Array(history.prefix(200))
        updated.updatedAt = Date()
        records[index] = updated
        persist(updated)
        return true
    }

    func createCollection(title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        collections.insert(PersonalGameCollection(title: cleaned), at: 0)
        saveCollections()
    }

    func updateCollection(_ collection: PersonalGameCollection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        var updated = collection
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty else { return }
        updated.updatedAt = Date()
        collections[index] = updated
        saveCollections()
    }

    func deleteCollection(_ id: String) {
        collections.removeAll { $0.id == id }
        saveCollections()
    }

    func containsGame(_ gameID: String, in collectionID: String) -> Bool {
        collections.first(where: { $0.id == collectionID })?.gameIDs.contains(gameID) ?? false
    }

    func toggleGame(_ gameID: String, in collectionID: String) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if collections[index].gameIDs.contains(gameID) {
            collections[index].gameIDs.removeAll { $0 == gameID }
        } else {
            collections[index].gameIDs.append(gameID)
        }
        collections[index].updatedAt = Date()
        saveCollections()
    }

    func add(_ game: PublicCollectionGame, status: LibraryStatus = .playing) {
        guard !contains(game.id) else { return }
        let now = Date()
        let record = LibraryRecord(
            id: game.id,
            title: game.title,
            gameURL: game.url?.absoluteString,
            coverURL: game.coverURL?.absoluteString,
            developer: game.developer,
            developerProfileURL: game.developerProfileURL?.absoluteString,
            status: status,
            isFavorite: false,
            notes: "",
            addedAt: now,
            updatedAt: now
        )
        records.insert(record, at: 0)
        statusEvents[game.id, default: []].append(
            LibraryStatusEvent(fromStatus: nil, toStatus: status, changedAt: now)
        )
        persist(record)
        saveStatusEvents()
    }

    func update(_ record: LibraryRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let previous = records[index]
        var updated = record
        if previous.status != updated.status {
            updated.updatedAt = Date()
            statusEvents[record.id, default: []].append(
                LibraryStatusEvent(fromStatus: previous.status, toStatus: updated.status, changedAt: updated.updatedAt)
            )
            saveStatusEvents()
        }
        records[index] = updated
        persist(updated)
    }

    /// Persists one complete scan in a single database save, and only writes
    /// Spark rows whose values actually changed.
    func updateSparkMetadata(_ metadataByGameID: [String: SparkPlayMetadata]) {
        guard !metadataByGameID.isEmpty else { return }
        var didChange = false
        let context = database.context

        for index in records.indices {
            guard let metadata = metadataByGameID[records[index].id] else { continue }
            var updated = records[index]
            var recordChanged = false
            let runtime = max(updated.sparkPlaytimeSeconds ?? 0, metadata.runtimeSeconds)
            if updated.sparkPlaytimeSeconds != runtime {
                updated.sparkPlaytimeSeconds = runtime
                recordChanged = true
            }
            if let lastSaveAt = metadata.lastSaveAt,
               updated.sparkLastSaveAt == nil || lastSaveAt > updated.sparkLastSaveAt! {
                updated.sparkLastSaveAt = lastSaveAt
                recordChanged = true
            }
            if let version = metadata.renpyVersion, updated.sparkRenpyVersion != version {
                updated.sparkRenpyVersion = version
                recordChanged = true
            }
            if let saveCount = metadata.saveCount, updated.sparkSaveCount != saveCount {
                updated.sparkSaveCount = saveCount
                recordChanged = true
            }
            if recordChanged {\n                records[index] = updated\n                didChange = true\n            }
        }

        guard didChange else { return }
        do {
            for record in records {
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
        } catch {
            print("itchPocket Spark metadata save failed: \(error)")
        }
    }

    func remove(_ id: String) {
        records.removeAll { $0.id == id }
        statusEvents.removeValue(forKey: id)
        let context = database.context
        do {
            if let entry = try context.fetch(FetchDescriptor<DBLibraryEntry>(predicate: #Predicate { $0.gameID == id })).first {
                context.delete(entry)
            }
            if let metadata = try context.fetch(FetchDescriptor<DBSparkMetadata>(predicate: #Predicate { $0.gameID == id })).first {
                context.delete(metadata)
            }
            try database.save()
        } catch {
            print("itchPocket library removal failed: \(error)")
        }
        saveStatusEvents()
        for index in collections.indices {
            collections[index].gameIDs.removeAll { $0 == id }
            collections[index].updatedAt = Date()
        }
        saveCollections()
    }

    private func load() {
        let context = database.context
        do {
            let games = try context.fetch(FetchDescriptor<DBGame>())
            let entries = try context.fetch(FetchDescriptor<DBLibraryEntry>())
            let developers = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBDeveloper>()).map { ($0.id, $0) })
            let updates = try context.fetch(FetchDescriptor<DBGameUpdate>())
            let metadata = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBSparkMetadata>()).map { ($0.gameID, $0) })
            let gameByID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
            let updatesByGame = Dictionary(grouping: updates, by: \.gameID)

            records = entries.compactMap { entry in
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
                    discoveryTags: game.discoveryTagsData.flatMap { try? JSONDecoder().decode([LibraryDiscoveryTag].self, from: $0) },
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
            statusEvents = Dictionary(grouping: statusRows, by: \.gameID).mapValues { rows in
                rows.map {
                    LibraryStatusEvent(
                        id: $0.id,
                        fromStatus: $0.fromStatus.flatMap(LibraryStatus.init(rawValue:)),
                        toStatus: LibraryStatus(rawValue: $0.toStatus) ?? .playing,
                        changedAt: $0.changedAt
                    )
                }
            }
            collections = try context.fetch(FetchDescriptor<DBLibraryCollection>()).map {
                PersonalGameCollection(id: $0.id, title: $0.title, gameIDs: $0.gameIDs, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            }
        } catch {
            print("itchPocket database load failed: \(error)")
            records = []
            statusEvents = [:]
            collections = []
        }
    }

    private func persist(_ record: LibraryRecord) {
        let context = database.context
        do {
            let developerID: String?
            if let profileURL = record.developerProfileURL, !profileURL.isEmpty {
                developerID = Self.canonicalDeveloperID(profileURL)
            } else if let name = record.developer, !name.isEmpty {
                developerID = "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } else {
                developerID = nil
            }

            if let developerID, let name = record.developer {
                let descriptor = FetchDescriptor<DBDeveloper>(predicate: #Predicate { $0.id == developerID })
                let developer = try context.fetch(descriptor).first ?? DBDeveloper(id: developerID, name: name)
                if developer.modelContext == nil { context.insert(developer) }
                developer.name = name
                developer.profileURL = record.developerProfileURL ?? developer.profileURL
                developer.patreonURL = record.patreonURL ?? developer.patreonURL
                developer.discordURL = record.discordURL ?? developer.discordURL
                if let avatar = record.patreonAvatarURL {
                    developer.avatarURL = avatar
                    developer.avatarSource = "patreon"
                } else if let avatar = record.developerAvatarURL, developer.avatarURL == nil {
                    developer.avatarURL = avatar
                    developer.avatarSource = "itch"
                }
                developer.updatedAt = .now
            }

            let gameDescriptor = FetchDescriptor<DBGame>(predicate: #Predicate { $0.id == record.id })
            let game = try context.fetch(gameDescriptor).first ?? DBGame(id: record.id, title: record.title)
            if game.modelContext == nil { context.insert(game) }
            game.title = record.title
            game.gameURL = record.gameURL
            game.coverURL = record.coverURL
            game.engine = record.engine
            game.discoveryTagsData = record.discoveryTags.flatMap { try? JSONEncoder().encode($0) }
            game.developerID = developerID
            game.updatedAt = .now

            let entryDescriptor = FetchDescriptor<DBLibraryEntry>(predicate: #Predicate { $0.gameID == record.id })
            let entry = try context.fetch(entryDescriptor).first ?? DBLibraryEntry(gameID: record.id, status: record.status.rawValue)
            if entry.modelContext == nil { context.insert(entry) }
            entry.status = record.status.rawValue
            entry.isFavorite = record.isFavorite
            entry.notes = record.notes
            entry.addedAt = record.addedAt
            entry.updatedAt = record.updatedAt

            let oldUpdates = try context.fetch(FetchDescriptor<DBGameUpdate>(predicate: #Predicate { $0.gameID == record.id }))
            let currentIDs = Set((record.gameUpdates ?? []).map(\.id))
            for old in oldUpdates where !currentIDs.contains(old.id) { context.delete(old) }
            for update in record.gameUpdates ?? [] {
                let updateID = update.id
                let updateDescriptor = FetchDescriptor<DBGameUpdate>(predicate: #Predicate { $0.id == updateID })
                let item = try context.fetch(updateDescriptor).first ?? DBGameUpdate(id: update.id, gameID: record.id, summary: update.summary)
                if item.modelContext == nil { context.insert(item) }
                item.gameID = record.id
                item.title = update.title
                item.summary = update.summary
                item.detectedAt = update.detectedAt
                item.publishedAt = update.publishedAt
                item.url = update.url
                item.sourceID = update.sourceID
                item.isHistorical = update.isHistorical ?? false
            }
            try database.save()
        } catch {
            print("itchPocket library database write failed: \(error)")
        }
    }

    private func saveStatusEvents() {
        let context = database.context
        do {
            try context.delete(model: DBLibraryStatusEvent.self)
            for (gameID, events) in statusEvents {
                for event in events {
                    context.insert(DBLibraryStatusEvent(
                        id: event.id,
                        gameID: gameID,
                        fromStatus: event.fromStatus?.rawValue,
                        toStatus: event.toStatus.rawValue,
                        changedAt: event.changedAt
                    ))
                }
            }
            try database.save()
        } catch {
            print("itchPocket status history save failed: \(error)")
        }
    }

    private func saveCollections() {
        let context = database.context
        do {
            try context.delete(model: DBLibraryCollection.self)
            for collection in collections {
                context.insert(DBLibraryCollection(
                    id: collection.id,
                    title: collection.title,
                    gameIDs: collection.gameIDs,
                    createdAt: collection.createdAt,
                    updatedAt: collection.updatedAt
                ))
            }
            try database.save()
        } catch {
            print("itchPocket collections save failed: \(error)")
        }
    }

    private static func canonicalDeveloperID(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else { return rawURL.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.string ?? rawURL.lowercased()
    }
}
