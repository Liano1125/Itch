import Foundation
import SwiftData

/// Owns persistence for update-monitor watch records only.
/// Network checks, notifications, and historical-sync state remain in GameUpdateMonitorStore.
@MainActor
final class UpdateMonitorRepository {
    enum RepositoryError: Error, Equatable {
        case duplicateWatchID(String)
    }

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// Rehydrates watch state using DBGame as the source of the current title and URL.
    /// Orphaned watch rows are ignored here; this read never deletes persisted data.
    func loadWatches() throws -> [String: GameUpdateWatch] {
        let context = database.context
        let games = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBGame>()).map { ($0.id, $0) }
        )
        let rows = try context.fetch(FetchDescriptor<DBUpdateWatch>())
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let game = games[row.gameID] else { return nil }
            return (row.gameID, GameUpdateWatch(
                gameID: row.gameID,
                gameTitle: game.title,
                gameURL: game.gameURL ?? "",
                entityTag: row.entityTag,
                lastModified: row.lastModified,
                contentHash: row.contentHash,
                lastCheckedAt: row.lastCheckedAt,
                hasBaseline: row.hasBaseline,
                isEnabled: row.isEnabled
            ))
        })
    }

    /// Reconciles a complete in-memory watch snapshot with DBUpdateWatch.
    /// Pass save=false when the caller batches this write with other repository changes.
    func saveWatches(_ watches: [GameUpdateWatch], save shouldSave: Bool = true) throws {
        var desiredByID: [String: GameUpdateWatch] = [:]
        for watch in watches {
            guard desiredByID[watch.gameID] == nil else {
                throw RepositoryError.duplicateWatchID(watch.gameID)
            }
            desiredByID[watch.gameID] = watch
        }

        let context = database.context
        let existing = try context.fetch(FetchDescriptor<DBUpdateWatch>())
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.gameID, $0) })
        let desiredIDs = Set(desiredByID.keys)

        for item in existing where !desiredIDs.contains(item.gameID) {
            context.delete(item)
        }

        for watch in desiredByID.values {
            let item = existingByID[watch.gameID] ?? DBUpdateWatch(gameID: watch.gameID)
            if item.modelContext == nil { context.insert(item) }
            item.entityTag = watch.entityTag
            item.lastModified = watch.lastModified
            item.contentHash = watch.contentHash
            item.lastCheckedAt = watch.lastCheckedAt
            item.hasBaseline = watch.hasBaseline
            item.isEnabled = watch.isEnabled
        }

        if shouldSave { try database.save() }
    }
}
