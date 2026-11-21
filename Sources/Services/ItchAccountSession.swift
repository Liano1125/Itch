import Foundation

/// Stable identity for an itch.io account.
///
/// Numeric itch user IDs are authoritative. Usernames and display names are
/// mutable presentation data and must never be used as account keys.
struct ItchAccountIdentity: Codable, Hashable, Identifiable {
    let itchUserID: Int
    var username: String
    var displayName: String?
    var profileURL: URL?
    var avatarURL: URL?

    var id: String {
        "itch:\(itchUserID)"
    }

    init(
        itchUserID: Int,
        username: String,
        displayName: String? = nil,
        profileURL: URL? = nil,
        avatarURL: URL? = nil
    ) {
        self.itchUserID = itchUserID
        self.username = username
        self.displayName = displayName
        self.profileURL = profileURL
        self.avatarURL = avatarURL
    }

    init(user: ItchUser) {
        self.init(
            itchUserID: user.id,
            username: user.username,
            displayName: user.displayName,
            profileURL: user.url,
            avatarURL: user.coverUrl
        )
    }
}

/// Immutable identity + generation captured when account-owned async work begins.
/// Requiring both values makes call sites explicit about which account owns a result,
/// while the generation also rejects sign-out/sign-in cycles for the same identity.
struct ItchAccountRequestContext: Equatable {
    let accountID: String
    let generation: UInt64
    let accountRemovalGeneration: UInt64
}

/// Snapshot used by legacy V3 library operations, including signed-out local-library mode.
/// The optional account ID records whether the operation began signed in, while the
/// generation rejects results that cross sign-in, sign-out, or account-switch boundaries.
struct ItchSessionOperationContext: Equatable {
    let accountID: String?
    let generation: UInt64
}

/// Snapshot used by authentication flows to detect a removal that starts and
/// finishes while profile lookup is suspended.
struct ItchAccountRemovalStateSnapshot: Equatable {
    let generations: [String: UInt64]
    let accountsBeingRemoved: Set<String>
}

/// In-memory account generation used to reject late async results after an
/// account switch. This is deliberately independent of SwiftData so the
/// migration can be introduced before repositories become account-scoped.
@MainActor
final class ItchAccountSession {
    private(set) var identity: ItchAccountIdentity?
    private(set) var generation: UInt64 = 0
    private var accountsBeingRemoved = Set<String>()
    private var accountRemovalGenerations: [String: UInt64] = [:]

    /// Reserves an account identity while its persistent data and notification
    /// projections are being removed. Authentication must not reactivate it
    /// until the complete removal operation has finished.
    func beginAccountRemoval(_ accountID: String) -> Bool {
        guard accountsBeingRemoved.insert(accountID).inserted else { return false }
        // Invalidate only this account's in-flight work. An unrelated active
        // account must not have its requests cancelled by this removal.
        accountRemovalGenerations[accountID, default: 0] += 1
        return true
    }

    func endAccountRemoval(_ accountID: String) {
        accountsBeingRemoved.remove(accountID)
    }

    func isRemovalInProgress(for accountID: String) -> Bool {
        accountsBeingRemoved.contains(accountID)
    }

    func captureRemovalStateSnapshot() -> ItchAccountRemovalStateSnapshot {
        ItchAccountRemovalStateSnapshot(
            generations: accountRemovalGenerations,
            accountsBeingRemoved: accountsBeingRemoved
        )
    }

    func removalWasStarted(for accountID: String, after snapshot: ItchAccountRemovalStateSnapshot) -> Bool {
        snapshot.accountsBeingRemoved.contains(accountID)
            || snapshot.generations[accountID, default: 0] != accountRemovalGenerations[accountID, default: 0]
    }

    func activate(_ identity: ItchAccountIdentity?) {
        guard self.identity?.id != identity?.id else {
            // Refresh mutable profile fields without invalidating work for the
            // same authenticated account.
            self.identity = identity
            return
        }
        generation &+= 1
        self.identity = identity
    }

    /// Captures the currently authenticated account for an async operation.
    /// Returns nil while signed out so account-owned work cannot start unscoped.
    func captureRequestContext() -> ItchAccountRequestContext? {
        guard let identity, !accountsBeingRemoved.contains(identity.id) else { return nil }
        return ItchAccountRequestContext(
            accountID: identity.id,
            generation: generation,
            accountRemovalGeneration: accountRemovalGenerations[identity.id, default: 0]
        )
    }

    /// Validates both account identity and generation before publishing or saving
    /// an async result. Call this immediately before every account-owned side effect.
    func isCurrent(_ context: ItchAccountRequestContext) -> Bool {
        identity?.id == context.accountID
            && generation == context.generation
            && accountRemovalGenerations[context.accountID, default: 0] == context.accountRemovalGeneration
            && !accountsBeingRemoved.contains(context.accountID)
    }

    /// Captures the current session state for operations that also run while signed out.
    func captureOperationContext() -> ItchSessionOperationContext {
        ItchSessionOperationContext(accountID: identity?.id, generation: generation)
    }

    /// Rejects work that completed after sign-in, sign-out, or an account switch.
    func isCurrent(_ context: ItchSessionOperationContext) -> Bool {
        identity?.id == context.accountID && generation == context.generation
    }

    /// Compatibility API retained while existing call sites migrate to contexts.
    func requestGeneration() -> UInt64 {
        generation
    }

    func isCurrent(_ requestGeneration: UInt64) -> Bool {
        requestGeneration == generation
    }
}
