import Foundation
import SwiftData

/// Owns personal-library collection metadata and normalized membership rows.
/// The legacy gameIDs array is kept in sync until a later schema cutover.
@MainActor
final class LibraryRepository {
    enum RepositoryError: LocalizedError {
        case collectionNotFound(String)
        case gameNotFound(String)
        case emptyCollectionTitle
        case membershipOutOfSync(String)

        var errorDescription: String? {
            switch self {
            case .collectionNotFound(let id):
                return "Personal collection \(id) does not exist."
            case .gameNotFound(let id):
                return "Cannot add missing game \(id) to a collection."
            case .emptyCollectionTitle:
                return "A collection title cannot be empty."
            case .membershipOutOfSync(let id):
                return "Normalized membership rows do not match the legacy collection snapshot for \(id)."
            }
        }
    }

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func collections() throws -> [PersonalGameCollection] {
        let context = database.context
        let rows = try context.fetch(FetchDescriptor<DBLibraryCollection>())
        let membershipRows = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
        let membershipsByCollection = Dictionary(grouping: membershipRows, by: \.collectionID)

        return try rows.map { row in
            let normalizedItems = (membershipsByCollection[row.id] ?? []).sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id < $1.id
            }
            let normalizedIDs = normalizedItems.map(\.gameID)
            let legacyIDs = Self.uniqueInOrder(row.gameIDs)
            guard Set(normalizedIDs).count == normalizedIDs.count,
                  normalizedItems.allSatisfy({
                      $0.id == DBLibraryCollectionItem.stableID(collectionID: row.id, gameID: $0.gameID)
                  }) else {
                throw RepositoryError.membershipOutOfSync(row.id)
            }

            // V2 migration creates both representations. A wholly absent join
            // set can still be read from the legacy array for older/incomplete
            // stores, but a partial disagreement is treated as corruption.
            let gameIDs: [String]
            if normalizedItems.isEmpty && !legacyIDs.isEmpty {
                gameIDs = legacyIDs
            } else {
                guard normalizedIDs == legacyIDs else {
                    throw RepositoryError.membershipOutOfSync(row.id)
                }
                gameIDs = normalizedIDs
            }

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
        database.context.insert(DBLibraryCollection(
            id: collection.id,
            title: collection.title,
            gameIDs: [],
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

        let context = database.context
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
        row.gameIDs = gameIDs
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
        let context = database.context
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
        let context = database.context
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

        row.gameIDs = nextIDs
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

    /// Removes only library-owned records and collection membership.
    /// Game metadata, update history, and calendar events intentionally survive.
    func removeGameFromLibrary(gameID: String) throws {
        let context = database.context

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
        let statusRows = try context.fetch(FetchDescriptor<DBLibraryStatusEvent>(
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
        for item in statusRows { context.delete(item) }
        for item in allMembershipRows where item.gameID == gameID {
            context.delete(item)
        }

        for (collection, remainingIDs, existingItems) in affectedCollections {
            collection.gameIDs = remainingIDs
            collection.updatedAt = .now

            if existingItems.isEmpty {
                // Legacy-only collection: preserve the migration convention
                // that pre-existing members inherit the collection creation date.
                for (index, remainingID) in remainingIDs.enumerated() {
                    context.insert(DBLibraryCollectionItem(
                        id: DBLibraryCollectionItem.stableID(collectionID: collection.id, gameID: remainingID),
                        collectionID: collection.id,
                        gameID: remainingID,
                        sortOrder: index,
                        addedAt: collection.createdAt
                    ))
                }
            } else {
                for item in existingItems where item.gameID != gameID {
                    item.sortOrder = remainingIDs.firstIndex(of: item.gameID) ?? item.sortOrder
                }
            }
        }

        try database.save()
    }

    private func membershipIDs(for collection: DBLibraryCollection) throws -> [String] {
        let collectionID = collection.id
        let descriptor = FetchDescriptor<DBLibraryCollectionItem>(
            predicate: #Predicate { $0.collectionID == collectionID }
        )
        let items = try database.context.fetch(descriptor).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id < $1.id
        }
        let normalizedIDs = items.map(\.gameID)
        let legacyIDs = Self.uniqueInOrder(collection.gameIDs)
        guard Set(normalizedIDs).count == normalizedIDs.count,
              items.allSatisfy({
                  $0.id == DBLibraryCollectionItem.stableID(collectionID: collectionID, gameID: $0.gameID)
              }) else {
            throw RepositoryError.membershipOutOfSync(collectionID)
        }
        if items.isEmpty && !legacyIDs.isEmpty { return legacyIDs }
        guard normalizedIDs == legacyIDs else {
            throw RepositoryError.membershipOutOfSync(collectionID)
        }
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
        let existing = try database.context.fetch(descriptor)
        guard Set(existing.map(\.gameID)).count == existing.count,
              existing.allSatisfy({
                  $0.id == DBLibraryCollectionItem.stableID(collectionID: collectionID, gameID: $0.gameID)
              }) else {
            throw RepositoryError.membershipOutOfSync(collectionID)
        }
        let existingByGameID = Dictionary(uniqueKeysWithValues: existing.map { ($0.gameID, $0) })
        let desiredIDs = Set(gameIDs)
        for item in existing where !desiredIDs.contains(item.gameID) {
            database.context.delete(item)
        }
        for (index, gameID) in gameIDs.enumerated() {
            if let item = existingByGameID[gameID] {
                item.sortOrder = index
            } else {
                database.context.insert(DBLibraryCollectionItem(
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
        for gameID in gameIDs {
            let descriptor = FetchDescriptor<DBGame>(
                predicate: #Predicate { $0.id == gameID }
            )
            guard try database.context.fetch(descriptor).first != nil else {
                throw RepositoryError.gameNotFound(gameID)
            }
        }
    }

    private static func uniqueInOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
