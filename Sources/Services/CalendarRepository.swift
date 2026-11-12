import Foundation
import SwiftData

/// A value-only snapshot of a calendar row. Linked game updates enrich this
/// snapshot, but the calendar row remains independently readable.
struct StoredCalendarEvent {
    let id: String
    let gameID: String
    let title: String?
    let date: Date?
    let kind: String
    let reminderEnabled: Bool
    let reminderMinutes: Int
    let notes: String?
    let sourceFingerprint: String?
    let sourceUpdateID: String?
    let gameTitleSnapshot: String?

    init(
        id: String,
        gameID: String,
        title: String? = nil,
        date: Date? = nil,
        kind: String,
        reminderEnabled: Bool = true,
        reminderMinutes: Int = 60,
        notes: String? = nil,
        sourceFingerprint: String? = nil,
        sourceUpdateID: String? = nil,
        gameTitleSnapshot: String? = nil
    ) {
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

    fileprivate init(_ row: DBCalendarEvent) {
        self.init(
            id: row.id,
            gameID: row.gameID,
            title: row.title,
            date: row.date,
            kind: row.kind,
            reminderEnabled: row.reminderEnabled,
            reminderMinutes: row.reminderMinutes,
            notes: row.notes,
            sourceFingerprint: row.sourceFingerprint,
            sourceUpdateID: row.sourceUpdateID,
            gameTitleSnapshot: row.gameTitleSnapshot
        )
    }
}

/// Owns DBCalendarEvent persistence. It deliberately does not own Devlog or
/// Patreon content stores; those will have independent records and repositories.
@MainActor
final class CalendarRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func loadEvents() throws -> [StoredCalendarEvent] {
        try database.repositoryContext.fetch(FetchDescriptor<DBCalendarEvent>())
            .map(StoredCalendarEvent.init)
    }

    func upsert(
        _ event: StoredCalendarEvent,
        sourceUpdateID: String? = nil,
        clearSourceUpdateLink: Bool = false,
        save shouldSave: Bool = true
    ) throws {
        let context = database.repositoryContext
        try DatabaseReferenceValidator.requireGame(event.gameID, in: context)

        let eventID = event.id
        let descriptor = FetchDescriptor<DBCalendarEvent>(
            predicate: #Predicate { $0.id == eventID }
        )
        let existingRow = try context.fetch(descriptor).first
        let resolvedSourceUpdateID = CalendarSourceUpdateLinkPolicy.resolvedValue(
            existing: existingRow?.sourceUpdateID,
            incoming: sourceUpdateID,
            clear: clearSourceUpdateLink
        )
        try DatabaseReferenceValidator.validateCalendarUpdateLink(
            resolvedSourceUpdateID,
            eventGameID: event.gameID,
            in: context
        )

        let row = existingRow ?? DBCalendarEvent(
            id: event.id,
            gameID: event.gameID,
            kind: event.kind
        )
        if row.modelContext == nil { context.insert(row) }

        row.gameID = event.gameID
        row.title = event.title
        row.date = event.date
        row.kind = event.kind
        row.reminderEnabled = event.reminderEnabled
        row.reminderMinutes = event.reminderMinutes
        row.notes = event.notes
        row.sourceFingerprint = event.sourceFingerprint
        row.gameTitleSnapshot = event.gameTitleSnapshot
        row.sourceUpdateID = CalendarSourceUpdateLinkPolicy.resolvedValue(
            existing: row.sourceUpdateID,
            incoming: sourceUpdateID,
            clear: clearSourceUpdateLink
        )

        if shouldSave { try database.save() }
    }

    func delete(id: String, save shouldSave: Bool = true) throws {
        let descriptor = FetchDescriptor<DBCalendarEvent>(
            predicate: #Predicate { $0.id == id }
        )
        if let row = try database.repositoryContext.fetch(descriptor).first {
            database.repositoryContext.delete(row)
            if shouldSave { try database.save() }
        }
    }
}
