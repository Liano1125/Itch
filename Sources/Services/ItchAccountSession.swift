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
}

/// In-memory account generation used to reject late async results after an
/// account switch. This is deliberately independent of SwiftData so the
/// migration can be introduced before repositories become account-scoped.
@MainActor
final class ItchAccountSession {
    private(set) var identity: ItchAccountIdentity?
    private(set) var generation: UInt64 = 0

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
        guard let identity else { return nil }
        return ItchAccountRequestContext(accountID: identity.id, generation: generation)
    }

    /// Validates both account identity and generation before publishing or saving
    /// an async result. Call this immediately before every account-owned side effect.
    func isCurrent(_ context: ItchAccountRequestContext) -> Bool {
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
