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
    @Published private(set) var lastAddError: String?

    private let database: AppDatabase
    private let libraryRepository: LibraryRepository
    private let statusHistoryRepository: LibraryStatusHistoryRepository
    private let gameUpdateRepository: GameUpdateRepository
    private let sparkRepository: SparkRepository
    private let developerRepository: DeveloperRepository
    private let gameRepository: GameRepository
    private let shouldSimulateLibraryLoadFailure: () -> Bool
    private var didLoadLibrarySnapshots = false
    private var accountSession: ItchAccountSession?

    private enum StagingError: Error {
        case snapshotNotLoaded
    }

    init(
        database: AppDatabase? = nil,
        shouldSimulateLibraryLoadFailure: @escaping () -> Bool = { false }
    ) {
        let database = database ?? AppDatabase.shared
        self.database = database
        self.libraryRepository = LibraryRepository(database: database)
        self.statusHistoryRepository = LibraryStatusHistoryRepository(database: database)
        self.gameUpdateRepository = GameUpdateRepository(database: database)
        self.sparkRepository = SparkRepository(database: database)
        self.developerRepository = DeveloperRepository(database: database)
        self.gameRepository = GameRepository(database: database)
        self.shouldSimulateLibraryLoadFailure = shouldSimulateLibraryLoadFailure
        load()
    }

    /// Retries loading after a transient repository read failure.
    func reload() {
        load()
    }

    /// Binds the authenticated session without reassigning legacy V3 rows to an account.
    func bindAccountSession(_ session: ItchAccountSession) {
        accountSession = session
    }

    /// Captures a session boundary before starting account-sensitive asynchronous work.
    func captureRequestContext() -> ItchSessionOperationContext? {
        accountSession?.captureOperationContext()
    }

    /// An unbound store preserves legacy behavior; once bound, missing or stale contexts fail closed.
    func isCurrent(_ context: ItchSessionOperationContext?) -> Bool {
        guard let accountSession else { return context == nil }
        guard let context else { return false }
        return accountSession.isCurrent(context)
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

    /// Stages detected-update persistence in the caller's transaction without publishing memory state.
    func stageDetectedUpdates(_ updates: [DetectedGameUpdate]) throws -> Int {
        guard didLoadLibrarySnapshots else { throw StagingError.snapshotNotLoaded }
        var proposedRecords = records
        var changedIndices = Set<Int>()
        var inserted = 0
        for update in updates {
            guard let index = proposedRecords.firstIndex(where: { $0.id == update.gameID }) else { continue }
            var updated = proposedRecords[index]
            var history = updated.gameUpdates ?? []
            guard !history.contains(where: { $0.detectedAt == update.detectedAt && $0.summary == update.summary }) else { continue }
            history.insert(GameLibraryUpdate(summary: update.summary, detectedAt: update.detectedAt), at: 0)
            updated.gameUpdates = Array(history.prefix(30))
            updated.updatedAt = update.detectedAt
            proposedRecords[index] = updated
            changedIndices.insert(index)
            inserted += 1
        }
        guard inserted > 0 else { return 0 }
        for index in changedIndices.sorted() {
            try persist(proposedRecords[index], save: false)
        }
        return inserted
    }

    @discardableResult
    func recordDetectedUpdates(_ updates: [DetectedGameUpdate], save shouldSave: Bool = true) -> Int {
        guard didLoadLibrarySnapshots else { return 0 }
        do {
            if shouldSave {
                let inserted = try database.performTransaction {
                    try stageDetectedUpdates(updates)
                }
                if inserted > 0 { load() }
                return inserted
            }
            return try stageDetectedUpdates(updates)
        } catch {
            print("itchPocket detected update transaction failed: \(error)")
            return 0
        }
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

    /// Stages historical update rows and the matching library snapshot in the caller's transaction.
    func stageHistoricalUpdates(gameID: String, updates incoming: [GameLibraryUpdate]) throws -> Int {
        guard didLoadLibrarySnapshots else { throw StagingError.snapshotNotLoaded }
        guard let index = records.firstIndex(where: { $0.id == gameID }), !incoming.isEmpty else { return 0 }
        let original = records[index]
        let insertedUpdates = try gameUpdateRepository.appendHistoricalUpdates(
            incoming,
            for: gameID,
            save: false
        )
        guard !insertedUpdates.isEmpty else { return 0 }
        var updated = original
        var history = updated.gameUpdates ?? []
        history.append(contentsOf: insertedUpdates)
        history.sort { ($0.publishedAt ?? $0.detectedAt) > ($1.publishedAt ?? $1.detectedAt) }
        updated.gameUpdates = Array(history.prefix(200))
        updated.updatedAt = Date()
        try persist(updated, save: false)
        return insertedUpdates.count
    }

    @discardableResult
    func recordHistoricalUpdates(gameID: String, updates incoming: [GameLibraryUpdate], save shouldSave: Bool = true) -> Int {
        guard didLoadLibrarySnapshots else { return 0 }
        do {
            if shouldSave {
                let inserted = try database.performTransaction {
                    try stageHistoricalUpdates(gameID: gameID, updates: incoming)
                }
                if inserted > 0 { load() }
                return inserted
            }
            return try stageHistoricalUpdates(gameID: gameID, updates: incoming)
        } catch {
            print("itchPocket historical update transaction failed: \(error)")
            return 0
        }
    }

    func createCollection(title: String) {
        guard didLoadLibrarySnapshots else { return }
        do {
            let collection = try libraryRepository.createCollection(title: title)
            collections.insert(collection, at: 0)
        } catch {
            print("itchPocket collection creation failed: \(error)")
        }
    }

    func updateCollection(_ collection: PersonalGameCollection) {
        guard didLoadLibrarySnapshots else { return }
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        do {
            collections[index] = try libraryRepository.updateCollection(collection)
        } catch {
            print("itchPocket collection update failed: \(error)")
        }
    }

    func deleteCollection(_ id: String) {
        guard didLoadLibrarySnapshots else { return }
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
        guard didLoadLibrarySnapshots else { return }
        do {
            let updated = try libraryRepository.toggleGame(gameID, in: collectionID)
            if let index = collections.firstIndex(where: { $0.id == collectionID }) {
                collections[index] = updated
            }
        } catch {
            print("itchPocket collection membership update failed: \(error)")
        }
    }

    @discardableResult
    func add(_ game: PublicCollectionGame, status: LibraryStatus = .playing) -> Bool {
        if !didLoadLibrarySnapshots {
            // A transient startup read can leave the UI visible while writes are
            // intentionally blocked. Retry the snapshot load once before giving up.
            load()
            if !didLoadLibrarySnapshots {
                lastAddError = "游戏库数据尚未加载完成，请稍后重试。"
                return false
            }
        }
        guard !contains(game.id) else {
            lastAddError = nil
            return false
        }
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
        let event = LibraryStatusEvent(fromStatus: nil, toStatus: status, changedAt: now)

        do {
            try database.performTransaction {
                // Status history has a foreign-key reference to DBGame. Persisting
                // the library projection first creates the canonical game row;
                // appending history before this used to fail for newly discovered
                // games until their detail page happened to create that row.
                try persist(record, save: false)
                try statusHistoryRepository.append(event, for: game.id, save: false)
            }
            records.insert(record, at: 0)
            statusEvents[game.id, default: []].append(event)
            lastAddError = nil
            return true
        } catch {
            print("itchPocket library add transaction failed: \(error)")
            lastAddError = error.localizedDescription
            return false
        }
    }

    func update(_ record: LibraryRecord) {
        guard didLoadLibrarySnapshots else { return }
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let previous = records[index]
        var updated = record
        updated.updatedAt = Date()
        let event: LibraryStatusEvent? = previous.status == updated.status ? nil : LibraryStatusEvent(
            fromStatus: previous.status,
            toStatus: updated.status,
            changedAt: updated.updatedAt
        )

        do {
            try database.performTransaction {
                if let event {
                    try statusHistoryRepository.append(event, for: record.id, save: false)
                }
                try persist(updated, save: false)
            }
            records[index] = updated
            if let event { statusEvents[record.id, default: []].append(event) }
        } catch {
            print("itchPocket library update transaction failed: \(error)")
        }
    }

    /// Persists one complete scan in a single database transaction, and only writes
    /// Spark rows whose values actually changed.
    func updateSparkMetadata(
        _ metadataByGameID: [String: SparkPlayMetadata],
        requestContext: ItchSessionOperationContext? = nil
    ) {
        guard isCurrent(requestContext) else { return }
        guard didLoadLibrarySnapshots else { return }
        guard !metadataByGameID.isEmpty else { return }
        var proposedRecords = records
        var changedGameIDs = Set<String>()

        for index in proposedRecords.indices {
            guard let metadata = metadataByGameID[proposedRecords[index].id] else { continue }
            var updated = proposedRecords[index]
            let runtime = max(updated.sparkPlaytimeSeconds ?? 0, metadata.runtimeSeconds)
            updated.sparkPlaytimeSeconds = runtime
            if let lastSaveAt = metadata.lastSaveAt,
               updated.sparkLastSaveAt == nil || lastSaveAt > updated.sparkLastSaveAt! {
                updated.sparkLastSaveAt = lastSaveAt
            }
            if let version = metadata.renpyVersion { updated.sparkRenpyVersion = version }
            if let saveCount = metadata.saveCount { updated.sparkSaveCount = saveCount }

            if updated.sparkPlaytimeSeconds != proposedRecords[index].sparkPlaytimeSeconds
                || updated.sparkLastSaveAt != proposedRecords[index].sparkLastSaveAt
                || updated.sparkRenpyVersion != proposedRecords[index].sparkRenpyVersion
                || updated.sparkSaveCount != proposedRecords[index].sparkSaveCount {
                proposedRecords[index] = updated
                changedGameIDs.insert(updated.id)
            }
        }

        guard !changedGameIDs.isEmpty else { return }
        let scannedAt = Date()
        let snapshots = proposedRecords.compactMap { record -> StoredSparkMetadata? in
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

        do {
            try database.performTransaction {
                try sparkRepository.upsert(snapshots, save: false)
            }
            records = proposedRecords
        } catch {
            print("itchPocket Spark metadata transaction failed: \(error)")
        }
    }

    func remove(_ id: String) {
        guard didLoadLibrarySnapshots else { return }
        do {
            try libraryRepository.removeGameFromLibrary(gameID: id)
            records.removeAll { $0.id == id }
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
        didLoadLibrarySnapshots = false
        do {
            if shouldSimulateLibraryLoadFailure() {
                throw PersonalLibraryStoreLoadError.simulatedFailure
            }

            let gamesByID = try gameRepository.loadByID()
            let entries = try libraryRepository.loadEntries()
            let developers = try developerRepository.loadByID()
            let updatesByGame = try gameUpdateRepository.loadUpdatesByGame()
            let metadata = try sparkRepository.loadByGameID()
            let detailRepository = GameDetailRepository(database: database)
            let loadedRecords: [LibraryRecord] = entries.compactMap { entry -> LibraryRecord? in
                guard let game = gamesByID[entry.gameID] else { return nil }
                let developer = game.developerID.flatMap { developers[$0] }
                let spark = metadata[game.id]
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
                    gameUpdates: updatesByGame[game.id] ?? [],
                    discoveryTags: try? detailRepository.discoveryTags(for: game.id),
                    engine: game.engine,
                    patreonURL: developer?.patreonURL,
                    discordURL: developer?.discordURL,
                    sparkPlaytimeSeconds: spark?.runtimeSeconds,
                    sparkLastSaveAt: spark?.lastSaveAt,
                    sparkRenpyVersion: spark?.renpyVersion,
                    sparkSaveCount: spark?.saveCount
                )
            }.sorted { $0.addedAt > $1.addedAt }

            var loadedStatusEvents = statusEvents
            var statusHistoryLoaded = false
            do {
                loadedStatusEvents = try statusHistoryRepository.loadEvents()
                statusHistoryLoaded = true
            } catch {
                print("itchPocket status history load failed: \(error)")
            }

            var loadedCollections = collections
            var collectionsLoaded = false
            do {
                loadedCollections = try libraryRepository.collections()
                collectionsLoaded = true
            } catch {
                print("itchPocket collection load failed: \(error)")
            }

            records = loadedRecords
            statusEvents = loadedStatusEvents
            collections = loadedCollections
            didLoadLibrarySnapshots = statusHistoryLoaded && collectionsLoaded
        } catch {
            // Keep the last known-good snapshot. On first launch the arrays
            // are already empty, and reload() can retry without losing data.
            print("itchPocket database load failed; retaining previous library snapshot: \(error)")
        }
    }

    private func persist(
        _ record: LibraryRecord,
        save shouldSave: Bool = true,
        updatesAreCompleteSnapshot: Bool = false
    ) throws {
        guard didLoadLibrarySnapshots else {
            throw PersonalLibraryStoreLoadError.persistenceBlocked
        }
        let write = {
            let developerID: String?
            if let profileURL = record.developerProfileURL, !profileURL.isEmpty {
                developerID = Self.canonicalDeveloperID(profileURL)
            } else if let name = record.developer, !name.isEmpty {
                developerID = "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } else {
                developerID = nil
            }

            if let developerID, let name = record.developer {
                let existingDeveloper = try self.developerRepository.developer(id: developerID)
                try self.developerRepository.upsertIdentity(
                    id: developerID,
                    name: name,
                    profileURL: record.developerProfileURL,
                    patreonURL: record.patreonURL,
                    discordURL: record.discordURL,
                    save: false
                )
                if let avatar = record.patreonAvatarURL,
                   existingDeveloper?.avatarURL != avatar || existingDeveloper?.avatarSource != "patreon" {
                    try self.developerRepository.setAvatar(
                        id: developerID,
                        url: avatar,
                        source: "patreon",
                        save: false
                    )
                } else if let avatar = record.developerAvatarURL,
                          existingDeveloper?.avatarURL == nil {
                    try self.developerRepository.setAvatar(
                        id: developerID,
                        url: avatar,
                        source: "itch",
                        save: false
                    )
                }
            }

            let gameID = record.id
            try self.gameRepository.upsertMetadata(
                id: gameID,
                title: record.title,
                gameURL: record.gameURL,
                coverURL: record.coverURL,
                engine: record.engine,
                developerID: developerID,
                save: false
            )
            if let tags = record.discoveryTags {
                try GameDetailRepository.shared.applyPartialUpdate(
                    GameDetailPartialUpdate(discoveryTags: tags),
                    for: gameID,
                    save: false
                )
            }

            try self.libraryRepository.upsertEntry(
                StoredLibraryEntry(
                    gameID: gameID,
                    status: record.status.rawValue,
                    isFavorite: record.isFavorite,
                    notes: record.notes,
                    addedAt: record.addedAt,
                    updatedAt: record.updatedAt
                ),
                save: false
            )

            // LibraryRecord history is a partial projection (historical entries are capped).
            // The repository preserves omitted rows unless a caller explicitly supplies a complete snapshot.
            try self.gameUpdateRepository.synchronize(
                record.gameUpdates ?? [],
                for: gameID,
                completeSnapshot: updatesAreCompleteSnapshot,
                save: false
            )
        }

        if shouldSave {
            try database.performTransaction(write)
        } else {
            try write()
        }
    }

    private static func canonicalDeveloperID(_ rawURL: String) -> String {
        DeveloperRepository.canonicalID(for: rawURL)
    }
}


private enum PersonalLibraryStoreLoadError: Error {
    case simulatedFailure
    case persistenceBlocked
}
