import Foundation
import SwiftData

/// A value-only projection of a persisted update, keyed by its stable database ID.
struct StoredGameUpdate {
    let gameID: String
    let update: GameLibraryUpdate
}

/// Owns all DBGameUpdate reads and writes. Partial snapshots never delete rows.
@MainActor
final class GameUpdateRepository {
    enum RepositoryError: LocalizedError {
        case updateIDConflict(String)
        case duplicateUpdateID(String)

        var errorDescription: String? {
            switch self {
            case .updateIDConflict(let id):
                return "Game-update ID \(id) is already associated with another game."
            case .duplicateUpdateID(let id):
                return "The update batch contains duplicate ID \(id)."
            }
        }
    }

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func loadUpdatesByGame() throws -> [String: [GameLibraryUpdate]] {
        let rows = try database.context.fetch(FetchDescriptor<DBGameUpdate>())
        return Dictionary(grouping: rows, by: \.gameID).mapValues { rows in
            rows.map(Self.value(from:)).sorted(by: Self.isNewer)
        }
    }

    func loadUpdatesByID() throws -> [String: StoredGameUpdate] {
        let rows = try database.context.fetch(FetchDescriptor<DBGameUpdate>())
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, StoredGameUpdate(gameID: $0.gameID, update: Self.value(from: $0)))
        })
    }

    func detectedUpdateID(gameID: String, detectedAt: Date) throws -> String? {
        let descriptor = FetchDescriptor<DBGameUpdate>(
            predicate: #Predicate { $0.gameID == gameID && $0.detectedAt == detectedAt }
        )
        return try database.context.fetch(descriptor).first?.id
    }

    /// Inserts or updates one row. Reusing another game's ID is rejected before mutation.
    func upsert(_ update: GameLibraryUpdate, for gameID: String, save shouldSave: Bool = true) throws {
        let context = database.context
        let updateID = update.id
        let descriptor = FetchDescriptor<DBGameUpdate>(
            predicate: #Predicate { $0.id == updateID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.gameID != gameID {
            throw RepositoryError.updateIDConflict(updateID)
        }

        let row = existing ?? DBGameUpdate(
            id: update.id,
            gameID: gameID,
            title: update.title,
            summary: update.summary,
            detectedAt: update.detectedAt,
            publishedAt: update.publishedAt,
            url: update.url,
            sourceID: update.sourceID,
            isHistorical: update.isHistorical ?? false
        )
        if existing == nil { context.insert(row) }
        Self.apply(update, to: row, gameID: gameID)

        if shouldSave { try database.save() }
    }

    /// Synchronizes a caller-provided history. Omitted rows are deleted only for an
    /// explicitly complete snapshot; ordinary LibraryRecord values are partial.
    func synchronize(
        _ updates: [GameLibraryUpdate],
        for gameID: String,
        completeSnapshot: Bool = false,
        save shouldSave: Bool = true
    ) throws {
        let ids = updates.map(\.id)
        guard Set(ids).count == ids.count else {
            let duplicate = ids.first { id in ids.filter { $0 == id }.count > 1 } ?? "unknown"
            throw RepositoryError.duplicateUpdateID(duplicate)
        }

        let context = database.context
        let existingForGame = try context.fetch(FetchDescriptor<DBGameUpdate>(
            predicate: #Predicate { $0.gameID == gameID }
        ))
        var rowsByID: [String: DBGameUpdate] = [:]
        for update in updates {
            let updateID = update.id
            let descriptor = FetchDescriptor<DBGameUpdate>(
                predicate: #Predicate { $0.id == updateID }
            )
            if let existing = try context.fetch(descriptor).first {
                guard existing.gameID == gameID else {
                    throw RepositoryError.updateIDConflict(updateID)
                }
                rowsByID[updateID] = existing
            }
        }

        let incomingIDs = Set(ids)
        if completeSnapshot {
            for stored in existingForGame where LibraryUpdatePersistencePolicy.shouldDeleteStoredUpdate(
                storedID: stored.id,
                incomingIDs: incomingIDs,
                isCompleteSnapshot: true
            ) {
                context.delete(stored)
            }
        }

        for update in updates {
            let row = rowsByID[update.id] ?? DBGameUpdate(
                id: update.id,
                gameID: gameID,
                title: update.title,
                summary: update.summary,
                detectedAt: update.detectedAt,
                publishedAt: update.publishedAt,
                url: update.url,
                sourceID: update.sourceID,
                isHistorical: update.isHistorical ?? false
            )
            if row.modelContext == nil { context.insert(row) }
            Self.apply(update, to: row, gameID: gameID)
        }

        if shouldSave { try database.save() }
    }

    /// Adds only historical entries not already represented by source ID or URL.
    /// The database, rather than a possibly truncated in-memory history, is authoritative.
    func appendHistoricalUpdates(
        _ updates: [GameLibraryUpdate],
        for gameID: String,
        save shouldSave: Bool = true
    ) throws -> [GameLibraryUpdate] {
        guard !updates.isEmpty else { return [] }
        let context = database.context
        let existingRows = try context.fetch(FetchDescriptor<DBGameUpdate>(
            predicate: #Predicate { $0.gameID == gameID }
        ))
        var knownSourceIDs = Set(existingRows.compactMap(\.sourceID))
        var knownURLs = Set(existingRows.compactMap(\.url))
        var candidates: [GameLibraryUpdate] = []

        for update in updates {
            let duplicateSource = update.sourceID.map { knownSourceIDs.contains($0) } ?? false
            let duplicateURL = update.url.map { knownURLs.contains($0) } ?? false
            guard !duplicateSource && !duplicateURL else { continue }
            candidates.append(update)
            if let sourceID = update.sourceID { knownSourceIDs.insert(sourceID) }
            if let url = update.url { knownURLs.insert(url) }
        }

        let ids = candidates.map(\.id)
        guard Set(ids).count == ids.count else {
            let duplicate = ids.first { id in ids.filter { $0 == id }.count > 1 } ?? "unknown"
            throw RepositoryError.duplicateUpdateID(duplicate)
        }
        // Validate all identities before inserting any candidate into the shared context.
        for update in candidates {
            let updateID = update.id
            let descriptor = FetchDescriptor<DBGameUpdate>(
                predicate: #Predicate { $0.id == updateID }
            )
            if let existing = try context.fetch(descriptor).first, existing.gameID != gameID {
                throw RepositoryError.updateIDConflict(updateID)
            }
        }

        for update in candidates {
            try upsert(update, for: gameID, save: false)
        }
        if shouldSave && !candidates.isEmpty { try database.save() }
        return candidates
    }

    /// Refreshes a historical row by source ID while preserving its stable DB identity.
    func upsertHistorical(
        _ update: GameLibraryUpdate,
        for gameID: String,
        save shouldSave: Bool = true
    ) throws -> GameLibraryUpdate {
        if let sourceID = update.sourceID {
            let descriptor = FetchDescriptor<DBGameUpdate>(
                predicate: #Predicate { $0.gameID == gameID && $0.sourceID == sourceID }
            )
            if let existing = try database.context.fetch(descriptor).first {
                var refreshed = Self.value(from: existing)
                refreshed.title = update.title
                refreshed.summary = update.summary
                refreshed.publishedAt = update.publishedAt
                refreshed.url = update.url
                refreshed.sourceID = sourceID
                refreshed.isHistorical = true
                try upsert(refreshed, for: gameID, save: shouldSave)
                return refreshed
            }
        }

        var historical = update
        historical.isHistorical = true
        try upsert(historical, for: gameID, save: shouldSave)
        return historical
    }

    private static func apply(_ update: GameLibraryUpdate, to row: DBGameUpdate, gameID: String) {
        row.gameID = gameID
        row.title = update.title
        row.summary = update.summary
        row.detectedAt = update.detectedAt
        row.publishedAt = update.publishedAt
        row.url = update.url
        row.sourceID = update.sourceID
        row.isHistorical = update.isHistorical ?? false
    }

    private static func value(from row: DBGameUpdate) -> GameLibraryUpdate {
        GameLibraryUpdate(
            id: row.id,
            title: row.title,
            summary: row.summary,
            detectedAt: row.detectedAt,
            publishedAt: row.publishedAt,
            url: row.url,
            sourceID: row.sourceID,
            isHistorical: row.isHistorical
        )
    }

    private static func isNewer(_ lhs: GameLibraryUpdate, _ rhs: GameLibraryUpdate) -> Bool {
        let left = lhs.publishedAt ?? lhs.detectedAt
        let right = rhs.publishedAt ?? rhs.detectedAt
        if left != right { return left > right }
        return lhs.id < rhs.id
    }
}
