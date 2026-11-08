import Foundation
import SwiftData

/// The detail cache still uses DBGame's legacy columns in this phase.
/// This repository is the only feature-facing read/write boundary for them.
@MainActor
final class GameDetailRepository {
    static let shared = GameDetailRepository(database: .shared)

    private let database: AppDatabase
    private let context: ModelContext

    private let fetchDatePrefix = "gameDetail.lastSuccessfulFetch."
    private let fetchStatusPrefix = "gameDetail.fetchStatus."
    private let legacyPrefetchDatePrefix = "detailPrefetch.lastSuccess."

    init(database: AppDatabase) {
        self.database = database
        self.context = database.context
    }

    func detail(for gameID: String) throws -> GameDetailRecord? {
        guard let game = try database.game(id: gameID) else { return nil }
        let tags = game.discoveryTagsData.flatMap {
            try? JSONDecoder().decode([LibraryDiscoveryTag].self, from: $0)
        } ?? []
        let statusValue = try database.state(for: fetchStatusPrefix + gameID)?.stringValue
        let currentFetchDate = try database.state(for: fetchDatePrefix + gameID)?.dateValue
        let legacyFetchDate = try database.state(for: legacyPrefetchDatePrefix + gameID)?.dateValue
        let fetchDate = currentFetchDate ?? legacyFetchDate

        return GameDetailRecord(
            description: game.descriptionText,
            galleryURLs: game.galleryURLs,
            discoveryTags: tags,
            fetchedAt: fetchDate,
            fetchStatus: GameDetailFetchStatus(rawValue: statusValue ?? "") ?? .unknown
        )
    }

    /// Applies only fields explicitly present in a partial response.
    /// An empty gallery/tag array is an explicit value and therefore clears it.
    func applyPartialUpdate(
        _ update: GameDetailPartialUpdate,
        for gameID: String,
        save shouldSave: Bool = true
    ) throws {
        guard let game = try database.game(id: gameID) else { return }
        game.descriptionText = GameDetailPersistencePolicy.resolvedValue(
            existing: game.descriptionText,
            incoming: update.description,
            mode: .partial
        )
        if let galleryURLs = GameDetailPersistencePolicy.resolvedValue(
            existing: Optional(game.galleryURLs),
            incoming: update.galleryURLs,
            mode: .partial
        ) {
            game.galleryURLs = galleryURLs
        }
        let existingTags = game.discoveryTagsData.flatMap {
            try? JSONDecoder().decode([LibraryDiscoveryTag].self, from: $0)
        }
        if let discoveryTags = GameDetailPersistencePolicy.resolvedValue(
            existing: existingTags,
            incoming: update.discoveryTags,
            mode: .partial
        ) {
            game.discoveryTagsData = try JSONEncoder().encode(discoveryTags)
        }
        if update.description != nil || update.galleryURLs != nil || update.discoveryTags != nil {
            let statusKey = fetchStatusPrefix + gameID
            let existingStatus = try database.state(for: statusKey)?.stringValue
            if existingStatus == nil {
                try setState(GameDetailFetchStatus.partial.rawValue, for: statusKey)
            }
        }
        if shouldSave { try database.save() }
    }

    /// A successful full page parse is authoritative, including nil description
    /// and empty arrays. Fetch freshness is independent of DBGame.updatedAt.
    func replaceCompleteSnapshot(
        _ snapshot: GameDetailCompleteSnapshot,
        for gameID: String,
        fetchedAt: Date = .now
    ) throws {
        guard let game = try database.game(id: gameID) else { return }
        game.descriptionText = GameDetailPersistencePolicy.resolvedValue(
            existing: game.descriptionText,
            incoming: snapshot.description,
            mode: .complete
        )
        game.galleryURLs = GameDetailPersistencePolicy.resolvedValue(
            existing: Optional(game.galleryURLs),
            incoming: snapshot.galleryURLs,
            mode: .complete
        ) ?? []
        let existingTags = game.discoveryTagsData.flatMap {
            try? JSONDecoder().decode([LibraryDiscoveryTag].self, from: $0)
        }
        let resolvedTags = GameDetailPersistencePolicy.resolvedValue(
            existing: existingTags,
            incoming: snapshot.discoveryTags,
            mode: .complete
        ) ?? []
        game.discoveryTagsData = try JSONEncoder().encode(resolvedTags)

        try setState(fetchedAt, for: fetchDatePrefix + gameID)
        try setState(GameDetailFetchStatus.complete.rawValue, for: fetchStatusPrefix + gameID)
        try database.save()
    }

    private func setState(_ value: Date, for key: String) throws {
        let state = try database.state(for: key) ?? DBAppState(key: key)
        if state.modelContext == nil { context.insert(state) }
        state.dateValue = value
        state.stringValue = nil
        state.updatedAt = .now
    }

    private func setState(_ value: String, for key: String) throws {
        let state = try database.state(for: key) ?? DBAppState(key: key)
        if state.modelContext == nil { context.insert(state) }
        state.stringValue = value
        state.dateValue = nil
        state.updatedAt = .now
    }
}

struct GameDetailRecord {
    let description: String?
    let galleryURLs: [String]
    let discoveryTags: [LibraryDiscoveryTag]
    let fetchedAt: Date?
    let fetchStatus: GameDetailFetchStatus
}

enum GameDetailFetchStatus: String, Equatable {
    case unknown
    case partial
    case complete
}

struct GameDetailPartialUpdate {
    var description: String? = nil
    var galleryURLs: [String]? = nil
    var discoveryTags: [LibraryDiscoveryTag]? = nil
}

struct GameDetailCompleteSnapshot {
    let description: String?
    let galleryURLs: [String]
    let discoveryTags: [LibraryDiscoveryTag]
}
