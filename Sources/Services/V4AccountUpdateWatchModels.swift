import Foundation
import SwiftData

/// V4 update-watch state. Both user preference and HTTP validators remain
/// account-scoped until request-session independence is proven.
@Model
final class DBAccountUpdateWatch {
    @Attribute(.unique) var id: String
    var accountID: String
    var gameID: String
    var entityTag: String?
    var lastModified: String?
    var contentHash: String?
    var lastCheckedAt: Date?
    var hasBaseline: Bool
    var isEnabled: Bool

    init(
        accountID: String,
        gameID: String,
        entityTag: String? = nil,
        lastModified: String? = nil,
        contentHash: String? = nil,
        lastCheckedAt: Date? = nil,
        hasBaseline: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = Self.stableID(accountID: accountID, gameID: gameID)
        self.accountID = accountID
        self.gameID = gameID
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.contentHash = contentHash
        self.lastCheckedAt = lastCheckedAt
        self.hasBaseline = hasBaseline
        self.isEnabled = isEnabled
    }

    static func stableID(accountID: String, gameID: String) -> String {
        "\(accountID.utf8.count):\(accountID)\(gameID.utf8.count):\(gameID)"
    }
}

/// Lossless holding area for V3 globally-keyed watches. No account owner is
/// inferred from the current login, library membership, or game URL.
@Model
final class DBLegacyUpdateWatch {
    @Attribute(.unique) var id: String
    var originalGameID: String
    var entityTag: String?
    var lastModified: String?
    var contentHash: String?
    var lastCheckedAt: Date?
    var hasBaseline: Bool
    var isEnabled: Bool
    var integrityIssue: String?
    var quarantinedAt: Date

    init(
        originalGameID: String,
        entityTag: String? = nil,
        lastModified: String? = nil,
        contentHash: String? = nil,
        lastCheckedAt: Date? = nil,
        hasBaseline: Bool = false,
        isEnabled: Bool = true,
        integrityIssue: String? = nil,
        quarantinedAt: Date = .now
    ) {
        self.id = Self.stableID(gameID: originalGameID)
        self.originalGameID = originalGameID
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.contentHash = contentHash
        self.lastCheckedAt = lastCheckedAt
        self.hasBaseline = hasBaseline
        self.isEnabled = isEnabled
        self.integrityIssue = integrityIssue
        self.quarantinedAt = quarantinedAt
    }

    static func stableID(gameID: String) -> String {
        "v3-update-watch:\(gameID.utf8.count):\(gameID)"
    }
}
