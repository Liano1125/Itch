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

    func requestGeneration() -> UInt64 {
        generation
    }

    func isCurrent(_ requestGeneration: UInt64) -> Bool {
        requestGeneration == generation
    }
}
