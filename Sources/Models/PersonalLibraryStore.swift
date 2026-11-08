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

    private let database: AppDatabase
    private let libraryRepository: LibraryRepository
    private let statusHistoryRepository: LibraryStatusHistoryRepository
    private let gameUpdateRepository: GameUpdateRepository
    private let sparkRepository: SparkRepository
    private let developerRepository: DeveloperRepository

    init() {
        let database = AppDatabase.shared
        self.database = database
        self.libraryRepository = LibraryRepository(database: database)
        self.statusHistoryRepository = LibraryStatusHistoryRepository(database: database)
        self.gameUpdateRepository = GameUpdateRepository(database: database)
        self.sparkRepository = SparkRepository(database: database)
        self.developerRepository = DeveloperRepository(database: database)
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
        do {
            let insertedUpdates = try gameUpdateRepository.appendHistoricalUpdates(
                incoming,
                for: gameID,
                save: false
            )
            guard !insertedUpdates.isEmpty else { return 0 }
            var history = updated.gameUpdates ?? []
            history.append(contentsOf: insertedUpdates)
            history.sort { ($0.publishedAt ?? $0.detectedAt) > ($1.publishedAt ?? $1.detectedAt) }
            updated.gameUpdates = Array(history.prefix(200))
            updated.updatedAt = Date()
            records[index] = updated
            persist(updated, save: shouldSave)
            return insertedUpdates.count
        } catch {
            print("itchPocket historical update persistence failed: \(error)")
            return 0
        }
    }

    func createCollection(title: String) {
        do {
            let collection = try libraryRepository.createCollection(title: title)
            collections.insert(collection, at: 0)
        } catch {
            print("itchPocket collection creation failed: \(error)")
        }
    }

    func updateCollection(_ collection: PersonalGameCollection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        do {
            collections[index] = try libraryRepository.updateCollection(collection)
        } catch {
            print("itchPocket collection update failed: \(error)")
        }
    }

    func deleteCollection(_ id: String) {
        do {
            try libraryRepository.deleteCollection(id: id)
            collections.removeAll { $0.id == id }
        } catch {
            print("itchPocket collection deletion failed: \(error)")
        }
    }

    func containsGame(_ gameID: String, in collectionID: String) -> Bool {
        collections.first(where: { $0.id == collectionID })?.gameIDs.contains(gameID) ?? false
    }

    func toggleGame(_ gameID: String, in collectionID: String) {
        do {
            let updated = try libraryRepository.toggleGame(gameID, in: collectionID)
            if let index = collections.firstIndex(where: { $0.id == collectionID }) {
                collections[index] = updated
            }
        } catch {
            print("itchPocket collection membership update failed: \(error)")
        }
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
        let event = LibraryStatusEvent(fromStatus: nil, toStatus: status, changedAt: now)
        statusEvents[game.id, default: []].append(event)
        do {
            try statusHistoryRepository.append(event, for: game.id, save: false)
        } catch {
            print("itchPocket status history save failed: \(error)")
        }
        persist(record, save: false)
        try? database.save()
    }

    func update(_ record: LibraryRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let previous = records[index]
        var updated = record
        updated.updatedAt = Date()
        if previous.status != updated.status {
            let event = LibraryStatusEvent(
                fromStatus: previous.status,
                toStatus: updated.status,
                changedAt: updated.updatedAt
            )
            statusEvents[record.id, default: []].append(event)
            do {
                try statusHistoryRepository.append(event, for: record.id, save: false)
            } catch {
                print("itchPocket status history save failed: \(error)")
            }
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
            let scannedAt = Date()
            let snapshots = records.compactMap { record -> StoredSparkMetadata? in
                guard changedGameIDs.contains(record.id),
                      let runtime = record.sparkPlaytimeSeconds else { return nil }
                return StoredSparkMetadata(
                    gameID: record.id,
                    runtimeSeconds: runtime,
                    lastSaveAt: record.sparkLastSaveAt,
                    renpyVersion: record.sparkRenpyVersion,
                    saveCount: record.sparkSaveCount,
                    scannedAt: scannedAt
                )
            }
            try sparkRepository.upsert(snapshots, save: false)
            try database.save()
        } catch {
            print("itchPocket Spark metadata save failed: \(error)")
        }
    }

    func remove(_ id: String) {
        do {
            try libraryRepository.removeGameFromLibrary(gameID: id)
            records.removeAll { $0.id == id }
            statusEvents.removeValue(forKey: id)
            do {
                collections = try libraryRepository.collections()
            } catch {
                print("itchPocket collection reload after removal failed: \(error)")
            }
        } catch {
            print("itchPocket library removal failed: \(error)")
        }
    }

    private func load() {
        let context = database.context
        do {
            let games = try context.fetch(FetchDescriptor<DBGame>())
            let entries = try context.fetch(FetchDescriptor<DBLibraryEntry>())
            let developers = try developerRepository.loadByID()
            let updatesByGame = try gameUpdateRepository.loadUpdatesByGame()
            let metadata = try sparkRepository.loadByGameID()
            let gameByID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
            records = entries.compactMap { entry in
                guard let game = gameByID[entry.gameID] else { return nil }
                let developer = game.developerID.flatMap { developers[$0] }
                let spark = metadata[game.id]
                let gameUpdates = updatesByGame[game.id] ?? []
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

            do {
                statusEvents = try statusHistoryRepository.loadEvents()
            } catch {
                // A status-history read failure must not hide otherwise valid
                // game-library records from the user.
                print("itchPocket status history load failed: \(error)")
                statusEvents = [:]
            }
            do {
                collections = try libraryRepository.collections()
            } catch {
                print("itchPocket collection load failed: \(error)")
                collections = []
            }
        } catch {
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
                let existingDeveloper = try developerRepository.developer(id: developerID)
                try developerRepository.upsertIdentity(
                    id: developerID,
                    name: name,
                    profileURL: record.developerProfileURL,
                    patreonURL: record.patreonURL,
                    discordURL: record.discordURL,
                    save: false
                )
                if let avatar = record.patreonAvatarURL,
                   existingDeveloper?.avatarURL != avatar || existingDeveloper?.avatarSource != "patreon" {
                    try developerRepository.setAvatar(
                        id: developerID,
                        url: avatar,
                        source: "patreon",
                        save: false
                    )
                } else if let avatar = record.developerAvatarURL,
                          existingDeveloper?.avatarURL == nil {
                    try developerRepository.setAvatar(
                        id: developerID,
                        url: avatar,
                        source: "itch",
                        save: false
                    )
                }
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

            // LibraryRecord history is a partial projection (historical entries are capped).
            // The repository preserves omitted rows unless a caller explicitly supplies a complete snapshot.
            try gameUpdateRepository.synchronize(
                record.gameUpdates ?? [],
                for: gameID,
                completeSnapshot: updatesAreCompleteSnapshot,
                save: false
            )
            if shouldSave { try database.save() }
        } catch {
            print("itchPocket library database write failed: \(error)")
        }
    }

    private static func canonicalDeveloperID(_ rawURL: String) -> String {
        DeveloperRepository.canonicalID(for: rawURL)
    }
}
