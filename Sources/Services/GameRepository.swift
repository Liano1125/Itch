import Foundation
import SwiftData

/// Immutable projection of canonical game identity and metadata.
struct StoredGame: Equatable {
    let id: String
    let title: String
    let gameURL: String?
    let coverURL: String?
    let engine: String?
    let developerID: String?
    let updatedAt: Date

    fileprivate init(_ row: DBGame) {
        id = row.id
        title = row.title
        gameURL = row.gameURL
        coverURL = row.coverURL
        engine = row.engine
        developerID = row.developerID
        updatedAt = row.updatedAt
    }
}

/// Owns canonical DBGame identity and metadata persistence. It deliberately
/// does not own library membership, updates, calendar events, or detail status.
@MainActor
final class GameRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func game(id: String) throws -> StoredGame? {
        let gameID = id
        let descriptor = FetchDescriptor<DBGame>(
            predicate: #Predicate { $0.id == gameID }
        )
        return try database.repositoryContext.fetch(descriptor).first.map(StoredGame.init)
    }

    func loadByID() throws -> [String: StoredGame] {
        let rows = try database.repositoryContext.fetch(FetchDescriptor<DBGame>())
        return Dictionary(rows.map { ($0.id, StoredGame($0)) }, uniquingKeysWith: { _, latest in latest })
    }

    /// Nil optional values preserve existing metadata, matching the former
    /// AppDatabase.upsertGame behavior. This operation never deletes a game.
    func upsertMetadata(
        id: String,
        title: String,
        gameURL: String? = nil,
        coverURL: String? = nil,
        engine: String? = nil,
        developerID: String? = nil,
        save shouldSave: Bool = true
    ) throws {
        let context = database.repositoryContext
        let gameID = id
        let descriptor = FetchDescriptor<DBGame>(
            predicate: #Predicate { $0.id == gameID }
        )
        let row = try context.fetch(descriptor).first ?? DBGame(id: id, title: title)
        var changed = row.modelContext == nil
        if row.modelContext == nil { context.insert(row) }
        if row.title != title { row.title = title; changed = true }
        if let gameURL, row.gameURL != gameURL { row.gameURL = gameURL; changed = true }
        if let coverURL, row.coverURL != coverURL { row.coverURL = coverURL; changed = true }
        if let engine, row.engine != engine { row.engine = engine; changed = true }
        if let developerID, row.developerID != developerID { row.developerID = developerID; changed = true }
        if changed { row.updatedAt = .now }
        if shouldSave { try database.save() }
    }

    func existingGameIDs(in candidates: [String]) throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let wanted = Set(candidates)
        let rows = try database.repositoryContext.fetch(FetchDescriptor<DBGame>())
        return Set(rows.lazy.map(\.id).filter { wanted.contains($0) })
    }

}
