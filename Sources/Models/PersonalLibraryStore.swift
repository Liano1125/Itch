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
    private let storageKey = "itchPocket.personalLibrary.v1"
    private let collectionsStorageKey = "itchPocket.collections.v1"
    private let statusEventsStorageKey = "itchPocket.statusEvents.v1"

    init() {
        load()
        loadCollections()
        loadStatusEvents()
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
        save()
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
        save()
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

    func add(_ game: PublicCollectionGame, status: LibraryStatus = .wishlist) {
        guard !contains(game.id) else { return }
        let now = Date()
        records.insert(
            LibraryRecord(
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
            ),
            at: 0
        )
        statusEvents[game.id, default: []].append(
            LibraryStatusEvent(fromStatus: nil, toStatus: status, changedAt: now)
        )
        save()
        saveStatusEvents()
    }

    func update(_ record: LibraryRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let previous = records[index]
        var updated = record
        updated.updatedAt = Date()
        records[index] = updated

        if previous.status != updated.status {
            statusEvents[record.id, default: []].append(
                LibraryStatusEvent(fromStatus: previous.status, toStatus: updated.status, changedAt: updated.updatedAt)
            )
            saveStatusEvents()
        }
        save()
    }

    func remove(_ id: String) {
        records.removeAll { $0.id == id }
        statusEvents.removeValue(forKey: id)
        saveStatusEvents()
        for index in collections.indices {
            collections[index].gameIDs.removeAll { $0 == id }
            collections[index].updatedAt = Date()
        }
        save()
        saveCollections()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LibraryRecord].self, from: data) else { return }
        records = decoded
    }

    private func loadCollections() {
        guard let data = UserDefaults.standard.data(forKey: collectionsStorageKey),
              let decoded = try? JSONDecoder().decode([PersonalGameCollection].self, from: data) else { return }
        collections = decoded
    }

    private func loadStatusEvents() {
        guard let data = UserDefaults.standard.data(forKey: statusEventsStorageKey),
              let decoded = try? JSONDecoder().decode([String: [LibraryStatusEvent]].self, from: data) else { return }
        statusEvents = decoded
    }

    private func saveStatusEvents() {
        guard let data = try? JSONEncoder().encode(statusEvents) else { return }
        UserDefaults.standard.set(data, forKey: statusEventsStorageKey)
    }

    private func saveCollections() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        UserDefaults.standard.set(data, forKey: collectionsStorageKey)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
