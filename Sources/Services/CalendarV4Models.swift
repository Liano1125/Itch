import Foundation
import SwiftData

/// Shared, source-derived calendar timeline data. Never stores account notes or reminder preferences.
@Model
final class DBCalendarSourceEvent {
    @Attribute(.unique) var id: String
    var sourceFingerprint: String
    var gameID: String
    var title: String?
    var date: Date?
    var kind: String
    var sourceUpdateID: String?
    var gameTitleSnapshot: String?
    var updatedAt: Date

    init(sourceFingerprint: String, gameID: String, title: String? = nil, date: Date? = nil,
         kind: String, sourceUpdateID: String? = nil, gameTitleSnapshot: String? = nil,
         updatedAt: Date = .now) {
        self.id = Self.stableID(sourceFingerprint: sourceFingerprint)
        self.sourceFingerprint = sourceFingerprint
        self.gameID = gameID
        self.title = title
        self.date = date
        self.kind = kind
        self.sourceUpdateID = sourceUpdateID
        self.gameTitleSnapshot = gameTitleSnapshot
        self.updatedAt = updatedAt
    }

    static func stableID(sourceFingerprint: String) -> String {
        "source:\(sourceFingerprint.utf8.count):\(sourceFingerprint)"
    }
}

/// User-created calendar events. Every row belongs to exactly one verified itch account.
@Model
final class DBAccountCalendarEvent {
    @Attribute(.unique) var id: String
    var accountID: String
    var eventKey: String
    var gameID: String
    var title: String?
    var date: Date?
    var kind: String
    var reminderEnabled: Bool
    var reminderMinutes: Int
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    init(accountID: String, eventKey: String, gameID: String, title: String? = nil,
         date: Date? = nil, kind: String, reminderEnabled: Bool = true,
         reminderMinutes: Int = 60, notes: String? = nil,
         createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = Self.stableID(accountID: accountID, eventKey: eventKey)
        self.accountID = accountID
        self.eventKey = eventKey
        self.gameID = gameID
        self.title = title
        self.date = date
        self.kind = kind
        self.reminderEnabled = reminderEnabled
        self.reminderMinutes = reminderMinutes
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func stableID(accountID: String, eventKey: String) -> String {
        "\(accountID.utf8.count):\(accountID)\(eventKey.utf8.count):\(eventKey)"
    }
}

/// Per-account reminder and note overlay for a shared source event.
@Model
final class DBAccountCalendarOverlay {
    @Attribute(.unique) var id: String
    var accountID: String
    var sourceEventID: String
    var reminderEnabled: Bool
    var reminderMinutes: Int
    var notes: String?
    var updatedAt: Date

    init(accountID: String, sourceEventID: String, reminderEnabled: Bool = false,
         reminderMinutes: Int = 60, notes: String? = nil, updatedAt: Date = .now) {
        self.id = Self.stableID(accountID: accountID, sourceEventID: sourceEventID)
        self.accountID = accountID
        self.sourceEventID = sourceEventID
        self.reminderEnabled = reminderEnabled
        self.reminderMinutes = reminderMinutes
        self.notes = notes
        self.updatedAt = updatedAt
    }

    static func stableID(accountID: String, sourceEventID: String) -> String {
        "\(accountID.utf8.count):\(accountID)\(sourceEventID.utf8.count):\(sourceEventID)"
    }
}

/// Lossless V3 calendar quarantine. Rows remain unassigned until provenance or an explicit claim is verified.
@Model
final class DBLegacyCalendarEvent {
    @Attribute(.unique) var id: String
    var originalEventID: String
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
    var quarantinedAt: Date
    var integrityIssue: String?

    init(copying row: DBCalendarEvent, integrityIssue: String? = nil, quarantinedAt: Date = .now) {
        self.originalEventID = row.id
        self.id = Self.stableID(originalEventID: row.id)
        self.gameID = row.gameID
        self.title = row.title
        self.date = row.date
        self.kind = row.kind
        self.reminderEnabled = row.reminderEnabled
        self.reminderMinutes = row.reminderMinutes
        self.notes = row.notes
        self.sourceFingerprint = row.sourceFingerprint
        self.sourceUpdateID = row.sourceUpdateID
        self.gameTitleSnapshot = row.gameTitleSnapshot
        self.quarantinedAt = quarantinedAt
        self.integrityIssue = integrityIssue
    }

    static func stableID(originalEventID: String) -> String {
        "legacy-calendar:\(originalEventID.utf8.count):\(originalEventID)"
    }
}
