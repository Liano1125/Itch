import Foundation
import SwiftUI

/// Full-snapshot persistence is safe only after its source snapshot loaded completely.
enum SnapshotPersistencePolicy {
    static func canReplacePersistedSnapshot(didLoadSuccessfully: Bool) -> Bool {
        didLoadSuccessfully
    }

    /// Applies a full replacement only when the source snapshot was loaded successfully.
    /// Returning false leaves the persisted snapshot untouched.
    @discardableResult
    static func replacePersistedSnapshot<Element>(
        _ persisted: inout [Element],
        with desired: [Element],
        didLoadSuccessfully: Bool
    ) -> Bool {
        guard canReplacePersistedSnapshot(didLoadSuccessfully: didLoadSuccessfully) else {
            return false
        }
        persisted = desired
        return true
    }
}

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

    private let repository: PersonalLibraryRepository
    private let shouldSimulateSnapshotLoadFailure: () -> Bool
    // Full-snapshot writers must never treat a failed initial read as an empty database.
    private var didLoadLibrarySnapshots = false

    init(
        database: AppDatabase? = nil,
        repository: PersonalLibraryRepository? = nil,
        shouldSimulateSnapshotLoadFailure: @escaping () -> Bool = { false }
    ) {
        let resolvedDatabase = database ?? .shared
        self.repository = repository ?? PersonalLibraryRepository(database: resolvedDatabase)
        self.shouldSimulateSnapshotLoadFailure = shouldSimulateSnapshotLoadFailure
        load()
    }

    /// Retries loading the complete library snapshot after a transient read failure.
    func reload() {
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
            repository.saveRecord(updated, save: false)
            inserted += 1
        }
        if shouldSave && inserted > 0 { try? repository.save() }
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
        repository.saveRecord(updated, save: shouldSave)
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
        repository.saveRecord(record, save: false)
        saveStatusEvents(save: false)
        try? repository.save()
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
        repository.saveRecord(updated, save: false)
        try? repository.save()
    }

    /// Persists one complete scan in a single database save.
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
            try repository.saveSparkMetadata(records: records, changedGameIDs: changedGameIDs)
        } catch {
            print("itchPocket Spark metadata save failed: \\(error)")
        }
    }

    func remove(_ id: String) {
        guard didLoadLibrarySnapshots else {
            print("itchPocket library removal skipped: initial database load did not complete")
            return
        }
        records.removeAll { $0.id == id }
        statusEvents.removeValue(forKey: id)
        for index in collections.indices where collections[index].gameIDs.contains(id) {
            collections[index].gameIDs.removeAll { $0 == id }
            collections[index].updatedAt = Date()
        }
        do {
            try repository.remove(gameID: id, statusEvents: statusEvents, collections: collections)
        } catch {
            print("itchPocket library removal failed: \\(error)")
        }
    }

    private func load() {
        didLoadLibrarySnapshots = false
        do {
            if shouldSimulateSnapshotLoadFailure() {
                throw SnapshotLoadTestError.simulatedFailure
            }
            let snapshot = try repository.snapshot()
            records = snapshot.records
            statusEvents = snapshot.statusEvents
            collections = snapshot.collections
            didLoadLibrarySnapshots = true
        } catch {
            didLoadLibrarySnapshots = false
            print("itchPocket database load failed: \\(error)")
            records = []
            statusEvents = [:]
            collections = []
        }
    }

    private func saveStatusEvents(save shouldSave: Bool = true) {
        guard SnapshotPersistencePolicy.canReplacePersistedSnapshot(didLoadSuccessfully: didLoadLibrarySnapshots) else {
            print("itchPocket status history save skipped: initial database load did not complete")
            return
        }
        do {
            try repository.saveStatusEvents(statusEvents, save: shouldSave)
        } catch {
            print("itchPocket status history save failed: \\(error)")
        }
    }

    private func saveCollections(save shouldSave: Bool = true) {
        guard SnapshotPersistencePolicy.canReplacePersistedSnapshot(didLoadSuccessfully: didLoadLibrarySnapshots) else {
            print("itchPocket collections save skipped: initial database load did not complete")
            return
        }
        do {
            try repository.saveCollections(collections, save: shouldSave)
        } catch {
            print("itchPocket collections save failed: \\(error)")
        }
    }


}


private enum SnapshotLoadTestError: Error {
    case simulatedFailure
}
