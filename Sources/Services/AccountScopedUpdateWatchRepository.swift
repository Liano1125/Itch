import Foundation
import SwiftData

struct StoredAccountUpdateWatch: Equatable {
    let gameID: String
    let entityTag: String?
    let lastModified: String?
    let contentHash: String?
    let lastCheckedAt: Date?
    let hasBaseline: Bool
    let isEnabled: Bool
}

/// V4-only repository. Every operation is bound to one canonical itch account.
/// It is intentionally not wired to the V3 global monitor store.
@MainActor
final class AccountScopedUpdateWatchRepository {
    enum RepositoryError: LocalizedError, Equatable {
        case invalidAccountID
        case emptyGameID
        case missingGame(String)
        case duplicateRecord(String)

        var errorDescription: String? {
            switch self {
            case .invalidAccountID:
                return "A canonical itch:<positive-user-id> account is required."
            case .emptyGameID:
                return "Update-watch game identity must not be empty."
            case .missingGame(let id):
                return "Update-watch game does not exist: \(id)."
            case .duplicateRecord(let id):
                return "Multiple update-watch records match \(id)."
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

    func loadWatches() throws -> [StoredAccountUpdateWatch] {
        let scope = accountID
        let descriptor = FetchDescriptor<DBAccountUpdateWatch>(
            predicate: #Predicate { $0.accountID == scope }
        )
        return try context.fetch(descriptor).map {
            StoredAccountUpdateWatch(
                gameID: $0.gameID, entityTag: $0.entityTag, lastModified: $0.lastModified,
                contentHash: $0.contentHash, lastCheckedAt: $0.lastCheckedAt,
                hasBaseline: $0.hasBaseline, isEnabled: $0.isEnabled
            )
        }.sorted { $0.gameID < $1.gameID }
    }

    func upsert(_ watch: StoredAccountUpdateWatch, save: Bool = true) throws {
        try V4AccountRegistryGuard.requireRegisteredAccount(accountID, in: context)
        let gameID = watch.gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gameID.isEmpty, gameID == watch.gameID else { throw RepositoryError.emptyGameID }
        let gameDescriptor = FetchDescriptor<DBGame>(predicate: #Predicate { $0.id == gameID })
        guard try context.fetch(gameDescriptor).first != nil else {
            throw RepositoryError.missingGame(gameID)
        }

        let id = DBAccountUpdateWatch.stableID(accountID: accountID, gameID: gameID)
        let descriptor = FetchDescriptor<DBAccountUpdateWatch>(predicate: #Predicate { $0.id == id })
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw RepositoryError.duplicateRecord(id) }
        let row = rows.first ?? DBAccountUpdateWatch(accountID: accountID, gameID: gameID)
        if rows.isEmpty { context.insert(row) }
        row.entityTag = watch.entityTag
        row.lastModified = watch.lastModified
        row.contentHash = watch.contentHash
        row.lastCheckedAt = watch.lastCheckedAt
        row.hasBaseline = watch.hasBaseline
        row.isEnabled = watch.isEnabled
        if save { try context.save() }
    }

    func setEnabled(gameID: String, isEnabled: Bool, save: Bool = true) throws {
        let current = try loadWatches().first { $0.gameID == gameID }
        let watch = current ?? StoredAccountUpdateWatch(
            gameID: gameID, entityTag: nil, lastModified: nil, contentHash: nil,
            lastCheckedAt: nil, hasBaseline: false, isEnabled: isEnabled
        )
        try upsert(StoredAccountUpdateWatch(
            gameID: watch.gameID, entityTag: watch.entityTag, lastModified: watch.lastModified,
            contentHash: watch.contentHash, lastCheckedAt: watch.lastCheckedAt,
            hasBaseline: watch.hasBaseline, isEnabled: isEnabled
        ), save: save)
    }

    func delete(gameID: String, save: Bool = true) throws {
        let id = DBAccountUpdateWatch.stableID(accountID: accountID, gameID: gameID)
        let descriptor = FetchDescriptor<DBAccountUpdateWatch>(predicate: #Predicate { $0.id == id })
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw RepositoryError.duplicateRecord(id) }
        rows.forEach(context.delete)
        if save, !rows.isEmpty { try context.save() }
    }

    /// Copies V3 rows into an unassigned holding area without deleting or
    /// modifying the source. Repeated calls are idempotent.
    func quarantineLegacyRows(quarantinedAt: Date = .now) throws -> Int {
        let sourceRows = try context.fetch(FetchDescriptor<DBUpdateWatch>())
        let existingRows = try context.fetch(FetchDescriptor<DBLegacyUpdateWatch>())
        var existingByID: [String: DBLegacyUpdateWatch] = [:]
        for row in existingRows {
            guard existingByID[row.id] == nil else { throw RepositoryError.duplicateRecord(row.id) }
            existingByID[row.id] = row
        }

        let games = try context.fetch(FetchDescriptor<DBGame>())
        let gameIDs = Set(games.map(\.id))
        var pending: [DBLegacyUpdateWatch] = []
        for source in sourceRows {
            let id = DBLegacyUpdateWatch.stableID(gameID: source.gameID)
            guard existingByID[id] == nil else { continue }
            pending.append(DBLegacyUpdateWatch(
                originalGameID: source.gameID,
                entityTag: source.entityTag,
                lastModified: source.lastModified,
                contentHash: source.contentHash,
                lastCheckedAt: source.lastCheckedAt,
                hasBaseline: source.hasBaseline,
                isEnabled: source.isEnabled,
                integrityIssue: gameIDs.contains(source.gameID) ? nil : "missing-game",
                quarantinedAt: quarantinedAt
            ))
        }
        guard !pending.isEmpty else { return 0 }
        pending.forEach(context.insert)
        try context.save()
        return pending.count
    }
}
