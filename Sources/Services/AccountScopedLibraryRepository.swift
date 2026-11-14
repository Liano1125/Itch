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
        guard normalized.hasPrefix("itch:"), normalized.count > 5 else {
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
}
