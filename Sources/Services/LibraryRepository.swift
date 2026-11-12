import Foundation
import SwiftData

struct StoredLibraryEntry: Equatable {
    let gameID: String
    let status: String
    let isFavorite: Bool
    let notes: String
    let addedAt: Date
    let updatedAt: Date
}

/// Owns personal-library entries, collection metadata, and normalized membership rows.
@MainActor
final class LibraryRepository {
    enum RepositoryError: LocalizedError {
        case collectionNotFound(String)
        case gameNotFound(String)
        case emptyCollectionTitle
        case membershipOutOfSync(String)
        case duplicateLibraryEntry(String)

        var errorDescription: String? {
            switch self {
            case .collectionNotFound(let id):
                return "Personal collection \(id) does not exist."
            case .gameNotFound(let id):
                return "Cannot add missing game \(id) to a collection."
            case .emptyCollectionTitle:
                return "A collection title cannot be empty."
            case .membershipOutOfSync(let id):
                return "Normalized membership rows are invalid for collection \(id)."
            case .duplicateLibraryEntry(let id):
                return "Multiple personal-library entries exist for game \(id)."
            }
        }
    }

    private let database: AppDatabase
    private let gameRepository: GameRepository

    init(database: AppDatabase) {
        self.database = database
        self.gameRepository = GameRepository(database: database)
    }

    func loadEntries() throws -> [StoredLibraryEntry] {
        let rows = try database.repositoryContext.fetch(FetchDescriptor<DBLibraryEntry>())
        try Self.validateUniqueGameIDs(rows.map(\.gameID))
        return rows.map { row in
            StoredLibraryEntry(gameID: row.gameID, status: row.status, isFavorite: row.isFavorite,
                               notes: row.notes, addedAt: row.addedAt, updatedAt: row.updatedAt)
        }
    }

    /// Fails closed if a malformed store exposes more than one row for a game.
    /// SwiftData's unique attribute is the primary guard; this protects reads
    /// from legacy or externally corrupted stores that violate that invariant.
    static func validateUniqueGameIDs(_ gameIDs: [String]) throws {
        var seen = Set<String>()
        for gameID in gameIDs {
            guard seen.insert(gameID).inserted else {
                throw RepositoryError.duplicateLibraryEntry(gameID)
            }
        }
    }

    /// Inserts or updates one membership row. Unmentioned games are untouched.
    func upsertEntry(_ entry: StoredLibraryEntry, save: Bool = true) throws {
        let gameID = entry.gameID
        let descriptor = FetchDescriptor<DBLibraryEntry>(predicate: #Predicate { $0.gameID == gameID })
        let context = database.repositoryContext
        try DatabaseReferenceValidator.requireGame(gameID, in: context)
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else { throw RepositoryError.duplicateLibraryEntry(gameID) }
        let row: DBLibraryEntry
        if let existing = matches.first {
            row = existing
        } else {
            row = DBLibraryEntry(gameID: entry.gameID, status: entry.status)
            context.insert(row)
        }
        row.status = entry.status
        row.isFavorite = entry.isFavorite
        row.notes = entry.notes
        row.addedAt = entry.addedAt
        row.updatedAt = entry.updatedAt
        if save { try database.save() }
    }

    func collections() throws -> [PersonalGameCollection] {
        let context = database.repositoryContext
        let rows = try context.fetch(FetchDescriptor<DBLibraryCollection>())
        let membershipRows = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
        let membershipsByCollection = Dictionary(grouping: membershipRows, by: \.collectionID)

        return try rows.map { row in
            let normalizedItems = (membershipsByCollection[row.id] ?? []).sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id < $1.id
            }
            let normalizedIDs = normalizedItems.map(\.gameID)
            guard Set(normalizedIDs).count == normalizedIDs.count,
                  normalizedItems.allSatisfy({
                      $0.id == DBLibraryCollectionItem.stableID(collectionID: row.id, gameID: $0.gameID)
                  }) else {
                throw RepositoryError.membershipOutOfSync(row.id)
            }

            try validateGamesExist(normalizedIDs)
            let gameIDs = normalizedIDs

            return PersonalGameCollection(
                id: row.id,
                title: row.title,
                gameIDs: gameIDs,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }
        .sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    @discardableResult
    func createCollection(title: String, now: Date = .now) throws -> PersonalGameCollection {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RepositoryError.emptyCollectionTitle }

        let collection = PersonalGameCollection(
            title: cleaned,
            createdAt: now,
            updatedAt: now
        )
        database.repositoryContext.insert(DBLibraryCollection(
            id: collection.id,
            title: collection.title,
            createdAt: collection.createdAt,
            updatedAt: collection.updatedAt
        ))
        try database.save()
        return collection
    }

    @discardableResult
    func updateCollection(_ collection: PersonalGameCollection, now: Date = .now) throws -> PersonalGameCollection {
        let cleaned = collection.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RepositoryError.emptyCollectionTitle }

        let context = database.repositoryContext
        let collectionID = collection.id
        let descriptor = FetchDescriptor<DBLibraryCollection>(
            predicate: #Predicate { $0.id == collectionID }
        )
        guard let row = try context.fetch(descriptor).first else {
            throw RepositoryError.collectionNotFound(collectionID)
        }

        // Do not let a stale in-memory snapshot silently overwrite a
        // partially migrated or inconsistent normalized membership set.
        _ = try membershipIDs(for: row)
        let gameIDs = Self.uniqueInOrder(collection.gameIDs)
        try validateGamesExist(gameIDs)
        row.title = cleaned
        row.updatedAt = now
        try replaceMemberships(for: row, gameIDs: gameIDs, now: now)
        try database.save()

        return PersonalGameCollection(
            id: row.id,
            title: row.title,
            gameIDs: gameIDs,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    func deleteCollection(id: String) throws {
        let context = database.repositoryContext
        let descriptor = FetchDescriptor<DBLibraryCollection>(
            predicate: #Predicate { $0.id == id }
        )
        let itemDescriptor = FetchDescriptor<DBLibraryCollectionItem>(
            predicate: #Predicate { $0.collectionID == id }
        )
        for item in try context.fetch(itemDescriptor) {
            context.delete(item)
        }
        if let collection = try context.fetch(descriptor).first {
            context.delete(collection)
        }
        try database.save()
    }

    @discardableResult
    func toggleGame(_ gameID: String, in collectionID: String, now: Date = .now) throws -> PersonalGameCollection {
        let context = database.repositoryContext
        let descriptor = FetchDescriptor<DBLibraryCollection>(
            predicate: #Predicate { $0.id == collectionID }
        )
        guard let row = try context.fetch(descriptor).first else {
            throw RepositoryError.collectionNotFound(collectionID)
        }

        let currentIDs = try membershipIDs(for: row)
        var nextIDs = currentIDs
        if nextIDs.contains(gameID) {
            nextIDs.removeAll { $0 == gameID }
        } else {
            try validateGamesExist([gameID])
            nextIDs.append(gameID)
        }

        row.updatedAt = now
        try replaceMemberships(for: row, gameIDs: nextIDs, now: now)
        try database.save()

        return PersonalGameCollection(
            id: row.id,
            title: row.title,
            gameIDs: nextIDs,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    /// Removes the active library entry, Spark snapshot, and collection membership.
    /// Game metadata, Devlog history, calendar events, and status history intentionally survive.
    /// Status history is a game timeline, not disposable state owned by the active library entry.
    func removeGameFromLibrary(gameID: String) throws {
        let context = database.repositoryContext

        // Read and validate every affected relationship before mutating the
        // shared context. A malformed collection must not leave half-applied
        // deletions waiting to be committed by an unrelated later save.
        let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>())
        let membershipsByCollection = try Dictionary(uniqueKeysWithValues: collections.map {
            ($0.id, try membershipIDs(for: $0))
        })
        let allMembershipRows = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
        let entries = try context.fetch(FetchDescriptor<DBLibraryEntry>(
            predicate: #Predicate { $0.gameID == gameID }
        ))
        let sparkRows = try context.fetch(FetchDescriptor<DBSparkMetadata>(
            predicate: #Predicate { $0.gameID == gameID }
        ))
        let affectedCollections = collections.compactMap { collection -> (DBLibraryCollection, [String], [DBLibraryCollectionItem])? in
            guard let currentIDs = membershipsByCollection[collection.id],
                  currentIDs.contains(gameID) else { return nil }
            let remainingIDs = currentIDs.filter { $0 != gameID }
            let existingItems = allMembershipRows.filter { $0.collectionID == collection.id }
            return (collection, remainingIDs, existingItems)
        }

        for item in entries { context.delete(item) }
        for item in sparkRows { context.delete(item) }
        for item in allMembershipRows where item.gameID == gameID {
            context.delete(item)
        }

        for (collection, remainingIDs, existingItems) in affectedCollections {
            collection.updatedAt = .now

            for item in existingItems where item.gameID != gameID {
                item.sortOrder = remainingIDs.firstIndex(of: item.gameID) ?? item.sortOrder
            }
        }

        try database.save()
    }

    private func membershipIDs(for collection: DBLibraryCollection) throws -> [String] {
        let collectionID = collection.id
        let descriptor = FetchDescriptor<DBLibraryCollectionItem>(
            predicate: #Predicate { $0.collectionID == collectionID }
        )
        let items = try database.repositoryContext.fetch(descriptor).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id < $1.id
        }
        let normalizedIDs = items.map(\.gameID)
        guard Set(normalizedIDs).count == normalizedIDs.count,
              items.allSatisfy({
                  $0.id == DBLibraryCollectionItem.stableID(collectionID: collectionID, gameID: $0.gameID)
              }) else {
            throw RepositoryError.membershipOutOfSync(collectionID)
        }
        try validateGamesExist(normalizedIDs)
        return normalizedIDs
    }

    private func replaceMemberships(
        for collection: DBLibraryCollection,
        gameIDs: [String],
        now: Date
    ) throws {
        let collectionID = collection.id
        let descriptor = FetchDescriptor<DBLibraryCollectionItem>(
            predicate: #Predicate { $0.collectionID == collectionID }
        )
        let existing = try database.repositoryContext.fetch(descriptor)
        guard Set(existing.map(\.gameID)).count == existing.count,
              existing.allSatisfy({
                  $0.id == DBLibraryCollectionItem.stableID(collectionID: collectionID, gameID: $0.gameID)
              }) else {
            throw RepositoryError.membershipOutOfSync(collectionID)
        }
        let existingByGameID = Dictionary(uniqueKeysWithValues: existing.map { ($0.gameID, $0) })
        let desiredIDs = Set(gameIDs)
        for item in existing where !desiredIDs.contains(item.gameID) {
            database.repositoryContext.delete(item)
        }
        for (index, gameID) in gameIDs.enumerated() {
            if let item = existingByGameID[gameID] {
                item.sortOrder = index
            } else {
                database.repositoryContext.insert(DBLibraryCollectionItem(
                    id: DBLibraryCollectionItem.stableID(collectionID: collectionID, gameID: gameID),
                    collectionID: collectionID,
                    gameID: gameID,
                    sortOrder: index,
                    addedAt: now
                ))
            }
        }
    }

    private func validateGamesExist(_ gameIDs: [String]) throws {
        let existingIDs = try gameRepository.existingGameIDs(in: gameIDs)
        for gameID in gameIDs where !existingIDs.contains(gameID) {
            throw RepositoryError.gameNotFound(gameID)
        }
    }

    private static func uniqueInOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
