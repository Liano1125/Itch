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
        let entryDescriptor = FetchDescriptor<DBLibraryEntry>(
            predicate: #Predicate { $0.gameID == gameID }
        )
        let sparkDescriptor = FetchDescriptor<DBSparkMetadata>(
            predicate: #Predicate { $0.gameID == gameID }
        )
        let statusDescriptor = FetchDescriptor<DBLibraryStatusEvent>(
            predicate: #Predicate { $0.gameID == gameID }
        )
        let membershipDescriptor = FetchDescriptor<DBLibraryCollectionItem>(
            predicate: #Predicate { $0.gameID == gameID }
        )

        for item in try context.fetch(entryDescriptor) { context.delete(item) }
        for item in try context.fetch(sparkDescriptor) { context.delete(item) }
        for item in try context.fetch(statusDescriptor) { context.delete(item) }
        for item in try context.fetch(membershipDescriptor) { context.delete(item) }

        let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>())
        for collection in collections where collection.gameIDs.contains(gameID) {
            collection.gameIDs.removeAll { $0 == gameID }
            collection.updatedAt = .now
            try normalizeMemberships(for: collection)
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
        for item in try database.context.fetch(descriptor) {
            database.context.delete(item)
        }
        for (index, gameID) in gameIDs.enumerated() {
            database.context.insert(DBLibraryCollectionItem(
                id: DBLibraryCollectionItem.stableID(collectionID: collectionID, gameID: gameID),
                collectionID: collectionID,
                gameID: gameID,
                sortOrder: index,
                addedAt: now
            ))
        }
    }

    private func normalizeMemberships(for collection: DBLibraryCollection) throws {
        let currentIDs = try membershipIDs(for: collection)
        try replaceMemberships(for: collection, gameIDs: currentIDs.filter { $0 != "" }, now: .now)
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
