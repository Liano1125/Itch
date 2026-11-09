import Foundation
import SwiftData

/// Owns persistence for update-monitor watch records only.
/// Game identity and current metadata remain owned by GameRepository.
@MainActor
final class UpdateMonitorRepository {
    enum RepositoryError: Error, Equatable {
        case duplicateWatchID(String)
        case duplicatePersistedWatchID(String)
    }

    private let database: AppDatabase
    private let gameRepository: GameRepository

    init(database: AppDatabase) {
        self.database = database
        gameRepository = GameRepository(database: database)
    }

    /// Rehydrates watch state using canonical game snapshots.
    /// Orphaned watch rows are ignored, not deleted, by this read.
    func loadWatches() throws -> [String: GameUpdateWatch] {
        let games = try gameRepository.loadByID()
        let rows = try database.repositoryContext.fetch(FetchDescriptor<DBUpdateWatch>())
        var result: [String: GameUpdateWatch] = [:]

        for row in rows {
            guard let game = games[row.gameID] else { continue }
            guard result[row.gameID] == nil else {
                throw RepositoryError.duplicatePersistedWatchID(row.gameID)
            }
            result[row.gameID] = GameUpdateWatch(
                gameID: row.gameID,
                gameTitle: game.title,
                gameURL: game.gameURL ?? "",
                entityTag: row.entityTag,
                lastModified: row.lastModified,
                contentHash: row.contentHash,
                lastCheckedAt: row.lastCheckedAt,
                hasBaseline: row.hasBaseline,
                isEnabled: row.isEnabled
            )
        }
        return result
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

        let context = database.repositoryContext
        let existing = try context.fetch(FetchDescriptor<DBUpdateWatch>())
        var existingByID: [String: DBUpdateWatch] = [:]
        for row in existing {
            guard existingByID[row.gameID] == nil else {
                throw RepositoryError.duplicatePersistedWatchID(row.gameID)
            }
            existingByID[row.gameID] = row
        }

        // All duplicate validation completes before the first context mutation.
        let desiredIDs = Set(desiredByID.keys)
        for row in existing where !desiredIDs.contains(row.gameID) {
            context.delete(row)
        }

        for watch in desiredByID.values {
            let row = existingByID[watch.gameID] ?? DBUpdateWatch(gameID: watch.gameID)
            if row.modelContext == nil { context.insert(row) }
            if row.entityTag != watch.entityTag { row.entityTag = watch.entityTag }
            if row.lastModified != watch.lastModified { row.lastModified = watch.lastModified }
            if row.contentHash != watch.contentHash { row.contentHash = watch.contentHash }
            if row.lastCheckedAt != watch.lastCheckedAt { row.lastCheckedAt = watch.lastCheckedAt }
            if row.hasBaseline != watch.hasBaseline { row.hasBaseline = watch.hasBaseline }
            if row.isEnabled != watch.isEnabled { row.isEnabled = watch.isEnabled }
        }

        if shouldSave { try database.save() }
    }
}
