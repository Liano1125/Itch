import Foundation
import SwiftUI
import SwiftData

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
    // Full-snapshot writers must never treat a failed initial read as an empty database.
    private var didLoadLibrarySnapshots = false

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
        guard let record = record(for: gameID) else { return }
        recordDetectedUpdates([
            DetectedGameUpdate(
                gameID: gameID,
                gameTitle: record.title,
                gameURL: record.gameURL ?? "",
                summary: summary,
                fingerprint: "manual:\(detectedAt.timeIntervalSince1970)",
                detectedAt: detectedAt
            )
        ])
    }

    @discardableResult
    func recordDetectedUpdates(_ updates: [DetectedGameUpdate], save shouldSave: Bool = true) -> Int {
        var inserted = 0
        for update in updates {
            guard let index = records.firstIndex(where: { $0.id == update.gameID }) else { continue }
            var updated = records[index]
            var history = updated.gameUpdates ?? []
            guard !history.contains(where: { $0.detectedAt == update.detectedAt && $0.summary == update.summary }) else { continue }
            history.insert(GameLibraryUpdate(summary: update.summary, detectedAt: update.detectedAt), at: 0)
            updated.gameUpdates = Array(history.prefix(30))
            updated.updatedAt = update.detectedAt
            records[index] = updated
            persist(updated, save: false)
            inserted += 1
        }
        if shouldSave && inserted > 0 { try? database.save() }
        return inserted
    }

    @discardableResult
    func recordHistoricalUpdate(gameID: String, title: String, summary: String, publishedAt: Date, url: String?, sourceID: String) -> Bool {
        let update = GameLibraryUpdate(
            title: title,
            summary: summary,
            detectedAt: Date(),
            publishedAt: publishedAt,
            url: url,
            sourceID: sourceID,
            isHistorical: true
        )
        return recordHistoricalUpdates(gameID: gameID, updates: [update]) > 0
    }

    @discardableResult
    func recordHistoricalUpdates(gameID: String, updates incoming: [GameLibraryUpdate], save shouldSave: Bool = true) -> Int {
        guard let index = records.firstIndex(where: { $0.id == gameID }), !incoming.isEmpty else { return 0 }
        var updated = records[index]
        var history = updated.gameUpdates ?? []
        var inserted = 0
        for update in incoming {
            guard !history.contains(where: {
                ($0.sourceID != nil && $0.sourceID == update.sourceID)
                    || ($0.url != nil && $0.url == update.url)
            }) else { continue }
            history.append(update)
            inserted += 1
        }
        guard inserted > 0 else { return 0 }
        history.sort { ($0.publishedAt ?? $0.detectedAt) > ($1.publishedAt ?? $1.detectedAt) }
        updated.gameUpdates = Array(history.prefix(200))
        updated.updatedAt = Date()
        records[index] = updated
        persist(updated, save: shouldSave)
        return inserted
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
        persist(record, save: false)
        saveStatusEvents(save: false)
        try? database.save()
    }

    func update(_ record: LibraryRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let previous = records[index]
        var updated = record
        updated.updatedAt = Date()
        if previous.status != updated.status {
            statusEvents[record.id, default: []].append(
                LibraryStatusEvent(fromStatus: previous.status, toStatus: updated.status, changedAt: updated.updatedAt)
            )
            saveStatusEvents(save: false)
        }
        records[index] = updated
        persist(updated, save: false)
        try? database.save()
    }

    /// Persists one complete scan in a single database save, and only writes
    /// Spark rows whose values actually changed.
    func updateSparkMetadata(_ metadataByGameID: [String: SparkPlayMetadata]) {
        guard !metadataByGameID.isEmpty else { return }
        var didChange = false
        var changedGameIDs = Set<String>()
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
            if recordChanged {
                records[index] = updated
                changedGameIDs.insert(updated.id)
                didChange = true
            }
        }

        guard didChange else { return }
        do {
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
        saveStatusEvents(save: false)
        for index in collections.indices where collections[index].gameIDs.contains(id) {
            collections[index].gameIDs.removeAll { $0 == id }
            collections[index].updatedAt = Date()
        }
        saveCollections(save: false)
        try? database.save()
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
                    discoveryTags: GameDetailRepository.shared.discoveryTags(for: game),
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
            didLoadLibrarySnapshots = true
        } catch {
            didLoadLibrarySnapshots = false
            print("itchPocket database load failed: \(error)")
            records = []
            statusEvents = [:]
            collections = []
        }
    }

    private func persist(
        _ record: LibraryRecord,
        save shouldSave: Bool = true,
        updatesAreCompleteSnapshot: Bool = false
    ) {
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
                try GameDetailRepository.shared.applyPartialUpdate(
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

    private func saveStatusEvents(save shouldSave: Bool = true) {
        guard didLoadLibrarySnapshots else {
            print("itchPocket status history save skipped: initial database load did not complete")
            return
        }
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

    private func saveCollections(save shouldSave: Bool = true) {
        guard didLoadLibrarySnapshots else {
            print("itchPocket collections save skipped: initial database load did not complete")
            return
        }
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

    private static func canonicalDeveloperID(_ rawURL: String) -> String {
        AppDatabase.canonicalDeveloperID(rawURL)
    }
}
