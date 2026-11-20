import Foundation
import SwiftData

/// Persists verified itch.io identity metadata in the V4 account registry.
/// Credentials and Patreon identity are deliberately outside this repository.
@MainActor
final class V4AccountRegistryRepository {
    enum RepositoryError: LocalizedError, Equatable {
        case invalidIdentity
        case duplicateIdentity(String)

        var errorDescription: String? {
            switch self {
            case .invalidIdentity:
                return "A verified itch account with a positive numeric user ID is required."
            case .duplicateIdentity(let id):
                return "Multiple V4 account records match identity \(id)."
            }
        }
    }

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Call only after the itch authentication response has supplied the numeric user ID.
    /// Re-authentication refreshes profile metadata without creating a second account row.
    @discardableResult
    func recordAuthenticatedIdentity(
        _ identity: ItchAccountIdentity,
        at date: Date = .now
    ) throws -> DBAccount {
        guard identity.itchUserID > 0,
              identity.id == "itch:\(identity.itchUserID)",
              !identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidIdentity
        }

        let accountID = identity.id
        let descriptor = FetchDescriptor<DBAccount>(
            predicate: #Predicate { $0.id == accountID }
        )
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw RepositoryError.duplicateIdentity(accountID)
        }

        let account: DBAccount
        if let existing = matches.first {
            account = existing
            account.refreshProfile(from: identity)
        } else {
            account = DBAccount(
                itchUserID: identity.itchUserID,
                username: identity.username,
                displayName: identity.displayName,
                profileURL: identity.profileURL?.absoluteString,
                avatarURL: identity.avatarURL?.absoluteString,
                firstSeenAt: date
            )
            context.insert(account)
        }

        account.lastAuthenticatedAt = date
        account.lastUsedAt = date
        try context.save()
        return account
    }

    func loadAccount(itchUserID: Int) throws -> DBAccount? {
        guard itchUserID > 0 else { throw RepositoryError.invalidIdentity }
        let accountID = DBAccount.stableID(itchUserID: itchUserID)
        let descriptor = FetchDescriptor<DBAccount>(
            predicate: #Predicate { $0.id == accountID }
        )
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw RepositoryError.duplicateIdentity(accountID)
        }
        return matches.first
    }
}
