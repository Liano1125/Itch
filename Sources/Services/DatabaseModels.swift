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
    var descriptionText: String?
    var galleryURLs: [String]
    var engine: String?
    var developerID: String?
    var updatedAt: Date

    init(id: String, title: String, gameURL: String? = nil, coverURL: String? = nil, descriptionText: String? = nil, galleryURLs: [String] = [], engine: String? = nil, developerID: String? = nil, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.gameURL = gameURL
        self.coverURL = coverURL
        self.descriptionText = descriptionText
        self.galleryURLs = galleryURLs
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
    // Snapshot is intentionally retained so a calendar item remains readable
    // even if its game is later removed from the personal library.
    var gameTitleSnapshot: String?
    var title: String?
    var date: Date?
    var kind: String
    var reminderEnabled: Bool
    var reminderMinutes: Int
    var notes: String?
    var sourceFingerprint: String?
    var sourceUpdateID: String?

    init(id: String, gameID: String, gameTitleSnapshot: String? = nil, title: String? = nil, date: Date? = nil, kind: String, reminderEnabled: Bool = true, reminderMinutes: Int = 60, notes: String? = nil, sourceFingerprint: String? = nil, sourceUpdateID: String? = nil) {
        self.id = id
        self.gameID = gameID
        self.gameTitleSnapshot = gameTitleSnapshot
        self.title = title
        self.date = date
        self.kind = kind
        self.reminderEnabled = reminderEnabled
        self.reminderMinutes = reminderMinutes
        self.notes = notes
        self.sourceFingerprint = sourceFingerprint
        self.sourceUpdateID = sourceUpdateID
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
    var gameTitle: String
    var gameURL: String
    var entityTag: String?
    var lastModified: String?
    var contentHash: String?
    var lastCheckedAt: Date?
    var hasBaseline: Bool
    var isEnabled: Bool

    init(gameID: String, gameTitle: String, gameURL: String, entityTag: String? = nil, lastModified: String? = nil, contentHash: String? = nil, lastCheckedAt: Date? = nil, hasBaseline: Bool = false, isEnabled: Bool = true) {
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.gameURL = gameURL
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
    var gameIDs: [String]
    var createdAt: Date
    var updatedAt: Date

    init(id: String, title: String, gameIDs: [String] = [], createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.gameIDs = gameIDs
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
