import Foundation
import SwiftData

/// Immutable projection returned by the V4 account-scoped library repository.
struct StoredAccountLibraryEntry: Equatable {
    let gameID: String
    let status: String
    let isFavorite: Bool
    let notes: String
    let addedAt: Date
    let updatedAt: Date
}


/// Immutable account-owned collection metadata.
struct StoredAccountLibraryCollection: Equatable {
    let collectionKey: String
    let title: String
}

/// Immutable membership row for one account-owned collection.
struct StoredAccountLibraryCollectionItem: Equatable {
    let collectionKey: String
    let gameID: String
    let sortOrder: Int
}

/// Immutable account-owned status transition.
struct StoredAccountLibraryStatusEvent: Equatable {
    let eventKey: String
    let gameID: String
    let fromStatus: String?
    let toStatus: String
}

/// V4-only repository for personal library rows.
///
/// This repository deliberately accepts a V4 ModelContext rather than
/// AppDatabase: the app still boots V3, and silently routing these operations
/// through the V3 store would reintroduce cross-account data leakage.
/// Shared DBGame rows remain global; every personal read/write is filtered by
/// the stable itch account ID.
@MainActor
final class AccountScopedLibraryRepository {
    enum RepositoryError: LocalizedError {
        case invalidAccountID
        case missingGame(String)
        case duplicateEntry(String)

        var errorDescription: String? {
            switch self {
            case .invalidAccountID:
                return "An authenticated itch account ID is required."
            case .missingGame(let id):
                return "Cannot add missing shared game \(id) to an account library."
            case .duplicateEntry(let id):
                return "Multiple library entries exist for game \(id) in this account."
            }
        }
    }

    private let context: ModelContext
    let accountID: String

    init(context: ModelContext, accountID: String) throws {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == accountID,
              normalized.hasPrefix("itch:"),
              let userID = Int(normalized.dropFirst(5)),
              userID > 0,
              normalized == "itch:\(userID)" else {
            throw RepositoryError.invalidAccountID
        }
        self.context = context
        self.accountID = normalized
    }

    func loadEntries() throws -> [StoredAccountLibraryEntry] {
        let scope = accountID
        let descriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>(
            predicate: #Predicate { $0.accountID == scope }
        )
        return try context.fetch(descriptor).map {
            StoredAccountLibraryEntry(
                gameID: $0.gameID,
                status: $0.status,
                isFavorite: $0.isFavorite,
                notes: $0.notes,
                addedAt: $0.addedAt,
                updatedAt: $0.updatedAt
            )
        }.sorted { $0.addedAt > $1.addedAt }
    }

    func upsertEntry(_ entry: StoredAccountLibraryEntry, save: Bool = true) throws {
        try V4AccountRegistryGuard.requireRegisteredAccount(accountID, in: context)
        let gameID = entry.gameID
        let gameDescriptor = FetchDescriptor<DBGame>(
            predicate: #Predicate { $0.id == gameID }
        )
        guard try !context.fetch(gameDescriptor).isEmpty else {
            throw RepositoryError.missingGame(gameID)
        }

        let scope = accountID
        let descriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>(
            predicate: #Predicate { $0.accountID == scope && $0.gameID == gameID }
        )
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else { throw RepositoryError.duplicateEntry(gameID) }

        let row: ItchPocketSchemaV4.DBLibraryEntry
        if let existing = matches.first {
            row = existing
        } else {
            row = ItchPocketSchemaV4.DBLibraryEntry(
                accountID: accountID,
                gameID: gameID,
                status: entry.status,
                isFavorite: entry.isFavorite,
                notes: entry.notes,
                addedAt: entry.addedAt,
                updatedAt: entry.updatedAt
            )
            context.insert(row)
        }
        row.status = entry.status
        row.isFavorite = entry.isFavorite
        row.notes = entry.notes
        row.addedAt = entry.addedAt
        row.updatedAt = entry.updatedAt
        if save { try context.save() }
    }

    func removeEntry(gameID: String, save: Bool = true) throws {
        let scope = accountID
        let descriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>(
            predicate: #Predicate { $0.accountID == scope && $0.gameID == gameID }
        )
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw RepositoryError.duplicateEntry(gameID) }
        rows.forEach(context.delete)
        if save, !rows.isEmpty { try context.save() }
    }

    // MARK: - Account-owned collections

    func loadCollections() throws -> [StoredAccountLibraryCollection] {
        let scope = accountID
        let descriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>(
            predicate: #Predicate { $0.accountID == scope }
        )
        return try context.fetch(descriptor).map {
            StoredAccountLibraryCollection(collectionKey: $0.collectionKey, title: $0.title)
        }.sorted { $0.collectionKey < $1.collectionKey }
    }

    func upsertCollection(
        collectionKey: String,
        title: String,
        save: Bool = true
    ) throws {
        try V4AccountRegistryGuard.requireRegisteredAccount(accountID, in: context)
        let key = collectionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !normalizedTitle.isEmpty else {
            throw RepositoryError.invalidAccountID
        }
        let scope = accountID
        let descriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>(
            predicate: #Predicate { $0.accountID == scope && $0.collectionKey == key }
        )
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else { throw RepositoryError.duplicateEntry(key) }
        if let existing = matches.first {
            existing.title = normalizedTitle
        } else {
            context.insert(ItchPocketSchemaV4.DBLibraryCollection(
                accountID: accountID,
                collectionKey: key,
                title: normalizedTitle
            ))
        }
        if save { try context.save() }
    }

    /// Removes a collection and its memberships as one save operation.
    func removeCollection(collectionKey: String, save: Bool = true) throws {
        let scope = accountID
        let collections = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>(
            predicate: #Predicate { $0.accountID == scope && $0.collectionKey == collectionKey }
        ))
        let items = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>(
            predicate: #Predicate { $0.accountID == scope && $0.collectionKey == collectionKey }
        ))
        guard collections.count <= 1 else { throw RepositoryError.duplicateEntry(collectionKey) }
        collections.forEach(context.delete)
        items.forEach(context.delete)
        if save, !collections.isEmpty || !items.isEmpty {
            do { try context.save() } catch { context.rollback(); throw error }
        }
    }

    func loadCollectionItems(collectionKey: String) throws -> [StoredAccountLibraryCollectionItem] {
        let scope = accountID
        let descriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>(
            predicate: #Predicate { $0.accountID == scope && $0.collectionKey == collectionKey }
        )
        return try context.fetch(descriptor).map {
            StoredAccountLibraryCollectionItem(
                collectionKey: $0.collectionKey,
                gameID: $0.gameID,
                sortOrder: $0.sortOrder
            )
        }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.gameID < $1.gameID
        }
    }

    func addGameToCollection(
        collectionKey: String,
        gameID: String,
        sortOrder: Int = 0,
        save: Bool = true
    ) throws {
        try V4AccountRegistryGuard.requireRegisteredAccount(accountID, in: context)
        let scope = accountID
        let collectionRows = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>(
            predicate: #Predicate { $0.accountID == scope && $0.collectionKey == collectionKey }
        ))
        guard collectionRows.count == 1 else { throw RepositoryError.missingGame(collectionKey) }
        let gameRows = try context.fetch(FetchDescriptor<DBGame>(
            predicate: #Predicate { $0.id == gameID }
        ))
        guard !gameRows.isEmpty else { throw RepositoryError.missingGame(gameID) }
        let matches = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>(
            predicate: #Predicate {
                $0.accountID == scope && $0.collectionKey == collectionKey && $0.gameID == gameID
            }
        ))
        guard matches.count <= 1 else { throw RepositoryError.duplicateEntry(gameID) }
        if let existing = matches.first {
            existing.sortOrder = sortOrder
        } else {
            context.insert(ItchPocketSchemaV4.DBLibraryCollectionItem(
                accountID: accountID,
                collectionKey: collectionKey,
                gameID: gameID,
                sortOrder: sortOrder
            ))
        }
        if save { try context.save() }
    }

    func removeGameFromCollection(
        collectionKey: String,
        gameID: String,
        save: Bool = true
    ) throws {
        let scope = accountID
        let matches = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>(
            predicate: #Predicate {
                $0.accountID == scope && $0.collectionKey == collectionKey && $0.gameID == gameID
            }
        ))
        guard matches.count <= 1 else { throw RepositoryError.duplicateEntry(gameID) }
        matches.forEach(context.delete)
        if save, !matches.isEmpty { try context.save() }
    }

    // MARK: - Account-owned status history

    func loadStatusEvents() throws -> [StoredAccountLibraryStatusEvent] {
        let scope = accountID
        let descriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>(
            predicate: #Predicate { $0.accountID == scope }
        )
        return try context.fetch(descriptor).map {
            StoredAccountLibraryStatusEvent(
                eventKey: $0.eventKey,
                gameID: $0.gameID,
                fromStatus: $0.fromStatus,
                toStatus: $0.toStatus
            )
        }.sorted { $0.eventKey < $1.eventKey }
    }

    func recordStatusEvent(
        eventKey: String,
        gameID: String,
        fromStatus: String?,
        toStatus: String,
        save: Bool = true
    ) throws {
        try V4AccountRegistryGuard.requireRegisteredAccount(accountID, in: context)
        let key = eventKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !toStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidAccountID
        }
        let gameRows = try context.fetch(FetchDescriptor<DBGame>(
            predicate: #Predicate { $0.id == gameID }
        ))
        guard !gameRows.isEmpty else { throw RepositoryError.missingGame(gameID) }
        let scope = accountID
        let matches = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>(
            predicate: #Predicate { $0.accountID == scope && $0.eventKey == key }
        ))
        guard matches.isEmpty else { throw RepositoryError.duplicateEntry(key) }
        context.insert(ItchPocketSchemaV4.DBLibraryStatusEvent(
            accountID: accountID,
            eventKey: key,
            gameID: gameID,
            fromStatus: fromStatus,
            toStatus: toStatus
        ))
        if save { try context.save() }
    }

}
