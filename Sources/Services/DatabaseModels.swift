import Foundation
import SwiftData

// MARK: - Canonical database records
// These records are the single durable source of truth. Views must never persist
// their own copies; feature stores are temporary presentation facades only.

@Model
final class DBDeveloper {
    @Attribute(.unique) var id: String
    var name: String
    var profileURL: String?
    var patreonURL: String?
    var discordURL: String?
    var avatarURL: String?
    var avatarSource: String?
    var avatarResolvedAt: Date?
    var updatedAt: Date

    init(id: String, name: String, profileURL: String? = nil, patreonURL: String? = nil, discordURL: String? = nil, avatarURL: String? = nil, avatarSource: String? = nil, avatarResolvedAt: Date? = nil, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.profileURL = profileURL
        self.patreonURL = patreonURL
        self.discordURL = discordURL
        self.avatarURL = avatarURL
        self.avatarSource = avatarSource
        self.avatarResolvedAt = avatarResolvedAt
        self.updatedAt = updatedAt
    }
}

@Model
final class DBGame {
    @Attribute(.unique) var id: String
    var title: String
    var gameURL: String?
    var coverURL: String?
    var engine: String?
    var developerID: String?
    var updatedAt: Date

    init(id: String, title: String, gameURL: String? = nil, coverURL: String? = nil, engine: String? = nil, developerID: String? = nil, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.gameURL = gameURL
        self.coverURL = coverURL
        self.engine = engine
        self.developerID = developerID
        self.updatedAt = updatedAt
    }
}

@Model
final class DBLibraryEntry {
    @Attribute(.unique) var gameID: String
    var status: String
    var isFavorite: Bool
    var notes: String
    var addedAt: Date
    var updatedAt: Date

    init(gameID: String, status: String, isFavorite: Bool = false, notes: String = "", addedAt: Date = .now, updatedAt: Date = .now) {
        self.gameID = gameID
        self.status = status
        self.isFavorite = isFavorite
        self.notes = notes
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}

@Model
final class DBGameUpdate {
    @Attribute(.unique) var id: String
    var gameID: String
    var title: String?
    var summary: String
    var detectedAt: Date
    var publishedAt: Date?
    var url: String?
    var sourceID: String?
    var isHistorical: Bool

    init(id: String, gameID: String, title: String? = nil, summary: String, detectedAt: Date = .now, publishedAt: Date? = nil, url: String? = nil, sourceID: String? = nil, isHistorical: Bool = false) {
        self.id = id
        self.gameID = gameID
        self.title = title
        self.summary = summary
        self.detectedAt = detectedAt
        self.publishedAt = publishedAt
        self.url = url
        self.sourceID = sourceID
        self.isHistorical = isHistorical
    }
}

@Model
final class DBCalendarEvent {
    @Attribute(.unique) var id: String
    var gameID: String
    var title: String?
    var date: Date?
    var kind: String
    var reminderEnabled: Bool
    var reminderMinutes: Int
    var notes: String?
    var sourceFingerprint: String?
    var sourceUpdateID: String?
    var gameTitleSnapshot: String?

    init(id: String, gameID: String, title: String? = nil, date: Date? = nil, kind: String, reminderEnabled: Bool = true, reminderMinutes: Int = 60, notes: String? = nil, sourceFingerprint: String? = nil, sourceUpdateID: String? = nil, gameTitleSnapshot: String? = nil) {
        self.id = id
        self.gameID = gameID
        self.title = title
        self.date = date
        self.kind = kind
        self.reminderEnabled = reminderEnabled
        self.reminderMinutes = reminderMinutes
        self.notes = notes
        self.sourceFingerprint = sourceFingerprint
        self.sourceUpdateID = sourceUpdateID
        self.gameTitleSnapshot = gameTitleSnapshot
    }
}

@Model
final class DBSparkMetadata {
    @Attribute(.unique) var gameID: String
    var runtimeSeconds: Double
    var lastSaveAt: Date?
    var renpyVersion: String?
    var saveCount: Int?
    var scannedAt: Date

    init(gameID: String, runtimeSeconds: Double, lastSaveAt: Date? = nil, renpyVersion: String? = nil, saveCount: Int? = nil, scannedAt: Date = .now) {
        self.gameID = gameID
        self.runtimeSeconds = runtimeSeconds
        self.lastSaveAt = lastSaveAt
        self.renpyVersion = renpyVersion
        self.saveCount = saveCount
        self.scannedAt = scannedAt
    }
}

@Model
final class DBTranslation {
    @Attribute(.unique) var cacheKey: String
    var scope: String
    var sourceHash: String
    var sourceText: String
    var targetLanguage: String
    var translatedText: String
    var updatedAt: Date

    init(cacheKey: String, scope: String, sourceHash: String, sourceText: String, targetLanguage: String, translatedText: String, updatedAt: Date = .now) {
        self.cacheKey = cacheKey
        self.scope = scope
        self.sourceHash = sourceHash
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.translatedText = translatedText
        self.updatedAt = updatedAt
    }
}

@Model
final class DBDiscoverySnapshot {
    @Attribute(.unique) var key: String
    var payload: Data
    var fetchedAt: Date
    var expiresAt: Date

    init(key: String, payload: Data, fetchedAt: Date = .now, expiresAt: Date) {
        self.key = key
        self.payload = payload
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
    }
}

@Model
final class DBUpdateWatch {
    @Attribute(.unique) var gameID: String
    var entityTag: String?
    var lastModified: String?
    var contentHash: String?
    var lastCheckedAt: Date?
    var hasBaseline: Bool
    var isEnabled: Bool

    init(gameID: String, entityTag: String? = nil, lastModified: String? = nil, contentHash: String? = nil, lastCheckedAt: Date? = nil, hasBaseline: Bool = false, isEnabled: Bool = true) {
        self.gameID = gameID
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.contentHash = contentHash
        self.lastCheckedAt = lastCheckedAt
        self.hasBaseline = hasBaseline
        self.isEnabled = isEnabled
    }
}

@Model
final class DBLibraryCollection {
    @Attribute(.unique) var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String, title: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class DBLibraryStatusEvent {
    @Attribute(.unique) var id: String
    var gameID: String
    var fromStatus: String?
    var toStatus: String
    var changedAt: Date

    init(id: String, gameID: String, fromStatus: String?, toStatus: String, changedAt: Date = .now) {
        self.id = id
        self.gameID = gameID
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.changedAt = changedAt
    }
}

@Model
final class DBAppState {
    @Attribute(.unique) var key: String
    var stringValue: String?
    var dateValue: Date?
    var dataValue: Data?
    var updatedAt: Date

    init(key: String, stringValue: String? = nil, dateValue: Date? = nil, dataValue: Data? = nil, updatedAt: Date = .now) {
        self.key = key
        self.stringValue = stringValue
        self.dateValue = dateValue
        self.dataValue = dataValue
        self.updatedAt = updatedAt
    }
}


/// Canonical, independently invalidatable V3 game-detail record.
@Model
final class DBGameDetail {
    @Attribute(.unique) var gameID: String
    var descriptionText: String?
    var galleryURLs: [String]
    var discoveryTagsData: Data?
    var fetchedAt: Date?
    var isComplete: Bool

    init(
        gameID: String,
        descriptionText: String? = nil,
        galleryURLs: [String] = [],
        discoveryTagsData: Data? = nil,
        fetchedAt: Date? = nil,
        isComplete: Bool = false
    ) {
        self.gameID = gameID
        self.descriptionText = descriptionText
        self.galleryURLs = galleryURLs
        self.discoveryTagsData = discoveryTagsData
        self.fetchedAt = fetchedAt
        self.isComplete = isComplete
    }
}

/// Join record for collection membership. Composite uniqueness is enforced by
/// LibraryRepository using (collectionID, gameID); id is deterministic for migration.
@Model
final class DBLibraryCollectionItem {
    @Attribute(.unique) var id: String
    var collectionID: String
    var gameID: String
    var sortOrder: Int
    var addedAt: Date

    init(id: String, collectionID: String, gameID: String, sortOrder: Int, addedAt: Date = .now) {
        self.id = id
        self.collectionID = collectionID
        self.gameID = gameID
        self.sortOrder = sortOrder
        self.addedAt = addedAt
    }

    static func stableID(collectionID: String, gameID: String) -> String {
        "\(collectionID.utf8.count):\(collectionID)\(gameID.utf8.count):\(gameID)"
    }
}


/// Persisted itch.io account profile. Credentials remain exclusively in Keychain.
/// This model is introduced in V4; V3 stores are not opened with this schema.
@Model
final class DBAccount {
    @Attribute(.unique) var id: String
    @Attribute(.unique) var itchUserID: Int
    var username: String
    var displayName: String?
    var profileURL: String?
    var avatarURL: String?
    var firstSeenAt: Date
    var lastAuthenticatedAt: Date?
    var lastUsedAt: Date?

    init(
        itchUserID: Int,
        username: String,
        displayName: String? = nil,
        profileURL: String? = nil,
        avatarURL: String? = nil,
        firstSeenAt: Date = .now,
        lastAuthenticatedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = Self.stableID(itchUserID: itchUserID)
        self.itchUserID = itchUserID
        self.username = username
        self.displayName = displayName
        self.profileURL = profileURL
        self.avatarURL = avatarURL
        self.firstSeenAt = firstSeenAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
        self.lastUsedAt = lastUsedAt
    }

    static func stableID(itchUserID: Int) -> String {
        "itch:\\(itchUserID)"
    }

    func refreshProfile(from identity: ItchAccountIdentity) {
        guard identity.itchUserID == itchUserID else { return }
        username = identity.username
        displayName = identity.displayName
        profileURL = identity.profileURL?.absoluteString
        avatarURL = identity.avatarURL?.absoluteString
    }
}
