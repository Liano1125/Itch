import Foundation
import SwiftData

/// Owns persistence for update-monitor watches. Writes are incremental so a
/// failed read can never turn an empty in-memory snapshot into a destructive
/// full-table replacement.
@MainActor
final class GameUpdateMonitorRepository {
    static let shared = GameUpdateMonitorRepository(database: .shared)

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func watches() throws -> [GameUpdateWatch] {
        let context = database.repositoryContext
        let games = try context.fetch(FetchDescriptor<DBGame>())
        let gamesByID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
        let rows = try context.fetch(FetchDescriptor<DBUpdateWatch>())

        return rows.compactMap { row in
            guard let game = gamesByID[row.gameID] else { return nil }
            return GameUpdateWatch(
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
    }

    func save(_ watch: GameUpdateWatch, save shouldSave: Bool = true) throws {
        let context = database.repositoryContext
        try DatabaseReferenceValidator.requireGame(watch.gameID, in: context)
        let gameID = watch.gameID
        let descriptor = FetchDescriptor<DBUpdateWatch>(
            predicate: #Predicate { $0.gameID == gameID }
        )
        let item: DBUpdateWatch
        if let existing = try context.fetch(descriptor).first {
            item = existing
        } else {
            item = DBUpdateWatch(gameID: watch.gameID)
            context.insert(item)
        }
        item.entityTag = watch.entityTag
        item.lastModified = watch.lastModified
        item.contentHash = watch.contentHash
        item.lastCheckedAt = watch.lastCheckedAt
        item.hasBaseline = watch.hasBaseline
        item.isEnabled = watch.isEnabled
        if shouldSave { try database.save() }
    }

    func save(_ watches: [GameUpdateWatch], save shouldSave: Bool = true) throws {
        let context = database.repositoryContext
        for watch in watches {
            try DatabaseReferenceValidator.requireGame(watch.gameID, in: context)
        }
        for watch in watches {
            try save(watch, save: false)
        }
        if shouldSave { try database.save() }
    }

    func remove(gameID: String, save shouldSave: Bool = true) throws {
        let context = database.repositoryContext
        let targetGameID = gameID
        let descriptor = FetchDescriptor<DBUpdateWatch>(
            predicate: #Predicate { $0.gameID == targetGameID }
        )
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
        if shouldSave { try database.save() }
    }
}
