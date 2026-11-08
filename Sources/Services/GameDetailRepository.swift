import Foundation
import SwiftData

/// The detail cache still uses DBGame's legacy columns in this phase.
/// This repository is the only feature-facing read/write boundary for them.
@MainActor
final class GameDetailRepository {
    static let shared = GameDetailRepository(database: .shared)

    private let database: AppDatabase
    private let appStateRepository: AppStateRepository
    private let saveChanges: () throws -> Void

    private let fetchDatePrefix = "gameDetail.lastSuccessfulFetch."
    private let fetchStatusPrefix = "gameDetail.fetchStatus."
    private let legacyPrefetchDatePrefix = "detailPrefetch.lastSuccess."

    init(database: AppDatabase, saveChanges: (() throws -> Void)? = nil) {
        self.database = database
        self.appStateRepository = AppStateRepository(database: database)
        self.saveChanges = saveChanges ?? { try database.save() }
    }

    func detail(for gameID: String) throws -> GameDetailRecord? {
        guard let game = try database.game(id: gameID) else { return nil }
        return try detail(for: game)
    }

    func detail(for game: DBGame) throws -> GameDetailRecord {
        let gameID = game.id
        let tags = discoveryTags(for: game) ?? []
        let statusValue = try appStateRepository.state(for: fetchStatusPrefix + gameID)?.stringValue
        let currentFetchDate = try appStateRepository.state(for: fetchDatePrefix + gameID)?.dateValue
        let legacyFetchDate = try appStateRepository.state(for: legacyPrefetchDatePrefix + gameID)?.dateValue
        let fetchDate = currentFetchDate ?? legacyFetchDate

        return GameDetailRecord(
            description: game.descriptionText,
            galleryURLs: game.galleryURLs,
            discoveryTags: tags,
            fetchedAt: fetchDate,
            fetchStatus: GameDetailFetchStatus(rawValue: statusValue ?? "") ?? .unknown
        )
    }

    /// Resolves a usable developer name without ever persisting a placeholder.
    /// Fresh page data wins; otherwise preserve the existing database/library name.
    nonisolated static func resolvedDeveloperName(
        incoming: String?,
        existing: String?,
        library: String?
    ) -> String? {
        func usable(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.caseInsensitiveCompare("itch.io 开发者") != .orderedSame else {
                return nil
            }
            return trimmed
        }
        return usable(incoming) ?? usable(existing) ?? usable(library)
    }

    /// Reads the legacy tag column without another database fetch; nil means no stored value.
    func discoveryTags(for game: DBGame) -> [LibraryDiscoveryTag]? {
        guard let data = game.discoveryTagsData else { return nil }
        return try? JSONDecoder().decode([LibraryDiscoveryTag].self, from: data)
    }

    /// Applies only fields explicitly present in a partial response.
    /// An empty gallery/tag array is an explicit value and therefore clears it.
    func applyPartialUpdate(
        _ update: GameDetailPartialUpdate,
        for gameID: String,
        save shouldSave: Bool = true
    ) throws {
        guard let game = try database.game(id: gameID) else { return }
        let statusKey = fetchStatusPrefix + gameID
        let original = GameFieldsSnapshot(game: game)
        let stateSnapshots = try captureStates(for: [statusKey])
        do {
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
                let existingStatus = try appStateRepository.state(for: statusKey)?.stringValue
                if existingStatus == nil {
                    try appStateRepository.setString(GameDetailFetchStatus.partial.rawValue, for: statusKey, clearOtherValues: true, save: false)
                }
            }
            if shouldSave { try commit() }
        } catch {
            original.restore(to: game)
            restoreStates(stateSnapshots)
            throw error
        }
    }

    /// Applies only fields the page parser positively identified.
    /// A page is considered fresh/complete only when every detail section was resolved.
    /// Missing DOM sections preserve cached values; an identified empty section may clear them.
    @discardableResult
    func applyPageSnapshot(
        _ snapshot: GameDetailPageSnapshot,
        for gameID: String,
        fetchedAt: Date = .now
    ) throws -> GameDetailFetchStatus {
        guard let game = try database.game(id: gameID) else { return .unknown }

        let statusKey = fetchStatusPrefix + gameID
        let dateKey = fetchDatePrefix + gameID
        let original = GameFieldsSnapshot(game: game)
        let stateSnapshots = try captureStates(for: [statusKey, dateKey])
        do {
            if snapshot.descriptionResolved {
                game.descriptionText = snapshot.description
            }
            if snapshot.galleryResolved {
                game.galleryURLs = snapshot.galleryURLs
            }
            if snapshot.tagsResolved {
                game.discoveryTagsData = try JSONEncoder().encode(snapshot.discoveryTags)
            }

            if snapshot.isComplete {
                try appStateRepository.setDate(fetchedAt, for: dateKey, clearOtherValues: true, save: false)
                try appStateRepository.setString(GameDetailFetchStatus.complete.rawValue, for: statusKey, clearOtherValues: true, save: false)
            } else {
                let existingStatus = try appStateRepository.state(for: statusKey)?.stringValue
                if existingStatus == nil || existingStatus == GameDetailFetchStatus.unknown.rawValue {
                    try appStateRepository.setString(GameDetailFetchStatus.partial.rawValue, for: statusKey, clearOtherValues: true, save: false)
                }
            }

            try commit()
            return snapshot.isComplete ? .complete : .partial
        } catch {
            original.restore(to: game)
            restoreStates(stateSnapshots)
            throw error
        }
    }

    private func commit() throws {
        try saveChanges()
    }

    private struct StateSnapshot {
        let key: String
        let state: StoredAppState?
    }

    private struct GameFieldsSnapshot {
        let descriptionText: String?
        let galleryURLs: [String]
        let discoveryTagsData: Data?

        init(game: DBGame) {
            descriptionText = game.descriptionText
            galleryURLs = game.galleryURLs
            discoveryTagsData = game.discoveryTagsData
        }

        func restore(to game: DBGame) {
            game.descriptionText = descriptionText
            game.galleryURLs = galleryURLs
            game.discoveryTagsData = discoveryTagsData
        }
    }

    private func captureStates(for keys: [String]) throws -> [StateSnapshot] {
        try keys.map { key in
            StateSnapshot(key: key, state: try appStateRepository.state(for: key))
        }
    }

    /// Restores only the keys touched by this repository operation. Never roll back
    /// the shared ModelContext, which may contain unrelated pending app changes.
    private func restoreStates(_ snapshots: [StateSnapshot]) {
        for snapshot in snapshots {
            try? appStateRepository.restore(snapshot.state, for: snapshot.key)
        }
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

struct GameDetailPageSnapshot {
    let description: String?
    let descriptionResolved: Bool
    let galleryURLs: [String]
    let galleryResolved: Bool
    let discoveryTags: [LibraryDiscoveryTag]
    let tagsResolved: Bool

    var isComplete: Bool {
        GameDetailSnapshotPolicy.shouldMarkComplete(
            descriptionResolved: descriptionResolved,
            galleryResolved: galleryResolved,
            tagsResolved: tagsResolved
        )
    }
}

enum GameDetailSnapshotPolicy {
    static func shouldMarkComplete(
        descriptionResolved: Bool,
        galleryResolved: Bool,
        tagsResolved: Bool
    ) -> Bool {
        descriptionResolved && galleryResolved && tagsResolved
    }

    static func resolvedValue<Value>(
        existing: Value,
        incoming: Value,
        isResolved: Bool
    ) -> Value {
        isResolved ? incoming : existing
    }
}
